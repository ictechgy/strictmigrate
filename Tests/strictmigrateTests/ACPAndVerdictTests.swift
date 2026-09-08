import XCTest

@testable import strictmigrate

final class AdapterAndVerdictTests: XCTestCase {
    func testCodexAdapterArgumentConstruction() {
        XCTAssertEqual(
            CodexAdapter.arguments(extraArguments: []),
            ["exec", "-s", "workspace-write", "--color", "never", "-"]
        )
        XCTAssertEqual(
            CodexAdapter.arguments(extraArguments: ["-m", "gpt-5.4"]),
            ["exec", "-s", "workspace-write", "--color", "never", "-", "-m", "gpt-5.4"]
        )
    }

    func testCrossTargetRegressionLabelsIncludeTheTarget() {
        let task = TaskRecord(id: "t-0001", target: "Core", file: "Sources/Core/A.swift", symbols: ["touch"])
        let before = [
            ConcurrencyDiagnostic(file: "Sources/Core/A.swift", line: 2, column: 1, severity: .error, category: .isolation, message: "m", diagnosticID: nil),
        ]
        let after = [
            ConcurrencyDiagnostic(file: "Sources/App/main.swift", line: 3, column: 1, severity: .error, category: .region, message: "m", diagnosticID: nil),
        ]

        let plain = VerdictCalculator.verdict(before: before, after: after, task: task, packageRoot: "/nonexistent")
        XCTAssertEqual(plain.regressionsElsewhere, ["Sources/App/main.swift [(file scope)] +1"])

        let attributed = VerdictCalculator.verdict(
            before: before, after: after, task: task, packageRoot: "/nonexistent",
            fileTarget: { file in file.hasPrefix("Sources/App/") ? "App" : "Core" }
        )
        XCTAssertEqual(attributed.regressionsElsewhere, ["App:Sources/App/main.swift [(file scope)] +1"])
    }
}

final class TestRunnerParsingTests: XCTestCase {
    private func outcome(_ text: String, exit: Int32 = 0) -> TestRunOutcome {
        TestRunner.parse(exitCode: exit, output: text)
    }

    func testParsesXCTestSummary() {
        let text = """
            Test Suite 'All tests' passed at 2026-09-06.
            Executed 12 tests, with 0 failures (0 unexpected) in 0.3s
            """
        let result = outcome(text)
        XCTAssertEqual(result.executed, 12)
        XCTAssertEqual(result.failures, 0)
        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.summaryLabel, "12/12")
    }

    func testPrefersLastXCTestSummaryLine() {
        let text = """
            Test Suite 'CoreTests' failed at 2026-09-06.
            Executed 4 tests, with 1 failure (1 unexpected) in 0.1s
            Test Suite 'AllTests' failed at 2026-09-06.
            Executed 8 tests, with 2 failures (2 unexpected) in 0.2s
            """
        let result = outcome(text, exit: 1)
        XCTAssertEqual(result.executed, 8)
        XCTAssertEqual(result.failures, 2)
        XCTAssertEqual(result.summaryLabel, "6/8")
    }

    func testParsesSwiftTestingCount() {
        let result = outcome("Test run with 5 tests passed after 0.2 seconds")
        XCTAssertEqual(result.executed, 5)
        XCTAssertEqual(result.failures, 0)
        XCTAssertTrue(result.passed)
    }

    func testFailureWithoutParsableSummaryFails() {
        let result = outcome("Fatal error: something broke", exit: 70)
        XCTAssertNil(result.executed)
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.summaryLabel, "failed")
    }

    func testCountsThreadSanitizerReports() {
        let text = """
            Executed 3 tests, with 0 failures in 0.1s
            ==================
            WARNING: ThreadSanitizer: Swift access race
            WARNING: ThreadSanitizer: data race
            """
        let result = outcome(text)
        XCTAssertEqual(result.tsanRaces, 2)
        XCTAssertFalse(result.passed, "races must fail the verdict even with green tests")
    }
}

/// End-to-end ACP adapter test against a Python mock agent that speaks the
/// protocol over stdio and applies the known spawnWork fix when prompted.
final class ACPAdapterTests: XCTestCase {
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    private var repo: String!
    private var mockAgentPath: String!

    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["STRICTMIGRATE_SKIP_INTEGRATION"] != nil)
        try XCTSkipIf(Shell.run("/usr/bin/env", arguments: ["python3", "--version"]).exitCode != 0)

        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("strictmigrate-acp-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let source = Self.repoRoot.appendingPathComponent("Examples/DemoConcurrency")
        for item in ["Package.swift", "Sources"] {
            try FileManager.default.copyItem(at: source.appendingPathComponent(item), to: URL(fileURLWithPath: repo).appendingPathComponent(item))
        }

        mockAgentPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("strictmigrate-mock-acp-\(UUID().uuidString).py").path
        try Self.mockAgentSource.write(toFile: mockAgentPath, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: repo)
        try? FileManager.default.removeItem(atPath: mockAgentPath)
    }

    /// A minimal ACP agent: handshakes, opens sessions, and "fixes" the demo
    /// package's spawnWork when prompted (after streaming a message chunk).
    /// The fix is applied by rewriting the function body via regex so the
    /// mock never depends on exact fixture indentation.
    private static let mockAgentSource = """
        import json
        import os
        import re
        import sys


        def send(obj):
            sys.stdout.write(json.dumps(obj) + "\\n")
            sys.stdout.flush()


        def send_response(request_id, result):
            send({"jsonrpc": "2.0", "id": request_id, "result": result})


        def notify(method, params):
            send({"jsonrpc": "2.0", "method": method, "params": params})


        BODY = re.compile(
            r"(public static func spawnWork\\(\\) \\{\\n).*?(\\n    \\})",
            re.S,
        )
        # \\\\1 in this Swift literal reaches python as \\1 — re.sub's group
        # reference. (A single \\\\ would become the \\x01 control character in
        # python, silently corrupting the fixture; the executor's
        # untrustworthy-measurement gate now reverts such edits instead of
        # committing them, so the mock has to produce clean Swift.)
        REPLACEMENT = (
            "\\\\1        Task { @MainActor in\\n"
            "            let renderer = ThumbnailRenderer()\\n"
            "            renderer.theme = \\"dark\\"\\n"
            "        }\\\\2"
        )


        for line in sys.stdin:
            if not line.strip():
                continue
            message = json.loads(line)
            method = message.get("method")
            if method == "initialize":
                send_response(message["id"], {
                    "protocolVersion": 1,
                    "agentCapabilities": {"loadSession": False},
                    "authMethods": [],
                })
            elif method == "session/new":
                send_response(message["id"], {"sessionId": "s-1"})
            elif method == "session/prompt":
                notify("session/update", {
                    "sessionId": message["params"]["sessionId"],
                    "update": {
                        "sessionUpdate": "agent_message_chunk",
                        "content": {"type": "text", "text": "Moving renderer creation into the MainActor task."},
                    },
                })
                path = os.path.join(os.getcwd(), "Sources/ImagePipelineCore/Renderer.swift")
                with open(path) as handle:
                    text = handle.read()
                text, _ = BODY.subn(REPLACEMENT, text)
                with open(path, "w") as handle:
                    handle.write(text)
                send_response(message["id"], {"stopReason": "end_turn", "usage": {}})
            # notifications (initialized) and anything else: ignored
        """

    func testACPAdapterHandshakePromptAndEdit() throws {
        let adapter = ACPAdapter(commandLine: "python3 \(mockAgentPath!)")
        let promptPath = (repo as NSString).appendingPathComponent(".strictmigrate/prompt-test.md")
        try FileManager.default.createDirectory(
            atPath: (repo as NSString).appendingPathComponent(".strictmigrate"),
            withIntermediateDirectories: true
        )
        try "task prompt".write(toFile: promptPath, atomically: true, encoding: .utf8)

        let outcome = try adapter.run(
            AgentInvocation(prompt: "task prompt", promptFilePath: promptPath, workingDirectory: repo, taskID: "t-0001")
        )

        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertTrue(outcome.transcript.contains("Moving renderer creation into the MainActor task."))
        XCTAssertTrue(outcome.transcript.contains("stopReason=end_turn"))

        let fixed = try String(
            contentsOfFile: (repo as NSString).appendingPathComponent("Sources/ImagePipelineCore/Renderer.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(fixed.contains("Task { @MainActor in"), "mock agent must have applied the fix")
    }

    func testExecutorLoopThroughACPAdapter() throws {
        // Full production loop with the ACP adapter: measure → dispatch via
        // ACP → scope check → verdict → commit.
        _ = try Shell.run("git", arguments: ["init", "-q"], currentDirectory: repo)
        _ = try Shell.run("git", arguments: ["config", "user.email", "acp@test"], currentDirectory: repo)
        _ = try Shell.run("git", arguments: ["config", "user.name", "acp-test"], currentDirectory: repo)
        _ = try Shell.run("git", arguments: ["add", "-A"], currentDirectory: repo)
        _ = try Shell.run("git", arguments: ["commit", "-q", "-m", "fixture"], currentDirectory: repo)

        var journal = Journal()
        journal.tasks = [
            TaskRecord(
                id: "t-0003", target: "ImagePipelineCore",
                file: "Sources/ImagePipelineCore/Renderer.swift",
                symbols: ["spawnWork"], diagnostics: ["actor-isolation×2"]
            ),
        ]

        let journalPath = (repo as NSString).appendingPathComponent(JournalStore.defaultFileName)
        let executor = TaskExecutor(
            adapter: ACPAdapter(commandLine: "python3 \(mockAgentPath!)"),
            root: repo,
            git: GitWorkingCopy(root: repo),
            whitelist: PathWhitelist(journalPath: JournalStore.defaultFileName),
            journalPath: journalPath,
            workDirectory: (repo as NSString).appendingPathComponent(".strictmigrate"),
            options: TaskExecutor.Options(level: .complete, buildTests: false, maxAttempts: 2)
        )

        var mutableJournal = journal
        let reports = try executor.execute(taskIDs: ["t-0003"], journal: &mutableJournal) { line in
            print("   [acp-loop] \(line)")
        }

        if !reports.isEmpty, !reports[0].passed {
            print("   [acp-loop] attempt notes: \(mutableJournal.tasks.first?.notes ?? [])")
        }

        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(reports[0].passed, "ACP-driven attempt should pass and commit")
        XCTAssertEqual(mutableJournal.tasks.first?.status, .passed)
        XCTAssertFalse(mutableJournal.tasks.first?.commits.isEmpty ?? true)
    }
}
