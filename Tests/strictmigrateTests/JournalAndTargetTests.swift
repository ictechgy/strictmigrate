import XCTest

@testable import strictmigrate

final class JournalTests: XCTestCase {
    func testRoundTripThroughYAML() throws {
        var journal = Journal()
        journal.applyMeasurement(
            at: Date(timeIntervalSince1970: 0),
            level: .targeted,
            results: [
                "ImagePipelineCore": DiagnosticCounts(sendable: 12, isolation: 3, region: 9),
                "DemoApp": .zero,
            ]
        )
        journal.tasks.append(
            TaskRecord(
                id: "t-0142",
                target: "ImagePipelineCore",
                file: "Sources/ImagePipelineCore/Decoder.swift",
                symbols: ["ImageDecoder.decode", "DecodeContext"],
                diagnostics: ["sendable-violation×2", "actor-isolation×1"],
                status: .passed,
                commits: ["9f2e1a"],
                verdict: TaskRecord.Verdict(build: "pass", tests: "47/47", tsan: "clean"),
                attempts: 2
            )
        )

        let yaml = try JournalStore.encode(journal)
        XCTAssertEqual(try JournalStore.decode(yaml), journal)

        XCTAssertTrue(yaml.contains("diagnostics_baseline:"))
        XCTAssertTrue(yaml.contains("sendable: 12"))
        XCTAssertTrue(yaml.contains("last_measured_at:"))
    }

    func testDecodeHandWrittenMinimalJournal() throws {
        let yaml = """
            version: 1
            targets:
              ImagePipelineCore:
                level: complete
                diagnostics_baseline: { sendable: 12, isolation: 3, region: 9 }
            tasks:
              - id: t-0001
                target: ImagePipelineCore
                file: Sources/ImagePipelineCore/Decoder.swift
            """
        let journal = try JournalStore.decode(yaml)
        XCTAssertEqual(journal.version, 1)
        XCTAssertEqual(journal.targets["ImagePipelineCore"]?.diagnosticsBaseline.sendable, 12)
        XCTAssertEqual(journal.targets["ImagePipelineCore"]?.level, .complete)
        XCTAssertEqual(journal.tasks.first?.id, "t-0001")
        XCTAssertEqual(journal.tasks.first?.status, .queued)
    }

    func testApplyMeasurementKeepsInitialStable() {
        var journal = Journal()
        let first: [String: DiagnosticCounts] = ["Core": DiagnosticCounts(sendable: 10, isolation: 0, region: 0)]
        journal.applyMeasurement(at: Date(), level: .complete, results: first)
        XCTAssertEqual(journal.targets["Core"]?.diagnosticsInitial?.sendable, 10)

        journal.applyMeasurement(
            at: Date(),
            level: .complete,
            results: ["Core": DiagnosticCounts(sendable: 4, isolation: 0, region: 0)]
        )
        XCTAssertEqual(journal.targets["Core"]?.diagnosticsBaseline.sendable, 4)
        XCTAssertEqual(journal.targets["Core"]?.diagnosticsInitial?.sendable, 10, "initial must not move")
        XCTAssertEqual(journal.targets["Core"]?.progress ?? 0, 0.6, accuracy: 0.0001)
    }

    func testProgressEdgeCases() {
        // Clean from day one.
        let clean = TargetState(level: .complete, diagnosticsBaseline: .zero, diagnosticsInitial: .zero)
        XCTAssertEqual(clean.progress, 1.0)

        // Dirty at first contact with no recorded initial (falls back to baseline).
        let dirty = TargetState(level: .complete, diagnosticsBaseline: DiagnosticCounts(sendable: 5))
        XCTAssertEqual(dirty.progress, 0.0)

        // Regression beyond the initial count shows up below zero.
        let regressed = TargetState(
            level: .complete,
            diagnosticsBaseline: DiagnosticCounts(sendable: 15),
            diagnosticsInitial: DiagnosticCounts(sendable: 10)
        )
        XCTAssertEqual(regressed.progress, -0.5, accuracy: 0.0001)
    }

    func testAggregates() {
        var journal = Journal()
        journal.applyMeasurement(at: Date(), level: .complete, results: [
            "A": DiagnosticCounts(sendable: 1, isolation: 2, region: 3, other: 4),
            "B": DiagnosticCounts(sendable: 10),
        ])
        XCTAssertEqual(journal.aggregateBaseline.trackedTotal, 20)
        XCTAssertEqual(journal.aggregateInitial.trackedTotal, 20)
    }

    func testSaveAndLoadOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("strictmigrate-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("strictmigrate.yaml.journal").path

        var journal = try JournalStore.create(at: path)
        XCTAssertThrowsError(try JournalStore.create(at: path))

        journal.applyMeasurement(at: Date(), level: .complete, results: ["A": DiagnosticCounts(sendable: 2)])
        try JournalStore.save(journal, to: path)

        let reloaded = try JournalStore.load(at: path)
        XCTAssertEqual(reloaded.targets["A"]?.diagnosticsBaseline.sendable, 2)
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).hasPrefix("# strictmigrate journal"))
    }

    func testLoadMissingJournalThrowsHelpfulError() {
        let path = "/nonexistent/strictmigrate.yaml.journal"
        XCTAssertThrowsError(try JournalStore.load(at: path)) { error in
            XCTAssertTrue("\(error)".contains("strictmigrate init"))
        }
    }
}

final class TargetMapperTests: XCTestCase {
    let mapper = TargetMapper(targets: [
        PackageTarget(name: "Core", path: "Sources/Core"),
        PackageTarget(name: "CoreTests", path: "Tests/CoreTests"),
        PackageTarget(name: "App", path: "Sources/App"),
    ])

    func testLongestPrefixWins() {
        XCTAssertEqual(mapper.target(forFile: "Sources/Core/Deep/Nested/A.swift"), "Core")
        XCTAssertEqual(mapper.target(forFile: "Sources/App/main.swift"), "App")
        XCTAssertEqual(mapper.target(forFile: "Tests/CoreTests/CoreTests.swift"), "CoreTests")
        XCTAssertNil(mapper.target(forFile: "Tooling/script.swift"))
    }

    func testTallyIncludesCleanTargetsAndUnattributedBucket() {
        let diagnostics = [
            ConcurrencyDiagnostic(
                file: "Sources/Core/A.swift", line: 1, column: 1, severity: .error,
                category: .sendable, message: "m1", diagnosticID: nil
            ),
            ConcurrencyDiagnostic(
                file: "Tooling/x.swift", line: 1, column: 1, severity: .error,
                category: .isolation, message: "m2", diagnosticID: nil
            ),
            ConcurrencyDiagnostic(
                file: "Tooling/y.swift", line: 1, column: 1, severity: .warning,
                category: .unrelated, message: "unused", diagnosticID: nil
            ),
        ]
        let tally = mapper.tally(diagnostics)

        XCTAssertEqual(tally["Core"]?.sendable, 1)
        XCTAssertEqual(tally["App"], .zero)
        XCTAssertEqual(tally[TargetMapper.unattributed]?.isolation, 1)
        XCTAssertEqual(tally[TargetMapper.unattributed]?.trackedTotal, 1, "unrelated diagnostics are never counted")
    }

    func testParsesDescribeJSON() throws {
        let json = """
            {"name":"Demo","targets":[
              {"name":"Core","path":"Sources/Core","type":"library"},
              {"name":"App","path":"Sources/App","type":"executable"}
            ]}
            """
        let targets = try PackageInspector.parse(describeJSON: Data(json.utf8), packageRoot: "/repo")
        XCTAssertEqual(targets.map(\.name), ["Core", "App"])
    }
}

final class XcresultParserTests: XCTestCase {
    func testParsesRealRecordedXcresult() throws {
        guard let url = Fixtures.url("xcresult", ext: "json") else {
            XCTFail("fixture xcresult.json missing")
            return
        }
        let data = try Data(contentsOf: url)
        let diagnostics = try XcresultParser().parse(jsonData: data, workingDirectory: nil)

        // The root `issues` and per-action `buildResult.issues` mirror each
        // other; deduplication must collapse them.
        XCTAssertEqual(diagnostics.count, 3)
        XCTAssertTrue(diagnostics.allSatisfy { $0.severity == .error })
        XCTAssertTrue(diagnostics.allSatisfy { $0.category == .isolation })

        let lines = diagnostics.map(\.line).sorted()
        XCTAssertEqual(lines, [17, 21, 24], "0-based xcresult locations must be normalized to 1-based")
        XCTAssertTrue(diagnostics.allSatisfy { $0.file.hasSuffix("Renderer.swift") })
        XCTAssertTrue(diagnostics.contains { $0.message.hasPrefix("Call to main actor-isolated") })
    }
}
