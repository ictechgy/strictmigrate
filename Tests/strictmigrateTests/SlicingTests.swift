import XCTest

@testable import strictmigrate

final class SymbolLocatorTests: XCTestCase {
    let rendererSource = """
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
                let renderer = ThumbnailRenderer()
                Task {
                    // MainActor-isolated state touched from a nonisolated task.
                    renderer.theme = "dark" // brace in string "}" below
                }
            }
        }
        """

    func testFindsDeclarationsAndSpans() {
        let symbols = SymbolLocator.symbols(in: rendererSource)
        let names = symbols.map(\.name)

        XCTAssertTrue(names.contains("ThumbnailRenderer"))
        XCTAssertTrue(names.contains("render"))
        XCTAssertTrue(names.contains("renderSync"))
        XCTAssertTrue(names.contains("spawnWork"))
        XCTAssertTrue(names.contains("theme"))
        // The local `renderer`/`Task` lines inside spawnWork must not create symbols.
        XCTAssertFalse(names.contains("renderer"))
        XCTAssertFalse(names.contains("Task"))
    }

    func testInnermostPrefersDeepestStart() {
        let symbols = SymbolLocator.symbols(in: rendererSource)
        let renderSync = symbols.first { $0.name == "renderSync" }
        XCTAssertNotNil(renderSync)

        // A diagnostic on the renderer.render line belongs to renderSync,
        // not to the enclosing enum.
        let line = renderSync!.startLine + 1
        let innermost = SymbolLocator.innermostSymbol(containingLine: line, in: symbols)
        XCTAssertEqual(innermost?.name, "renderSync")
        XCTAssertEqual(innermost?.kind, "func")
    }

    func testTypeLevelPropertyIsASymbol() {
        let symbols = SymbolLocator.symbols(in: rendererSource)
        let theme = symbols.first { $0.name == "theme" }
        XCTAssertNotNil(theme)
        // Diagnostics on the declaration line itself map to the property.
        XCTAssertEqual(SymbolLocator.innermostSymbol(containingLine: theme!.startLine, in: symbols)?.name, "theme")
    }

    func testIgnoresBracesInStringsAndComments() {
        let source = """
            struct Holder {
                // } fake close in comment
                let text = "}{ unbalanced }{"
                var open = true /* } */
                func probe() -> String { text }
            }
            """
        let symbols = SymbolLocator.symbols(in: source)
        // Holder + three members; single-line var/let close on their own line.
        XCTAssertEqual(symbols.count, 4)
        XCTAssertTrue(symbols.contains { $0.name == "Holder" && $0.kind == "struct" })
        XCTAssertTrue(symbols.contains { $0.name == "text" && $0.kind == "let" })
        XCTAssertTrue(symbols.contains { $0.name == "open" && $0.kind == "var" })
        XCTAssertTrue(symbols.contains { $0.name == "probe" && $0.kind == "func" })
        // Holder must span to the real closing brace (line 6), not a fake one.
        let holder = symbols.first { $0.name == "Holder" }
        XCTAssertEqual(holder?.endLine, 6)
    }

    func testTopLevelCodeIsFileScope() {
        let symbols: [SymbolRange] = []
        let diagnostic = ConcurrencyDiagnostic(
            file: "Sources/App/main.swift", line: 3, column: 1, severity: .warning,
            category: .region, message: "sending 'x' risks causing data races", diagnosticID: nil
        )
        XCTAssertEqual(SymbolLocator.symbolName(for: diagnostic, symbols: symbols), "(file scope)")
    }
}

final class TargetPriorityTests: XCTestCase {
    func testLeafFirstOrder() {
        // App → Core, App → UI, UI → Core, Tests → App. Core has no deps.
        let order = TargetPriority.leafFirstOrder(dependencies: [
            "App": ["Core", "UI"],
            "UI": ["Core"],
            "Core": [],
            "AppTests": ["App"],
        ])
        XCTAssertEqual(order.first, "Core")
        XCTAssertTrue(order.firstIndex(of: "UI")! < order.firstIndex(of: "App")!)
        XCTAssertTrue(order.firstIndex(of: "App")! < order.firstIndex(of: "AppTests")!)
        XCTAssertEqual(Set(order), Set(["App", "UI", "Core", "AppTests"]))
    }

    func testCycleDoesNotHang() {
        let order = TargetPriority.leafFirstOrder(dependencies: [
            "A": ["B"],
            "B": ["A"],
        ])
        XCTAssertEqual(Set(order), Set(["A", "B"]))
    }
}

final class TaskSlicerTests: XCTestCase {
    private func writeSources(root: String) throws {
        let core = (root as NSString).appendingPathComponent("Sources/Core")
        try FileManager.default.createDirectory(atPath: core, withIntermediateDirectories: true)
        try """
        public final class Thing {
            public var state = 0          // line 2
            public func touch() async {
                state += 1                 // line 4
            }
        }
        """.write(toFile: (core as NSString).appendingPathComponent("Thing.swift"), atomically: true, encoding: .utf8)
    }

    private func diagnostic(
        _ file: String, _ line: Int, _ category: DiagnosticCategory, message: String
    ) -> ConcurrencyDiagnostic {
        ConcurrencyDiagnostic(
            file: file, line: line, column: 5, severity: .warning,
            category: category, message: message, diagnosticID: nil
        )
    }

    func testClustersBySymbolAndOrdersLeafFirst() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("slicer-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try writeSources(root: root)

        let mapper = TargetMapper(targets: [
            PackageTarget(name: "Core", path: "Sources/Core", dependencies: []),
            PackageTarget(name: "App", path: "Sources/App", dependencies: ["Core"]),
        ])
        let diagnostics = [
            diagnostic("Sources/Core/Thing.swift", 2, .sendable, message: "type 'Thing' does not conform to the 'Sendable' protocol"),
            diagnostic("Sources/Core/Thing.swift", 4, .isolation, message: "actor-isolated property 'state' can not be mutated"),
            diagnostic("Sources/Core/Thing.swift", 5, .isolation, message: "main actor-isolated property 'x' can not be mutated"),
            diagnostic("Sources/App/main.swift", 3, .region, message: "sending 'thing' risks causing data races"),
        ]

        let tasks = TaskSlicer.slice(
            diagnostics: diagnostics,
            packageRoot: root,
            mapper: mapper,
            options: TaskSlicer.Options(targetOrder: ["Core", "App"], firstTaskNumber: 1)
        )

        // Leaf target (Core) first; two symbols in Thing.swift → two tasks;
        // main.swift has no symbols → file-scope task.
        XCTAssertEqual(tasks.map(\.target), ["Core", "Core", "App"])
        XCTAssertEqual(tasks[0].symbols, ["state"], "line 2 sits on the property")
        XCTAssertEqual(tasks[0].diagnostics, ["sendable-violation×1"])
        XCTAssertEqual(tasks[1].symbols, ["touch"])
        XCTAssertEqual(tasks[1].diagnostics, ["actor-isolation×2"])
        XCTAssertEqual(tasks[2].symbols, ["(file scope)"])
        XCTAssertEqual(tasks.map(\.id), ["t-0001", "t-0002", "t-0003"])

        // Fewer diagnostics first within the same target.
        XCTAssertEqual(tasks[0].diagnostics.count, 1)
        XCTAssertEqual(tasks[1].diagnostics.count, 1)
    }

    func testSummariesFollowJournalStyle() {
        let diagnostics = [
            diagnostic("a", 1, .sendable, message: "s1"),
            diagnostic("a", 2, .sendable, message: "s2"),
            diagnostic("a", 3, .isolation, message: "i1"),
            diagnostic("a", 4, .region, message: "r1"),
        ]
        XCTAssertEqual(
            TaskSlicer.summaries(for: diagnostics),
            ["sendable-violation×2", "actor-isolation×1", "region-violation×1"]
        )
    }
}

final class TaskLifecycleTests: XCTestCase {
    private func makeRoot() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifecycle-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let file = (root as NSString).appendingPathComponent("Sources/Core/Thing.swift")
        try FileManager.default.createDirectory(
            atPath: (root as NSString).appendingPathComponent("Sources/Core"),
            withIntermediateDirectories: true
        )
        try """
        public final class Thing {
            public var state = 0
            public func touch() {}
        }
        """.write(toFile: file, atomically: true, encoding: .utf8)
        return root
    }

    private func diagnostic(_ line: Int, _ category: DiagnosticCategory) -> ConcurrencyDiagnostic {
        ConcurrencyDiagnostic(
            file: "Sources/Core/Thing.swift", line: line, column: 5, severity: .error,
            category: category, message: "m", diagnosticID: nil
        )
    }

    func testNextNumberContinuesFromHistory() {
        var journal = Journal()
        journal.tasks = [
            TaskRecord(id: "t-0002", target: "A", file: "a.swift"),
            TaskRecord(id: "t-0010", target: "A", file: "a.swift"),
        ]
        XCTAssertEqual(journal.nextTaskNumber, 11)
    }

    func testReplaceQueueDropsOnlyQueued() {
        var journal = Journal()
        journal.tasks = [
            TaskRecord(id: "t-0001", target: "A", file: "a.swift", status: .queued),
            TaskRecord(id: "t-0002", target: "A", file: "b.swift", status: .assigned),
            TaskRecord(id: "t-0003", target: "A", file: "c.swift", status: .passed),
        ]
        let dropped = journal.replaceQueue(with: [
            TaskRecord(id: "t-0004", target: "A", file: "d.swift"),
        ])
        XCTAssertEqual(dropped, 1)
        XCTAssertEqual(journal.tasks.map(\.id), ["t-0002", "t-0003", "t-0004"])
        XCTAssertEqual(journal.tasks.map(\.status), [.assigned, .passed, .queued])
    }

    func testReconcileClosesCleanTasksAndKeepsPartialOnes() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        var journal = Journal()
        journal.tasks = [
            TaskRecord(id: "t-0001", target: "Core", file: "Sources/Core/Thing.swift", symbols: ["state"], status: .assigned),
            TaskRecord(id: "t-0002", target: "Core", file: "Sources/Core/Thing.swift", symbols: ["touch"], status: .queued),
        ]

        // Only the `state` diagnostics were fixed; `touch` still fails.
        let closed = journal.reconcileTasks(
            against: [diagnostic(3, .isolation)],
            packageRoot: root,
            buildExitCode: 1
        )

        XCTAssertEqual(closed, ["t-0001"])
        XCTAssertEqual(journal.tasks.first { $0.id == "t-0001" }?.status, .passed)
        XCTAssertEqual(journal.tasks.first { $0.id == "t-0001" }?.verdict?.build, "fail", "overall build still fails — recorded honestly")
        XCTAssertEqual(journal.tasks.first { $0.id == "t-0002" }?.status, .queued)
    }

    func testNextAndMarkAssigned() {
        var journal = Journal()
        journal.tasks = [
            TaskRecord(id: "t-0001", target: "Core", file: "a.swift", status: .passed),
            TaskRecord(id: "t-0002", target: "Core", file: "b.swift"),
            TaskRecord(id: "t-0003", target: "Core", file: "c.swift"),
        ]
        XCTAssertEqual(journal.nextQueuedTask?.id, "t-0002")
        XCTAssertTrue(journal.markAssigned(id: "t-0002"))
        XCTAssertFalse(journal.markAssigned(id: "t-0002"), "already assigned")
        XCTAssertEqual(journal.nextQueuedTask?.id, "t-0003")
    }
}

final class TaskPromptTests: XCTestCase {
    func testRenderContainsBoundariesAndVerification() {
        let task = TaskRecord(
            id: "t-0007",
            target: "Core",
            file: "Sources/Core/Thing.swift",
            symbols: ["touch"],
            diagnostics: ["actor-isolation×1"]
        )
        let diagnostics = [
            ConcurrencyDiagnostic(
                file: "Sources/Core/Thing.swift", line: 4, column: 9, severity: .error,
                category: .isolation, message: "actor-isolated property 'x' can not be mutated", diagnosticID: nil
            ),
        ]
        let prompt = TaskPrompt.render(task: task, diagnostics: diagnostics, level: .complete)

        XCTAssertTrue(prompt.contains("Task t-0007 — target Core"))
        XCTAssertTrue(prompt.contains("Symbol(s): touch"))
        XCTAssertTrue(prompt.contains("4:9 [isolation] error:"))
        XCTAssertTrue(prompt.contains("Modify ONLY `Sources/Core/Thing.swift`"))
        XCTAssertTrue(prompt.contains("-strict-concurrency=complete"))
        XCTAssertTrue(prompt.contains("strictmigrate measure"))
    }

    func testRenderFallsBackToSummariesWithoutLocations() {
        let task = TaskRecord(id: "t-0008", target: "Core", file: "a.swift", symbols: ["x"], diagnostics: ["sendable-violation×2"])
        let prompt = TaskPrompt.render(task: task, diagnostics: [], level: .targeted)
        XCTAssertTrue(prompt.contains("sendable-violation×2"))
    }
}
