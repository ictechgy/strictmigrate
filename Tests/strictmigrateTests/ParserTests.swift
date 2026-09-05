import XCTest

@testable import strictmigrate

/// Locates recorded fixtures in the test bundle (with or without the
/// `Fixtures/` subdirectory, depending on how SPM laid them out).
enum Fixtures {
    static func url(_ name: String, ext: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: ext)
            ?? Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
    }
}

final class DiagnosticClassifierTests: XCTestCase {
    func testRealSwift6Diagnostics() {
        // (message, diagnostic id, expected category) — messages recorded from
        // real Swift 6.x compiler output; ids from toolchains that emit them.
        let cases: [(String, String?, DiagnosticCategory)] = [
            (
                "sending 'pipeline' risks causing data races; this is an error in the Swift 6 language mode",
                "RegionIsolation::SendingRisksDataRace", .region
            ),
            (
                "static property 'shared' is not concurrency-safe because it is nonisolated global shared mutable state; this is an error in the Swift 6 language mode",
                "MutableGlobalVariable", .sendable
            ),
            (
                "call to main actor-isolated instance method 'render(name:)' in a synchronous nonisolated context",
                "ActorIsolatedCall", .isolation
            ),
            (
                "call to main actor-isolated initializer 'init()' in a synchronous nonisolated context",
                nil, .isolation
            ),
            (
                "main actor-isolated property 'theme' can not be mutated from a nonisolated context",
                nil, .isolation
            ),
            (
                "capture of 'self' with non-sendable type 'ImagePipeline' in a '@Sendable' closure",
                nil, .sendable
            ),
            (
                "type 'DecodeContext' does not conform to the 'Sendable' protocol",
                nil, .sendable
            ),
            (
                "stored property 'cache' of 'Sendable' struct 'Config' has non-sendable type 'DecodeContext'",
                nil, .sendable
            ),
            (
                "reference to captured var 'count' in concurrently-executing code",
                nil, .sendable
            ),
            (
                "task-isolated value of type 'Box' passed as a strongly transferred parameter; later accesses could race",
                nil, .region
            ),
            (
                "passing value of non-sendable type 'Box' into a 'sending' parameter",
                nil, .region
            ),
            (
                "expression is 'async' but is not marked with 'await'",
                nil, .isolation
            ),
            (
                "actor-isolated property 'entries' can not be referenced from a nonisolated context",
                nil, .isolation
            ),
            (
                // Mixed signal: mentions isolation, but the violated rule is the
                // Sendable capture — sendable wins per rule order.
                "'isolation-specific' capture of 'self' with non-sendable type 'ViewModel'",
                nil, .sendable
            ),
            (
                "variable 'x' was written to, but never read",
                nil, .unrelated
            ),
            (
                "'ThumbnailRenderer' initializer is inaccessible due to 'internal' protection level",
                nil, .unrelated
            ),
            (
                "cannot find 'pipeline' in scope",
                nil, .unrelated
            ),
        ]

        for (message, id, expected) in cases {
            XCTAssertEqual(
                DiagnosticClassifier.classify(message: message, diagnosticID: id),
                expected,
                "message: \(message)"
            )
        }
    }

    func testXcresultStyleMessagesWithoutIds() {
        // xcresult drops the ids and capitalizes the message.
        let cases: [(String, DiagnosticCategory)] = [
            ("Call to main actor-isolated instance method 'render(name:)' in a synchronous nonisolated context", .isolation),
            ("Sending 'pipeline' risks causing data races", .region),
            ("Static property 'shared' is not concurrency-safe because it is nonisolated global shared mutable state", .sendable),
        ]
        for (message, expected) in cases {
            XCTAssertEqual(DiagnosticClassifier.classify(message: message), expected, "message: \(message)")
        }
    }

    func testIdTakesPrecedenceOverMessageText() {
        XCTAssertEqual(
            DiagnosticClassifier.classify(message: "something about an actor and sending", diagnosticID: "SendableSomething"),
            .sendable
        )
    }
}

final class TextCleanerTests: XCTestCase {
    func testStripsColorAndHyperlinks() {
        let raw = "\u{1B}[1;31merror: \u{1B}[1;39mcall failed\u{1B}[0;0m"
        XCTAssertEqual(TextCleaner.clean(raw), "error: call failed")
    }

    func testStripsOsc8Hyperlink() {
        let raw = "warning: unsafe state [#\u{1B}]8;;https://docs.swift.org/x\u{1B}\\MutableGlobalVariable\u{1B}]8;;\u{1B}\\]"
        let cleaned = TextCleaner.clean(raw)
        XCTAssertTrue(cleaned.contains("[#MutableGlobalVariable]"))
        XCTAssertFalse(cleaned.contains("\u{1B}"))
        XCTAssertFalse(cleaned.contains("https://"))
    }

    func testFootnoteDetection() {
        XCTAssertTrue(TextCleaner.isFootnote("[#MutableGlobalVariable]: <https://docs.swift.org/compiler/documentation/diagnostics/mutable-global-variable>"))
        XCTAssertFalse(TextCleaner.isFootnote("[#MutableGlobalVariable]: not a url"))
        XCTAssertFalse(TextCleaner.isFootnote("/path/File.swift:1:2: error: nope"))
    }

    func testExtractDiagnosticID() {
        let (message, id) = TextCleaner.extractDiagnosticID(
            from: "sending 'x' risks causing data races [#RegionIsolation::SendingRisksDataRace]"
        )
        XCTAssertEqual(id, "RegionIsolation::SendingRisksDataRace")
        XCTAssertEqual(message, "sending 'x' risks causing data races")

        let (plain, nilID) = TextCleaner.extractDiagnosticID(from: "plain message [not an id]")
        XCTAssertNil(nilID)
        XCTAssertEqual(plain, "plain message [not an id]")

        let (simple, simpleID) = TextCleaner.extractDiagnosticID(from: "unsafe state [#MutableGlobalVariable]")
        XCTAssertEqual(simpleID, "MutableGlobalVariable")
        XCTAssertEqual(simple, "unsafe state")
    }
}

final class CompilerLogParserTests: XCTestCase {
    let parser = CompilerLogParser()

    func testParsesBasicDiagnosticLine() {
        let log = """
            /repo/Sources/Core/Thing.swift:10:5: error: type 'Thing' does not conform to the 'Sendable' protocol
            note: candidate is non-sendable
            /repo/Sources/Core/Thing.swift:12:9: warning: capture of 'self' with non-sendable type 'Thing' in a '@Sendable' closure
            error: Build failed
            """
        let diagnostics = parser.parse(log, workingDirectory: "/repo")

        XCTAssertEqual(diagnostics.count, 2)
        XCTAssertEqual(diagnostics[0].file, "Sources/Core/Thing.swift")
        XCTAssertEqual(diagnostics[0].line, 10)
        XCTAssertEqual(diagnostics[0].column, 5)
        XCTAssertEqual(diagnostics[0].severity, .error)
        XCTAssertEqual(diagnostics[0].category, .sendable)
        XCTAssertEqual(diagnostics[1].severity, .warning)
    }

    func testDeduplicatesRepeatedDiagnostics() {
        let line = "/repo/Sources/App.swift:3:1: error: call to main actor-isolated method 'x()' in a synchronous nonisolated context"
        let diagnostics = parser.parse([line, line, line].joined(separator: "\n"), workingDirectory: "/repo")
        XCTAssertEqual(diagnostics.count, 1)
    }

    func testIgnoresSnippetEchoLinesAndFootnotes() {
        let log = """
            /repo/Sources/App.swift:16:23: warning: static property 'shared' is not concurrency-safe because it is nonisolated global shared mutable state [#MutableGlobalVariable]
            14 | public enum ImageDecoder {
            16 |     public static var shared = DecodeContext()
               |                       |- warning: static property 'shared' is not concurrency-safe because it is nonisolated global shared mutable state [#MutableGlobalVariable]
            [#MutableGlobalVariable]: <https://docs.swift.org/compiler/documentation/diagnostics/mutable-global-variable>
            """
        let diagnostics = parser.parse(log, workingDirectory: "/repo")
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].diagnosticID, "MutableGlobalVariable")
    }

    func testPathWithSpaces() {
        let log = "/repo/My Sources/App/Fancy Name.swift:7:13: error: sending 'box' risks causing data races"
        let diagnostics = parser.parse(log, workingDirectory: "/repo")
        XCTAssertEqual(diagnostics.first?.file, "My Sources/App/Fancy Name.swift")
        XCTAssertEqual(diagnostics.first?.category, .region)
    }

    func testColorizedOutputIsParsed() {
        let log = "\u{1B}[1;31mignored\u{1B}[0m\n/repo/Sources/A.swift:1:2: \u{1B}[1;31merror: \u{1B}[1;39mtype 'X' does not conform to the 'Sendable' protocol\u{1B}[0;0m"
        let diagnostics = parser.parse(log, workingDirectory: "/repo")
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].message, "type 'X' does not conform to the 'Sendable' protocol")
    }

    func testRelativizesThroughSymlinkedWorkingDirectory() throws {
        // Temp directories often sit behind symlinks (e.g. /var → /private/var
        // on macOS): the compiler reports the resolved form while callers may
        // pass either form as the working directory.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("strictmigrate-sym-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolvedRoot = root.resolvingSymlinksInPath().path
        let log = "\(resolvedRoot)/Sources/A.swift:1:2: error: type 'X' does not conform to the 'Sendable' protocol"

        XCTAssertEqual(parser.parse(log, workingDirectory: root.path).first?.file, "Sources/A.swift")
        XCTAssertEqual(parser.parse(log, workingDirectory: resolvedRoot).first?.file, "Sources/A.swift")
    }

    func testRealRecordedSwiftBuildLog() throws {
        guard let url = Fixtures.url("spm-build-raw", ext: "log") else {
            XCTFail("fixture spm-build-raw.log missing")
            return
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let diagnostics = parser.parse(text)

        XCTAssertEqual(diagnostics.count, 6, "fixture should contain exactly 6 unique tracked diagnostics")
        XCTAssertEqual(diagnostics.filter { $0.category == .sendable }.count, 1)
        XCTAssertEqual(diagnostics.filter { $0.category == .isolation }.count, 3)
        XCTAssertEqual(diagnostics.filter { $0.category == .region }.count, 2)
        XCTAssertEqual(diagnostics.filter { $0.severity == .error }.count, 3)
        XCTAssertEqual(diagnostics.filter { $0.severity == .warning }.count, 3)
        XCTAssertEqual(
            Set(diagnostics.map(\.diagnosticID)).subtracting([nil]) ,
            ["RegionIsolation::SendingRisksDataRace", "MutableGlobalVariable", "ActorIsolatedCall"]
        )
    }
}
