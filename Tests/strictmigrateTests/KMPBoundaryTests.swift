import XCTest

@testable import strictmigrate

final class KotlinSymbolLocatorTests: XCTestCase {
    let kotlinSource = """
        package com.example.shared

        class UserSession(private val userID: String) {
            var lastSeen: Long = 0

            fun touch() {
                lastSeen = System.currentTimeMillis()
            }

            /* nested block comment } { */
            fun summary(prefix: String = "u") = prefix + ": ${'$'}{userID} (${'$'}lastSeen)"
        }

        object Registry {
            val sessions = mutableMapOf<String, UserSession>()

            fun register(session: UserSession) {
                sessions[session.userID] = session
            }
        }

        suspend fun refresh(session: UserSession): String = \"\"\"
            raw text with } braces { inside
            \"\"\"
        """

    func testFindsKotlinDeclarations() {
        let symbols = SymbolLocator.symbols(in: kotlinSource, language: .kotlin)
        let names = symbols.map(\.name)
        let listing = names.joined(separator: ", ")

        XCTAssertTrue(names.contains("UserSession"), listing)
        XCTAssertTrue(names.contains("lastSeen"), listing)
        XCTAssertTrue(names.contains("touch"), listing)
        XCTAssertTrue(names.contains("summary"), listing)
        XCTAssertTrue(names.contains("Registry"), listing)
        XCTAssertTrue(names.contains("sessions"), listing)
        XCTAssertTrue(names.contains("refresh"), listing)
        // Local parameters and statements never become symbols.
        XCTAssertFalse(names.contains("userID"))
        XCTAssertFalse(names.contains("System"))
        XCTAssertFalse(names.contains("session"))
    }

    func testRawStringBracesDoNotCloseDeclarations() {
        let symbols = SymbolLocator.symbols(in: kotlinSource, language: .kotlin)
        let refresh = symbols.first { $0.name == "refresh" }
        XCTAssertNotNil(refresh)
        // refresh starts at its declaration line and spans the raw-string body.
        XCTAssertGreaterThan(refresh!.endLine, refresh!.startLine + 1)
        XCTAssertEqual(refresh!.kind, "fun")
    }

    func testInnermostResolutionInsideKotlinFun() {
        let symbols = SymbolLocator.symbols(in: kotlinSource, language: .kotlin)
        let touch = symbols.first { $0.name == "touch" }
        XCTAssertNotNil(touch)
        let innermost = SymbolLocator.innermostSymbol(containingLine: touch!.startLine + 1, in: symbols)
        XCTAssertEqual(innermost?.name, "touch")
    }
}

final class GradleTargetHeuristicTests: XCTestCase {
    private var root: String!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gradle-heuristic-\(UUID().uuidString)").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    private func mkdir(_ relativePath: String) -> String {
        let path = (root as NSString).appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func touch(_ relativePath: String, _ content: String = "// x\n") {
        let path = (root as NSString).appendingPathComponent(relativePath)
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func testAttributesModuleAndSourceSet() throws {
        _ = mkdir("shared/src/commonMain/kotlin/com/example")
        touch("shared/build.gradle.kts")
        touch("shared/src/commonMain/kotlin/com/example/A.kt")

        let target = GradleTargetHeuristic.target(
            forKotlinFile: "shared/src/commonMain/kotlin/com/example/A.kt", repoRoot: root
        )
        XCTAssertEqual(target, "shared/commonMain")
    }

    func testNestedModuleAndIosSourceSet() throws {
        _ = mkdir("features/auth/src/iosMain/kotlin")
        touch("features/auth/build.gradle")
        touch("features/auth/src/iosMain/kotlin/B.kt")

        let target = GradleTargetHeuristic.target(
            forKotlinFile: "features/auth/src/iosMain/kotlin/B.kt", repoRoot: root
        )
        XCTAssertEqual(target, "auth/iosMain")
    }

    func testSourceSetDiscovery() throws {
        _ = mkdir("shared/src/commonMain/kotlin")
        _ = mkdir("shared/src/iosMain/kotlin")
        touch("shared/build.gradle.kts")
        touch("shared/src/commonMain/kotlin/A.kt")
        touch("shared/src/iosMain/kotlin/B.kt")

        let targets = GradleTargetHeuristic.sourceSetTargets(repoRoot: root)
        XCTAssertEqual(targets, ["shared/commonMain", "shared/iosMain"])
    }
}

final class TaskRouterTests: XCTestCase {
    private var root: String!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-\(UUID().uuidString)").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    private func diagnostic(
        _ message: String, file: String = "Sources/App/main.swift", category: DiagnosticCategory = .sendable
    ) -> ConcurrencyDiagnostic {
        ConcurrencyDiagnostic(
            file: file, line: 7, column: 5, severity: .warning,
            category: category, message: message, diagnosticID: nil
        )
    }

    func testExtractsTypeNamesFromBoundaryDiagnostics() {
        let diagnostics = [
            diagnostic("capture of 'session' with non-sendable type 'UserSession' in a '@Sendable' closure"),
            diagnostic("type 'RegistryKt' does not conform to the 'Sendable' protocol", category: .isolation),
        ]
        XCTAssertEqual(TaskRouter.typeNames(diagnostics: diagnostics), ["UserSession"])
    }

    func testRoutesToKotlinDeclaration() throws {
        let kotlin = """
            package com.example.shared

            class UserSession(private val userID: String)
            """
        let dir = "shared/src/commonMain/kotlin/com/example"
        try FileManager.default.createDirectory(
            atPath: (root as NSString).appendingPathComponent(dir),
            withIntermediateDirectories: true
        )
        try kotlin.write(
            toFile: (root as NSString).appendingPathComponent("\(dir)/UserSession.kt"),
            atomically: true, encoding: .utf8
        )

        let task = TaskRecord(id: "t-0001", target: "KmpDemoApp", file: "Sources/KmpDemoApp/main.swift", symbols: ["(file scope)"])
        let routed = TaskRouter.kotlinFixTargets(
            diagnostics: [
                diagnostic(
                    "non-Sendable type 'UserSession' of let 'session' cannot exit main actor-isolated context",
                    file: "Sources/KmpDemoApp/main.swift"
                ),
            ],
            task: task,
            repoRoot: root
        )
        XCTAssertEqual(routed, ["shared/src/commonMain/kotlin/com/example/UserSession.kt"])
    }

    func testNoRoutingForSwiftOnlyTypes() throws {
        // No .kt files in the repo → routing finds nothing.
        let task = TaskRecord(id: "t-0001", target: "App", file: "Sources/App/main.swift")
        let routed = TaskRouter.kotlinFixTargets(
            diagnostics: [diagnostic("capture of 'x' with non-sendable type 'SwiftOnly'")],
            task: task,
            repoRoot: root
        )
        XCTAssertEqual(routed, [])
    }

    func testRoutingIsCapped() throws {
        let dir = "shared/src/commonMain/kotlin"
        try FileManager.default.createDirectory(
            atPath: (root as NSString).appendingPathComponent(dir),
            withIntermediateDirectories: true
        )
        // The same type name declared in several files (expect/actual pairs).
        for file in ["A.kt", "B.kt", "C.kt"] {
            try "expect class Shared\n".write(
                toFile: (root as NSString).appendingPathComponent("\(dir)/\(file)"),
                atomically: true, encoding: .utf8
            )
        }
        let task = TaskRecord(id: "t-0001", target: "App", file: "Sources/App/main.swift")
        let routed = TaskRouter.kotlinFixTargets(
            diagnostics: [diagnostic("capture of 'x' with non-sendable type 'Shared'")],
            task: task,
            repoRoot: root
        )
        XCTAssertEqual(routed.count, 2, "routing must not explode the edit scope")
    }
}

/// Full loop on the committed KMP boundary example: Swift-side measurement,
/// routing to the Kotlin declaration, and an executor attempt that edits both
/// sides of the boundary.
final class KmpBoundaryIntegrationTests: XCTestCase {
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    private var repo: String!

    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["STRICTMIGRATE_SKIP_INTEGRATION"] != nil)

        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("strictmigrate-kmp-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let source = Self.repoRoot.appendingPathComponent("Examples/KmpBoundary")
        for item in ["Package.swift", "Sources", "shared"] {
            try FileManager.default.copyItem(
                at: source.appendingPathComponent(item),
                to: URL(fileURLWithPath: repo).appendingPathComponent(item)
            )
        }
        _ = try Shell.run("git", arguments: ["init", "-q"], currentDirectory: repo)
        _ = try Shell.run("git", arguments: ["config", "user.email", "kmp@test"], currentDirectory: repo)
        _ = try Shell.run("git", arguments: ["config", "user.name", "kmp-test"], currentDirectory: repo)
        _ = try Shell.run("git", arguments: ["add", "-A"], currentDirectory: repo)
        _ = try Shell.run("git", arguments: ["commit", "-q", "-m", "fixture"], currentDirectory: repo)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: repo)
    }

    private static let fixedMainSwift = """
        @preconcurrency import SharedKit

        let cache = SessionCache()

        Task.detached {
            // KMP boundary fix: construct the Kotlin-exported session inside
            // the detached task so it never crosses an isolation boundary.
            let session = UserSession(userID: "u-1")
            session.touch()
            await cache.add("boot")
        }
        """

    func testMeasureSliceRouteAndExecuteAcrossTheBoundary() throws {
        // 1. Measure — Swift side of the boundary only.
        let outcome = try MeasureRunner.measureSwiftPackage(
            root: repo,
            options: SPMBuilder.Options(level: .complete, buildTests: false, extraArguments: [], scratchPath: nil)
        )
        let app = try XCTUnwrap(outcome.perTarget["KmpDemoApp"])
        XCTAssertGreaterThanOrEqual(app.sendable, 1, "capture of Kotlin-exported non-Sendable type")
        XCTAssertGreaterThanOrEqual(app.isolation, 1, "MainActor call from nonisolated task")
        XCTAssertEqual(outcome.perTarget["SharedKit"], .zero, "the shim target itself is clean")

        // Kotlin source sets appear as journal targets even before slicing.
        let mapper = HybridTargetMapper(spm: TargetMapper(targets: [
            PackageTarget(name: "SharedKit", path: "Sources/SharedKit", dependencies: []),
            PackageTarget(name: "KmpDemoApp", path: "Sources/KmpDemoApp", dependencies: ["SharedKit"]),
        ]), repoRoot: repo)
        let tallies = mapper.tally(outcome.diagnostics)
        XCTAssertEqual(tallies["shared/commonMain"], .zero, "discovered Kotlin source set gets a zero entry")

        // 2. Slice and route.
        let tasks = TaskSlicer.slice(
            diagnostics: outcome.diagnostics,
            packageRoot: repo,
            mapper: mapper,
            options: TaskSlicer.Options(targetOrder: ["SharedKit", "KmpDemoApp"], firstTaskNumber: 1)
        )
        let boundaryTask = try XCTUnwrap(tasks.first { $0.file.hasSuffix("main.swift") })

        let routed = TaskRouter.kotlinFixTargets(
            diagnostics: outcome.diagnostics, task: boundaryTask, repoRoot: repo
        )
        XCTAssertEqual(routed, ["shared/src/commonMain/kotlin/com/example/shared/UserSession.kt"])

        let prompt = TaskPrompt.render(
            task: boundaryTask,
            diagnostics: outcome.diagnostics.filter { $0.file == boundaryTask.file },
            level: .complete,
            kotlinFixTargets: routed
        )
        XCTAssertTrue(prompt.contains("KMP boundary"))
        XCTAssertTrue(prompt.contains("shared/src/commonMain/kotlin/com/example/shared/UserSession.kt"))

        // 3. Execute with an agent that edits BOTH sides — allowed because
        // routing widened the scope deterministically.
        let kotlinPath = (repo as NSString).appendingPathComponent(routed[0])
        let mainPath = (repo as NSString).appendingPathComponent(boundaryTask.file)
        let fixer = ScriptAgentAdapter(script: { _ in
            try Self.fixedMainSwift.write(toFile: mainPath, atomically: true, encoding: .utf8)
            var kotlin = try String(contentsOfFile: kotlinPath, encoding: .utf8)
            kotlin += "\n// TODO(next): make UserSession immutable for Swift 6 callers.\n"
            try kotlin.write(toFile: kotlinPath, atomically: true, encoding: .utf8)
            return AgentRunOutcome(exitCode: 0, transcript: "fixed both sides of the boundary")
        })

        var journal = Journal()
        journal.tasks = [boundaryTask]
        var executor = TaskExecutor(
            adapter: fixer,
            root: repo,
            git: GitWorkingCopy(root: repo),
            whitelist: PathWhitelist(journalPath: JournalStore.defaultFileName),
            journalPath: (repo as NSString).appendingPathComponent(JournalStore.defaultFileName),
            workDirectory: (repo as NSString).appendingPathComponent(".strictmigrate"),
            options: TaskExecutor.Options(level: .complete, buildTests: false, maxAttempts: 1),
            mapper: mapper
        )

        let reports = try executor.execute(taskIDs: [boundaryTask.id], journal: &journal) { _ in }
        XCTAssertTrue(reports[0].passed, "boundary task with routed Kotlin edit must pass")

        // One commit spanning both files — the boundary's real fix unit.
        let show = try Shell.run(
            "git", arguments: ["show", "--name-only", "--format=", "HEAD"], currentDirectory: repo
        )
        let committed = show.stdoutText.split(separator: "\n").map(String.init)
        XCTAssertEqual(Set(committed), Set([boundaryTask.file, routed[0]]))
        XCTAssertEqual(journal.tasks.first?.status, .passed)
    }
}
