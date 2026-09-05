import XCTest

@testable import strictmigrate

final class StatusReportTests: XCTestCase {
    func journalFixture() -> Journal {
        var journal = Journal()
        journal.applyMeasurement(at: Date(), level: .complete, results: [
            "ImagePipelineCore": DiagnosticCounts(sendable: 6, isolation: 3, region: 3),
            "CleanFromDayOne": .zero,
        ])
        // Simulate progress: ImagePipelineCore shrank from 24 to 12.
        journal.targets["ImagePipelineCore"]?.diagnosticsInitial = DiagnosticCounts(sendable: 20, isolation: 2, region: 2)
        return journal
    }

    func testPayloadMath() {
        let payload = StatusReport.payload(for: journalFixture())
        XCTAssertEqual(payload.summary.initialTotal, 24)
        XCTAssertEqual(payload.summary.remainingTotal, 12)
        XCTAssertEqual(payload.summary.progressPercent, 50)

        let core = payload.rows.first { $0.target == "ImagePipelineCore" }
        XCTAssertEqual(core?.progressPercent, 50)
        let clean = payload.rows.first { $0.target == "CleanFromDayOne" }
        XCTAssertEqual(clean?.progressPercent, 100)

        // Rows sort by remaining diagnostics, largest first.
        XCTAssertEqual(payload.rows.first?.target, "ImagePipelineCore")
    }

    func testRegressionIsReportedHonestly() {
        var journal = Journal()
        journal.applyMeasurement(at: Date(), level: .complete, results: [
            "Core": DiagnosticCounts(sendable: 30),
        ])
        journal.targets["Core"]?.diagnosticsInitial = DiagnosticCounts(sendable: 10)
        let payload = StatusReport.payload(for: journal)
        XCTAssertEqual(payload.summary.progressPercent, -200)
    }

    func testPrettyRendering() throws {
        let text = StatusReport.pretty(StatusReport.payload(for: journalFixture()), journalPath: "strictmigrate.yaml.journal")
        XCTAssertTrue(text.contains("strictmigrate — Swift 6 strict concurrency migration"))
        XCTAssertTrue(text.contains("ImagePipelineCore"))
        XCTAssertTrue(text.contains("50%"))
        XCTAssertTrue(text.contains("12 remaining concurrency diagnostics (from 24 initial)"))
    }

    func testPrettyEmptyJournal() {
        let text = StatusReport.pretty(StatusReport.payload(for: Journal()), journalPath: "j")
        XCTAssertTrue(text.contains("No targets measured yet"))
    }

    func testMarkdownRendering() throws {
        let text = try StatusReport.render(journalFixture(), format: .markdown, journalPath: "j")
        XCTAssertTrue(text.contains("| Target | Level | Sendable |"))
        XCTAssertTrue(text.contains("| ImagePipelineCore | complete | 6 | 3 | 3 | 0 | 12 | 50% |"))
    }

    func testJSONRendering() throws {
        let text = try StatusReport.render(journalFixture(), format: .json, journalPath: "j")
        XCTAssertTrue(text.contains("\"target\" : \"ImagePipelineCore\""))
        XCTAssertTrue(text.contains("\"progressPercent\" : 50"))
    }
}

final class PathUtilsTests: XCTestCase {
    func testRelativize() {
        XCTAssertEqual(PathUtils.relativize("/repo/Sources/A.swift", against: "/repo"), "Sources/A.swift")
        XCTAssertEqual(PathUtils.relativize("/elsewhere/A.swift", against: "/repo"), "/elsewhere/A.swift")
        XCTAssertEqual(PathUtils.relativize("relative/already.swift", against: "/repo"), "relative/already.swift")
        XCTAssertEqual(PathUtils.relativize("/repo/Sources/A.swift", against: nil), "/repo/Sources/A.swift")
        // Prefix that only looks like the root must not truncate the path.
        XCTAssertEqual(PathUtils.relativize("/repository/A.swift", against: "/repo"), "/repository/A.swift")
    }
}
