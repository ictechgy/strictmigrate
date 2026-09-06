import XCTest

@testable import strictmigrate

/// Executor tests run the full loop — real swift builds, real git commits —
/// against a disposable copy of Examples/DemoConcurrency. The agent is faked
/// (or a shell script), everything else is production code.
final class ExecutorTests: XCTestCase {
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    private var repo: String!

    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["STRICTMIGRATE_SKIP_INTEGRATION"] != nil)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("strictmigrate-exec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let source = Self.repoRoot.appendingPathComponent("Examples/DemoConcurrency")
        for item in ["Package.swift", "Sources"] {
            try FileManager.default.copyItem(
                at: source.appendingPathComponent(item),
                to: destination.appendingPathComponent(item)
            )
        }
        repo = destination.path
        try Self.git(["init", "-q"], in: repo)
        try Self.git(["config", "user.email", "strictmigrate@test"], in: repo)
        try Self.git(["config", "user.name", "strictmigrate-test"], in: repo)
        try Self.git(["add", "-A"], in: repo)
        try Self.git(["commit", "-q", "-m", "fixture"], in: repo)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: repo)
    }

    private static func git(_ arguments: [String], in directory: String) throws {
        let result = try Shell.run("git", arguments: arguments, currentDirectory: directory)
        guard result.exitCode == 0 else {
            throw NSError(domain: "git", code: Int(result.exitCode),
                          userInfo: [NSLocalizedDescriptionKey: result.stderrText])
        }
    }

    private func makeExecutor(adapter: AgentAdapter, maxAttempts: Int = 2) -> TaskExecutor {
        let journalPath = (repo as NSString).appendingPathComponent(JournalStore.defaultFileName)
        return TaskExecutor(
            adapter: adapter,
            root: repo,
            git: GitWorkingCopy(root: repo),
            whitelist: PathWhitelist(journalPath: JournalStore.defaultFileName),
            journalPath: journalPath,
            workDirectory: (repo as NSString).appendingPathComponent(".strictmigrate"),
            options: TaskExecutor.Options(level: .complete, buildTests: false, maxAttempts: maxAttempts)
        )
    }

    private func journalWithSpawnWorkTask() -> Journal {
        var journal = Journal()
        journal.tasks = [
            TaskRecord(
                id: "t-0003",
                target: "ImagePipelineCore",
                file: "Sources/ImagePipelineCore/Renderer.swift",
                symbols: ["spawnWork"],
                diagnostics: ["actor-isolation×2"]
            ),
        ]
        return journal
    }

    private func fileContents(_ relativePath: String) throws -> String {
        try String(
            contentsOfFile: (repo as NSString).appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    /// The known-good fix for spawnWork (moves the renderer into the
    /// MainActor task), used by the fakes and asserted against after runs.
    private static let spawnWorkFixed = """
        import Foundation

        @MainActor
        public final class ThumbnailRenderer {
            public var theme: String = "light"

            public init() {}

            public func render(name: String) -> String {
                "\\(theme):\\(name).png"
            }
        }

        public enum RenderService {
            /// Calls a MainActor-isolated method from a nonisolated context.
            public static func renderSync(_ renderer: ThumbnailRenderer) -> String {
                renderer.render(name: "avatar")
            }

            public static func spawnWork() {
                Task { @MainActor in
                    let renderer = ThumbnailRenderer()
                    renderer.theme = "dark"
                }
            }
        }
        """

    func testPassPathCommitsAndClosesTask() throws {
        let fixer = ScriptAgentAdapter(script: { repo in
            let path = (repo as NSString).appendingPathComponent("Sources/ImagePipelineCore/Renderer.swift")
            try Self.spawnWorkFixed.write(toFile: path, atomically: true, encoding: .utf8)
            return AgentRunOutcome(exitCode: 0, transcript: "fixed spawnWork")
        })
        var journal = journalWithSpawnWorkTask()
        var executor = makeExecutor(adapter: fixer)

        let reports = try executor.execute(taskIDs: ["t-0003"], journal: &journal) { _ in }

        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(reports[0].passed)
        XCTAssertEqual(reports[0].attempts.count, 1)

        // Journal: task passed with the commit recorded; target shrank 3 → 1.
        let task = journal.tasks.first { $0.id == "t-0003" }
        XCTAssertEqual(task?.status, .passed)
        XCTAssertEqual(task?.commits.count, 1)
        XCTAssertEqual(journal.targets["ImagePipelineCore"]?.diagnosticsBaseline.isolation, 1)

        // Git: exactly one new commit, tree clean afterwards.
        let log = try Shell.run("git", arguments: ["log", "--oneline"], currentDirectory: repo)
        XCTAssertTrue(log.stdoutText.contains("strictmigrate(t-0003)"))
        XCTAssertTrue(try GitWorkingCopy(root: repo).isClean(allowing: PathWhitelist(journalPath: JournalStore.defaultFileName)))
        XCTAssertEqual(try fileContents("Sources/ImagePipelineCore/Renderer.swift"), Self.spawnWorkFixed)
    }

    func testFailedAttemptRevertsAndExhaustsToReverted() throws {
        let noop = ScriptAgentAdapter(script: { _ in
            AgentRunOutcome(exitCode: 0, transcript: "I did nothing")
        })
        var journal = journalWithSpawnWorkTask()
        var executor = makeExecutor(adapter: noop, maxAttempts: 2)

        let reports = try executor.execute(taskIDs: ["t-0003"], journal: &journal) { _ in }

        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].finalStatus, .reverted)
        XCTAssertEqual(reports[0].attempts.count, 2, "both attempts run")

        let task = journal.tasks.first { $0.id == "t-0003" }
        XCTAssertEqual(task?.status, .reverted)
        XCTAssertEqual(task?.attempts, 2)
        XCTAssertEqual(task?.commits, [])
        XCTAssertEqual(task?.notes.count, 2)
        XCTAssertTrue(task?.notes.first?.contains("insufficient") ?? false)

        // The fixture file is untouched and the tree is clean.
        let original = try fileContents("Sources/ImagePipelineCore/Renderer.swift")
        XCTAssertTrue(original.contains("renderer.theme = \"dark\""))
        XCTAssertTrue(original.contains("let renderer = ThumbnailRenderer()"))
        XCTAssertTrue(try GitWorkingCopy(root: repo).isClean(allowing: PathWhitelist(journalPath: JournalStore.defaultFileName)))
    }

    func testScopeViolationIsAutoReverted() throws {
        let outlaw = ScriptAgentAdapter(script: { repo in
            let outside = (repo as NSString).appendingPathComponent("Sources/ImagePipelineCore/Pipeline.swift")
            var text = try String(contentsOfFile: outside, encoding: .utf8)
            text += "\n// agent left a stray edit\n"
            try text.write(toFile: outside, atomically: true, encoding: .utf8)
            return AgentRunOutcome(exitCode: 0, transcript: "edited the wrong file")
        })
        var journal = journalWithSpawnWorkTask()
        var executor = makeExecutor(adapter: outlaw, maxAttempts: 1)

        let reports = try executor.execute(taskIDs: ["t-0003"], journal: &journal) { _ in }

        XCTAssertEqual(reports[0].finalStatus, .reverted)
        XCTAssertEqual(reports[0].attempts.first?.scopeViolations, ["Sources/ImagePipelineCore/Pipeline.swift"])
        XCTAssertTrue(reports[0].attempts.first?.note.contains("scope violation") ?? false)

        // The stray edit is gone.
        XCTAssertFalse(try fileContents("Sources/ImagePipelineCore/Pipeline.swift").contains("stray edit"))
        XCTAssertTrue(try GitWorkingCopy(root: repo).isClean(allowing: PathWhitelist(journalPath: JournalStore.defaultFileName)))
    }

    func testCleanTreePreconditionStopsTheRun() throws {
        // Dirty the tree outside the whitelist before executing.
        let extra = (repo as NSString).appendingPathComponent("Sources/ImagePipelineCore/extra.swift")
        try "// unrelated dirty file\n".write(toFile: extra, atomically: true, encoding: .utf8)

        let fixer = ScriptAgentAdapter(script: { _ in AgentRunOutcome(exitCode: 0, transcript: "should not run") })
        var journal = journalWithSpawnWorkTask()
        var executor = makeExecutor(adapter: fixer)

        let reports = try executor.execute(taskIDs: ["t-0003"], journal: &journal) { _ in }
        XCTAssertTrue(reports.isEmpty, "executor must refuse to run on a dirty tree")
        XCTAssertEqual(journal.tasks.first?.status, .queued, "task stays queued")
    }

    func testCommandAdapterEndToEnd() throws {
        // The generic shell adapter applies the fix via a script — proves the
        // non-claude vendor path (v0.4 codex/ACP will use the same seam).
        // The script lives OUTSIDE the repo: an untracked file would trip the
        // clean-tree precondition, exactly as it should.
        let fixScript = FileManager.default.temporaryDirectory
            .appendingPathComponent("strictmigrate-fix-\(UUID().uuidString).sh").path
        defer { try? FileManager.default.removeItem(atPath: fixScript) }
        try """
        #!/bin/sh
        cat "$STRICTMIGRATE_PROMPT_FILE" > /dev/null
        cat > "Sources/ImagePipelineCore/Renderer.swift" <<'SWIFT'
        \(Self.spawnWorkFixed)
        SWIFT
        """.write(toFile: fixScript, atomically: true, encoding: .utf8)

        let adapter = CommandAdapter(commandLine: "sh \(fixScript)")
        var journal = journalWithSpawnWorkTask()
        var executor = makeExecutor(adapter: adapter)

        let reports = try executor.execute(taskIDs: ["t-0003"], journal: &journal) { _ in }
        let report = try XCTUnwrap(reports.first)
        XCTAssertTrue(report.passed)
        XCTAssertEqual(journal.tasks.first?.status, .passed)
    }
}

/// Test double: runs a closure against the working directory instead of an
/// LLM. Production code paths (measure, verdict, git) are all real.
struct ScriptAgentAdapter: AgentAdapter {
    var name: String { "script" }
    var script: @Sendable (String) throws -> AgentRunOutcome

    func run(_ invocation: AgentInvocation) throws -> AgentRunOutcome {
        try script(invocation.workingDirectory)
    }
}

final class VerdictCalculatorTests: XCTestCase {
    private let task = TaskRecord(
        id: "t-0001", target: "Core", file: "Sources/Core/A.swift",
        symbols: ["touch"], diagnostics: []
    )

    private var packageRoot: String!

    override func setUp() {
        super.setUp()
        // Real sources so diagnostics resolve to real enclosing symbols.
        packageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("verdict-\(UUID().uuidString)").path
        let core = (packageRoot as NSString).appendingPathComponent("Sources/Core")
        try? FileManager.default.createDirectory(atPath: core, withIntermediateDirectories: true)
        try? """
        func touch() {
            other()
        }
        """.write(toFile: (core as NSString).appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try? """
        func other() {}
        """.write(toFile: (core as NSString).appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: packageRoot)
        super.tearDown()
    }

    private func diagnostic(_ file: String, _ line: Int) -> ConcurrencyDiagnostic {
        ConcurrencyDiagnostic(
            file: file, line: line, column: 1, severity: .error,
            category: .isolation, message: "m", diagnosticID: nil
        )
    }

    func testPassWhenTaskCleanAndNoRegressions() {
        let before = [diagnostic("Sources/Core/A.swift", 2), diagnostic("Sources/Core/B.swift", 2)]
        let after = [diagnostic("Sources/Core/B.swift", 2)]
        let verdict = VerdictCalculator.verdict(before: before, after: after, task: task, packageRoot: packageRoot)
        XCTAssertTrue(verdict.passed)
    }

    func testFailWhenTaskNotClean() {
        let before = [diagnostic("Sources/Core/A.swift", 2)]
        let after = [diagnostic("Sources/Core/A.swift", 2)]
        let verdict = VerdictCalculator.verdict(before: before, after: after, task: task, packageRoot: packageRoot)
        XCTAssertFalse(verdict.passed)
        XCTAssertFalse(verdict.taskClean)
        XCTAssertTrue(verdict.regressionsElsewhere.isEmpty)
    }

    func testFailWhenNewDiagnosticsElsewhereEvenIfTotalDropped() {
        // Task fixed its 1 diagnostic but introduced 1 elsewhere: the total is
        // unchanged, and the verdict must still fail — regressions are checked
        // per symbol, not in aggregate.
        let before = [diagnostic("Sources/Core/A.swift", 2)]
        let after = [diagnostic("Sources/Core/B.swift", 1)]
        let verdict = VerdictCalculator.verdict(before: before, after: after, task: task, packageRoot: packageRoot)
        XCTAssertFalse(verdict.passed)
        XCTAssertEqual(verdict.regressionsElsewhere, ["Sources/Core/B.swift [other] +1"])
    }
}

final class GitWorkingCopyTests: XCTestCase {
    private var repo: String!

    override func setUp() {
        super.setUp()
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("strictmigrate-git-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = try? Shell.run("git", arguments: ["init", "-q"], currentDirectory: repo)
        _ = try? Shell.run("git", arguments: ["config", "user.email", "t@t"], currentDirectory: repo)
        _ = try? Shell.run("git", arguments: ["config", "user.name", "t"], currentDirectory: repo)
        try? "hello\n".write(toFile: (repo as NSString).appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try? Shell.run("git", arguments: ["add", "-A"], currentDirectory: repo)
        _ = try? Shell.run("git", arguments: ["commit", "-q", "-m", "init"], currentDirectory: repo)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: repo)
        super.tearDown()
    }

    func testCleanDirtyAndDiscard() throws {
        let git = GitWorkingCopy(root: repo)
        try git.requireRepository()
        XCTAssertTrue(try git.isClean(allowing: PathWhitelist(journalPath: "j.yaml")))

        // Modified tracked file.
        try "changed\n".write(toFile: (repo as NSString).appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        // Untracked file.
        try "new\n".write(toFile: (repo as NSString).appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let changes = try git.changes()
        XCTAssertEqual(Set(changes.map(\.path)), ["a.txt", "b.txt"])

        try git.discard(paths: ["a.txt", "b.txt"])
        XCTAssertTrue(try git.isClean(allowing: PathWhitelist(journalPath: "j.yaml")))
        XCTAssertEqual(try String(contentsOfFile: (repo as NSString).appendingPathComponent("a.txt"), encoding: .utf8), "hello\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: (repo as NSString).appendingPathComponent("b.txt")))
    }

    func testCommitScopesToGivenPaths() throws {
        let git = GitWorkingCopy(root: repo)
        try "changed\n".write(toFile: (repo as NSString).appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(toFile: (repo as NSString).appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let hash = try git.commit(paths: ["a.txt"], message: "scoped")
        XCTAssertFalse(hash.isEmpty)
        XCTAssertEqual(try git.shortHEAD(), hash)
        // b.txt remains uncommitted.
        XCTAssertEqual(try git.changes().map(\.path), ["b.txt"])
    }

    func testWhitelistAllowsHarnessPathsOnly() {
        let whitelist = PathWhitelist(journalPath: "strictmigrate.yaml.journal")
        XCTAssertTrue(whitelist.allows("strictmigrate.yaml.journal"))
        XCTAssertTrue(whitelist.allows(".strictmigrate/last-build.log"))
        XCTAssertTrue(whitelist.allows(".build/x"))
        // Agent-harness session state is bookkeeping, not code edits.
        XCTAssertTrue(whitelist.allows(".omc/state/session.json"))
        XCTAssertTrue(whitelist.allows(".claude/settings.json"))
        XCTAssertTrue(whitelist.allows(".codex/history.jsonl"))
        XCTAssertTrue(whitelist.allows(".serena/project.yml"))
        XCTAssertFalse(whitelist.allows("Sources/Core/A.swift"))
        XCTAssertFalse(whitelist.allows("strictmigrate.yaml.journal.bak"))
        XCTAssertFalse(whitelist.allows("CLAUDE.md"))
    }
}
