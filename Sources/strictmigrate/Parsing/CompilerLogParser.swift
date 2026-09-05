import Foundation

/// Parses `file:line:col: error|warning: message` diagnostic lines out of
/// Swift compiler / SwiftPM build output.
///
/// The same diagnostic can appear several times per build (emit-module and
/// per-file compile phases, source-snippet echo), so results are deduplicated
/// by location + severity + message.
struct CompilerLogParser {
    /// Path may contain spaces and colons, hence the non-greedy leading group.
    /// Captures: 1 file, 2 line, 3 column, 4 severity, 5 message.
    /// Immutable after construction; `Regex` just lacks a Sendable conformance here.
    private nonisolated(unsafe) static let diagnosticLine = try! Regex(
        #"^(.+?):(\d+):(\d+):\s*(error|warning):\s*(.*)$"#,
        as: (Substring, Substring, Substring, Substring, Substring, Substring).self
    )

    /// - Parameters:
    ///   - text: Raw build output (ANSI escapes tolerated; cleaned per line).
    ///   - workingDirectory: Absolute path used to relativize file locations.
    func parse(_ text: String, workingDirectory: String? = nil) -> [ConcurrencyDiagnostic] {
        var seen = Set<String>()
        var diagnostics: [ConcurrencyDiagnostic] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = TextCleaner.clean(String(rawLine))
            guard !TextCleaner.isFootnote(line),
                  let match = try? Self.diagnosticLine.firstMatch(in: line)
            else { continue }

            guard let lineNumber = Int(match.2),
                  let columnNumber = Int(match.3)
            else { continue }

            let (message, diagnosticID) = TextCleaner.extractDiagnosticID(from: String(match.5))
            let file = PathUtils.relativize(String(match.1), against: workingDirectory)
            let diagnostic = ConcurrencyDiagnostic(
                file: file,
                line: lineNumber,
                column: columnNumber,
                severity: Severity(rawValue: String(match.4)) ?? .error,
                category: DiagnosticClassifier.classify(message: message, diagnosticID: diagnosticID),
                message: message,
                diagnosticID: diagnosticID
            )

            let key = diagnostic.dedupKey
            guard seen.insert(key).inserted else { continue }
            diagnostics.append(diagnostic)
        }

        return diagnostics
    }
}
