import Foundation

/// Renders the journal as a migration status report: per-target remaining
/// diagnostics and completion rate against the first measurement.
enum StatusReport {
    enum Format: String, CaseIterable, Sendable {
        case pretty
        case markdown
        case json
    }

    struct Row: Codable, Equatable {
        var target: String
        var level: StrictLevel
        var remaining: DiagnosticCounts
        var initial: DiagnosticCounts
        /// Percent complete relative to `initial`; negative or above 100 means
        /// the count moved against the migration and is reported as-is.
        var progressPercent: Int
        var lastMeasuredAt: String?
    }

    struct Summary: Codable, Equatable {
        var targets: Int
        var remainingTotal: Int
        var initialTotal: Int
        var progressPercent: Int
        var remaining: DiagnosticCounts
    }

    struct Payload: Codable, Equatable {
        var journalVersion: Int
        var summary: Summary
        var rows: [Row]
    }

    static func payload(for journal: Journal) -> Payload {
        let rows = journal.targets
            .map { name, state -> Row in
                Row(
                    target: name,
                    level: state.level,
                    remaining: state.diagnosticsBaseline,
                    initial: state.diagnosticsInitial ?? state.diagnosticsBaseline,
                    progressPercent: percent(state.progress),
                    lastMeasuredAt: state.lastMeasuredAt
                )
            }
            .sorted { lhs, rhs in
                if lhs.remaining.trackedTotal != rhs.remaining.trackedTotal {
                    return lhs.remaining.trackedTotal > rhs.remaining.trackedTotal
                }
                return lhs.target < rhs.target
            }

        let remaining = journal.aggregateBaseline
        let initial = journal.aggregateInitial
        let overall: Double
        if initial.trackedTotal == 0 {
            overall = remaining.trackedTotal == 0 ? 1.0 : 0.0
        } else {
            overall = 1.0 - Double(remaining.trackedTotal) / Double(initial.trackedTotal)
        }

        return Payload(
            journalVersion: journal.version,
            summary: Summary(
                targets: rows.count,
                remainingTotal: remaining.trackedTotal,
                initialTotal: initial.trackedTotal,
                progressPercent: percent(overall),
                remaining: remaining
            ),
            rows: rows
        )
    }

    static func render(_ journal: Journal, format: Format, journalPath: String) throws -> String {
        let payload = payload(for: journal)
        switch format {
        case .pretty: return pretty(payload, journalPath: journalPath)
        case .markdown: return markdown(payload)
        case .json: return try json(payload)
        }
    }

    // MARK: - Renderers

    static func pretty(_ payload: Payload, journalPath: String) -> String {
        var out: [String] = []
        out.append("strictmigrate — Swift 6 strict concurrency migration")
        out.append("journal: \(journalPath)")
        out.append("")

        if payload.rows.isEmpty {
            out.append("No targets measured yet. Run `strictmigrate measure`.")
            return out.joined(separator: "\n") + "\n"
        }

        let nameWidth = max(6, payload.rows.map { $0.target.count }.max() ?? 6)
        let header = [
            pad("Target", nameWidth), pad("Level", 9),
            padLeft("Sendable", 9), padLeft("Isolation", 10), padLeft("Region", 7), padLeft("Other", 6),
            padLeft("Total", 6), "  Progress",
        ].joined(separator: " ")
        out.append(header)
        out.append(String(repeating: "─", count: header.count + 12))

        for row in payload.rows {
            let r = row.remaining
            out.append(
                [
                    pad(row.target, nameWidth), pad(row.level.rawValue, 9),
                    padLeft(String(r.sendable), 9), padLeft(String(r.isolation), 10),
                    padLeft(String(r.region), 7), padLeft(String(r.other), 6),
                    padLeft(String(r.trackedTotal), 6),
                    "  \(bar(row.progressPercent)) \(padLeft("\(row.progressPercent)%", 5))",
                ].joined(separator: " ")
            )
        }

        out.append("")
        let s = payload.summary
        out.append(
            "Total: \(s.remainingTotal) remaining concurrency diagnostics "
                + "(from \(s.initialTotal) initial) — \(s.progressPercent)% complete "
                + "across \(s.targets) target\(s.targets == 1 ? "" : "s")"
        )
        if s.remainingTotal > s.initialTotal {
            out.append("Regression: diagnostics grew by \(s.remainingTotal - s.initialTotal) since the first measurement.")
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func markdown(_ payload: Payload) -> String {
        var out: [String] = []
        out.append("## Strict concurrency migration status")
        out.append("")
        let s = payload.summary
        out.append(
            "**\(s.remainingTotal)** remaining diagnostics (from \(s.initialTotal) initial) — "
                + "**\(s.progressPercent)%** complete across \(s.targets) target\(s.targets == 1 ? "" : "s")."
        )
        out.append("")
        out.append("| Target | Level | Sendable | Isolation | Region | Other | Total | Progress |")
        out.append("|---|---|---:|---:|---:|---:|---:|---:|")
        for row in payload.rows {
            let r = row.remaining
            out.append(
                "| \(row.target) | \(row.level.rawValue) | \(r.sendable) | \(r.isolation) | \(r.region) | \(r.other) | \(r.trackedTotal) | \(row.progressPercent)% |"
            )
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func json(_ payload: Payload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self) + "\n"
    }

    // MARK: - Helpers

    static func percent(_ ratio: Double) -> Int {
        Int((ratio * 100).rounded())
    }

    static func bar(_ percent: Int, width: Int = 10) -> String {
        let clamped = min(max(percent, 0), 100)
        let filled = Int((Double(clamped) / 100 * Double(width)).rounded())
        return String(repeating: "▓", count: filled) + String(repeating: "░", count: width - filled)
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private static func padLeft(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }
}
