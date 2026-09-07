import Foundation

/// Outcome of one `swift test` run (optionally under ThreadSanitizer).
struct TestRunOutcome: Equatable, Sendable {
    var exitCode: Int32
    /// Tests executed, when a summary line was found (XCTest or swift-testing).
    var executed: Int?
    /// Parsed failure count; falls back to 1 when the run failed unparsably.
    var failures: Int
    /// Number of `WARNING: ThreadSanitizer:` reports.
    var tsanRaces: Int
    var output: String

    var passed: Bool { exitCode == 0 && failures == 0 && tsanRaces == 0 }
    var hasSummary: Bool { executed != nil }

    /// Journal-style tally, e.g. `47/47` or `45/47`.
    var summaryLabel: String {
        guard let executed else { return exitCode == 0 ? "n/a" : "failed" }
        return "\(executed - min(failures, executed))/\(executed)"
    }
}

/// Runs the package's test suite as a verdict stage. Only meaningful once the
/// whole package builds — the executor invokes this after a passing build
/// verdict, never alongside a broken one.
enum TestRunner {
    // `Regex` is not Sendable on this toolchain, but these constants are
    // immutable after construction and safe to share — hence `nonisolated(unsafe)`.
    private nonisolated(unsafe) static let xctestSummary = try! Regex(
        #"Executed (\d+) tests?, with (\d+) failures?"#,
        as: (Substring, Substring, Substring).self
    )
    private nonisolated(unsafe) static let swiftTestingSummary = try! Regex(
        #"Test run with (\d+) tests? (?:passed|failed)"#,
        as: (Substring, Substring).self
    )

    static func run(packageRoot: String, tsan: Bool) throws -> TestRunOutcome {
        var arguments = ["test", "--no-color-diagnostics"]
        if tsan {
            arguments += ["--sanitize=thread"]
        }
        let result = try Shell.run("swift", arguments: arguments, currentDirectory: packageRoot)
        return parse(exitCode: result.exitCode, output: result.combinedText)
    }

    static func parse(exitCode: Int32, output: String) -> TestRunOutcome {
        let cleaned = TextCleaner.clean(output)

        // XCTest: `Executed 12 tests, with 2 failures (0 unexpected) in 0.3s`
        // Prefer the last summary line in the combined output.
        var executed: Int?
        var failures = 0
        for match in cleaned.matches(of: xctestSummary) {
            executed = Int(match.1)
            failures = Int(match.2) ?? failures
        }

        // swift-testing: `Test run with 12 tests passed after …` — count only.
        if executed == nil {
            for match in cleaned.matches(of: swiftTestingSummary) {
                executed = Int(match.1)
            }
            if executed != nil, exitCode != 0 { failures = max(failures, 1) }
        } else if exitCode != 0, failures == 0 {
            failures = 1
        }

        let tsanRaces = cleaned.components(separatedBy: "WARNING: ThreadSanitizer:").count - 1
        return TestRunOutcome(
            exitCode: exitCode, executed: executed, failures: failures,
            tsanRaces: tsanRaces, output: output
        )
    }
}
