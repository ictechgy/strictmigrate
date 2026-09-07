import Foundation

/// Parses build issues out of an `.xcresult` bundle exported with
/// `xcrun xcresulttool get --legacy --format json`.
///
/// The JSON is traversed defensively: issue summaries are collected wherever
/// `errorSummaries`/`warningSummaries` arrays appear (the root `issues` and
/// per-action `buildResult.issues` mirror each other and are deduplicated).
/// Locations come from `documentLocationInCreatingWorkspace.url`, whose
/// fragment carries `StartingLineNumber`/`StartingColumnNumber` — these are
/// 0-based, unlike compiler output, and are normalized to 1-based here.
struct XcresultParser {
    func parse(jsonData: Data, workingDirectory: String? = nil) throws -> [ConcurrencyDiagnostic] {
        guard let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw ParseError.malformed("xcresult JSON root is not an object")
        }

        var collector = IssueCollector()
        collector.walk(root)

        var seen = Set<String>()
        var diagnostics: [ConcurrencyDiagnostic] = []
        let relativizer = workingDirectory.flatMap { $0.isEmpty ? nil : PathRelativizer(directory: $0) }
        for issue in collector.issues {
            let rawFile = issue.file ?? "(unknown)"
            let file = relativizer?.relativize(rawFile) ?? rawFile
            let diagnostic = ConcurrencyDiagnostic(
                file: file,
                line: issue.line,
                column: issue.column,
                severity: issue.severity,
                category: DiagnosticClassifier.classify(message: issue.message),
                message: issue.message,
                diagnosticID: nil
            )
            guard seen.insert(diagnostic.dedupKey).inserted else { continue }
            diagnostics.append(diagnostic)
        }
        return diagnostics
    }

    enum ParseError: Error, CustomStringConvertible {
        case malformed(String)

        var description: String {
            switch self {
            case .malformed(let reason): return "malformed xcresult payload: \(reason)"
            }
        }
    }
}

private struct XcresultIssue {
    var severity: Severity
    var message: String
    var file: String?
    var line: Int
    var column: Int
}

private struct IssueCollector {
    private(set) var issues: [XcresultIssue] = []

    mutating func walk(_ node: Any) {
        switch node {
        case let object as [String: Any]:
            for (key, value) in object {
                if let severity = Self.severity(forKey: key) {
                    let summaries = (value as? [String: Any])?["_values"] as? [[String: Any]] ?? []
                    issues.append(contentsOf: summaries.compactMap { Self.issue(from: $0, severity: severity) })
                } else {
                    walk(value)
                }
            }
        case let array as [Any]:
            for element in array {
                walk(element)
            }
        default:
            break
        }
    }

    private static func severity(forKey key: String) -> Severity? {
        switch key {
        case "errorSummaries": return .error
        case "warningSummaries": return .warning
        default: return nil
        }
    }

    private static func issue(from summary: [String: Any], severity: Severity) -> XcresultIssue? {
        guard let message = (summary["message"] as? [String: Any])?["_value"] as? String else { return nil }

        var issue = XcresultIssue(severity: severity, message: message, file: nil, line: 0, column: 0)
        if let location = summary["documentLocationInCreatingWorkspace"] as? [String: Any],
           let urlString = (location["url"] as? [String: Any])?["_value"] as? String,
           let parsed = parseDocumentLocation(urlString)
        {
            issue.file = parsed.path
            issue.line = parsed.line
            issue.column = parsed.column
        }
        return issue
    }

    /// `file:///path/File.swift#StartingLineNumber=16&StartingColumnNumber=17&…`
    private static func parseDocumentLocation(_ urlString: String) -> (path: String, line: Int, column: Int)? {
        let parts = urlString.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let head = parts.first, head.hasPrefix("file://") else { return nil }
        let encodedPath = String(head.dropFirst("file://".count))
        let path = encodedPath.removingPercentEncoding ?? encodedPath

        var line = 0
        var column = 0
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2, let number = Int(kv[1]) else { continue }
                switch kv[0] {
                case "StartingLineNumber": line = number + 1
                case "StartingColumnNumber": column = number + 1
                default: break
                }
            }
        }
        return (path, line, column)
    }
}
