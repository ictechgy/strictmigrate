import Foundation

/// Deterministic classification of a compiler diagnostic into a `DiagnosticCategory`.
///
/// Two layers, in order:
///
/// 1. **Diagnostic id** — newer toolchains (Swift 6.2+) append a bracketed id to
///    the message, e.g. `[#RegionIsolation::SendingRisksDataRace]`. Ids are
///    stable compiler identifiers, so they are preferred when present.
/// 2. **Message text** — case-insensitive keyword rules, verified against real
///    Swift 5/6 diagnostics. Used as the fallback for older toolchains and for
///    xcresult data (which drops the ids).
///
/// Categories are a prioritization aid; the tracked *total* is exact regardless
/// of which bucket a diagnostic lands in.
enum DiagnosticClassifier {
    static func classify(message: String, diagnosticID: String? = nil) -> DiagnosticCategory {
        if let id = diagnosticID?.lowercased(), !id.isEmpty {
            if matches(any: ["region", "sending", "transfer"], in: id) { return .region }
            if matches(any: ["sendable", "mutableglobal", "sharedmutable", "globalscope"], in: id) { return .sendable }
            if matches(any: ["actor", "isolat"], in: id) { return .isolation }
        }

        let m = message.lowercased()
        if matches(any: ["sending", "data race", "transfer", "region"], in: m) { return .region }
        if matches(any: ["sendable", "concurrency-safe", "concurrently-executing", "concurrent code"], in: m) {
            return .sendable
        }
        if matches(
            any: [
                "actor-isolated", "actor isolated", "main actor", "main-actor", "global actor",
                "nonisolated", "non-isolated", "isolated to", "different actor", "actor boundary",
                "cross-actor", "asynchronous context", "not marked with 'await'", "isolation",
            ],
            in: m
        ) { return .isolation }

        // Concurrency-adjacent but unmatched: count as `other` so the journal
        // total stays honest, without forcing these into a named bucket.
        if matches(
            any: ["sendab", "concurr", "actor", "isolat", "async", "await", "task", "region", "send", "race", "transfer"],
            in: m
        ) { return .other }

        return .unrelated
    }

    private static func matches(any needles: [String], in haystack: String) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}
