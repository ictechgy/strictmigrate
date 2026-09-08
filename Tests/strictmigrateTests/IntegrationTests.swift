import XCTest

@testable import strictmigrate

/// End-to-end pipeline against the committed demo package in
/// `Examples/DemoConcurrency` (copied to a scratch directory first).
/// Exercises the real toolchain: swift build, log parsing, target attribution,
/// journal merge, and status rendering. Runs a full compile — slow by design.
final class SPMIntegrationTests: XCTestCase {
    private static let repoRoot: URL = {
        // …/Tests/strictmigrateTests/IntegrationTests.swift → package root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    private func copyDemoPackage() throws -> String {
        let source = Self.repoRoot.appendingPathComponent("Examples/DemoConcurrency")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("strictmigrate-integration-\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in ["Package.swift", "Sources"] {
            try FileManager.default.copyItem(
                at: source.appendingPathComponent(item),
                to: destination.appendingPathComponent(item)
            )
        }
        return destination.path
    }

    func testMeasureSwiftPackageCollectsAllCategories() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["STRICTMIGRATE_SKIP_INTEGRATION"] != nil)

        let root = try copyDemoPackage()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let outcome = try MeasureRunner.measureSwiftPackage(
            root: root,
            options: SPMBuilder.Options(level: .complete, buildTests: false, extraArguments: [], scratchPath: nil)
        )

        // The demo package is designed to fail building with exactly these
        // diagnostics on the pinned stable toolchain (Xcode 26.6 / Swift 6.3.3):
        // 1 sendable + 3 isolation + 1 region (the 'sending' closure in
        // Pipeline.swift) in ImagePipelineCore; DemoApp measures clean.
        // See Sources/* in Examples/DemoConcurrency.
        XCTAssertEqual(outcome.buildExitCode, 1)
        XCTAssertTrue(outcome.targetsKnown)

        let core = try XCTUnwrap(outcome.perTarget["ImagePipelineCore"])
        XCTAssertEqual(core.sendable, 1)
        XCTAssertEqual(core.isolation, 3)
        XCTAssertEqual(core.region, 1)

        let app = try XCTUnwrap(outcome.perTarget["DemoApp"])
        XCTAssertEqual(app.region, 0)
        XCTAssertEqual(app.trackedTotal, 0)

        XCTAssertEqual(outcome.unrelatedCount, 0)
        XCTAssertEqual(outcome.tracked.trackedTotal, 5)
    }

    func testMeasureToJournalToStatus() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["STRICTMIGRATE_SKIP_INTEGRATION"] != nil)

        let root = try copyDemoPackage()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let outcome = try MeasureRunner.measureSwiftPackage(
            root: root,
            options: SPMBuilder.Options(level: .complete, buildTests: false, extraArguments: [], scratchPath: nil)
        )

        var journal = Journal()
        journal.applyMeasurement(at: Date(), level: .complete, results: outcome.perTarget)

        // Second measurement with one diagnostic group fixed (simulated).
        var healed = outcome.perTarget
        healed["ImagePipelineCore"] = DiagnosticCounts(sendable: 1, isolation: 1, region: 1)
        journal.applyMeasurement(at: Date(), level: .complete, results: healed)

        let payload = StatusReport.payload(for: journal)
        XCTAssertEqual(payload.summary.initialTotal, 5)
        XCTAssertEqual(payload.summary.remainingTotal, 3)
        XCTAssertEqual(payload.summary.progressPercent, 40)

        let report = StatusReport.pretty(payload, journalPath: "strictmigrate.yaml.journal")
        XCTAssertTrue(report.contains("ImagePipelineCore"))
        XCTAssertTrue(report.contains("3 remaining concurrency diagnostics (from 5 initial)"))
    }
}

final class ShellTests: XCTestCase {
    func testCapturesStdoutStderrAndExitCode() throws {
        let result = try Shell.run("/bin/sh", arguments: ["-c", "echo out; echo err 1>&2; exit 3"])
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertTrue(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("out"))
        XCTAssertTrue(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("err"))
    }

    func testLargeOutputDoesNotDeadlock() throws {
        // Overflow the default pipe buffer (64 KiB) many times over.
        let result = try Shell.run(
            "/bin/sh",
            arguments: ["-c", "for i in $(seq 1 2000); do echo \"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"; done; echo done 1>&2"]
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThan(result.stdout.count, 100_000)
        XCTAssertEqual(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines), "done")
    }

    func testLaunchFailureIsReported() {
        XCTAssertThrowsError(try Shell.run("/nonexistent/definitely-not-a-tool", arguments: [])) { error in
            XCTAssertTrue("\(error)".contains("could not launch"))
        }
    }

    func testLargeStdinWithLeadingStdoutDoesNotDeadlock() throws {
        try XCTSkipIf(Shell.run("/usr/bin/env", arguments: ["python3", "--version"]).exitCode != 0)
        // The child fills its stdout pipe (1 MiB) before reading stdin
        // (1 MiB). With a synchronous stdin write ahead of the output drains,
        // both pipes fill and neither side proceeds.
        let script = """
            import sys
            sys.stdout.write("X" * 1048576)
            sys.stdout.flush()
            data = sys.stdin.buffer.read(1048576)
            sys.stdout.write("\\nread %d\\n" % len(data))
            """
        let result = try Shell.run(
            "/usr/bin/env",
            arguments: ["python3", "-c", script],
            stdin: Data(repeating: 65, count: 1_048_576)
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThan(result.stdout.count, 1_000_000)
        XCTAssertTrue(result.stdoutText.contains("read 1048576"))
    }
}
