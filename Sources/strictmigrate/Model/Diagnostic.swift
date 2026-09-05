import Foundation

/// Severity of a compiler diagnostic.
enum Severity: String, Codable, Hashable, Sendable, CaseIterable {
    case error
    case warning
}

/// Category of a strict-concurrency diagnostic.
///
/// `sendable`, `isolation`, and `region` are the tracked buckets used by the
/// journal baseline; `other` catches concurrency-related diagnostics that do
/// not fit any bucket; `unrelated` diagnostics (syntax errors, style warnings,
/// …) are visible in measure output but never counted in the journal.
enum DiagnosticCategory: String, Codable, Hashable, Sendable, CaseIterable {
    case sendable
    case isolation
    case region
    case other
    case unrelated

    var isTracked: Bool { self != .unrelated }
}

/// One compiler diagnostic relevant to a strict-concurrency migration.
struct ConcurrencyDiagnostic: Hashable, Codable, Sendable {
    /// Repository-relative path when it could be relativized, otherwise the raw path.
    var file: String
    var line: Int
    var column: Int
    var severity: Severity
    var category: DiagnosticCategory
    var message: String
    /// Bracketed diagnostic id emitted by newer toolchains,
    /// e.g. `RegionIsolation::SendingRisksDataRace`.
    var diagnosticID: String?

    /// Identity used to collapse duplicates that `swift build` emits multiple
    /// times per location (emit-module and per-file compile phases).
    var dedupKey: String {
        "\(file)|\(line)|\(column)|\(severity.rawValue)|\(message.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

/// Tallies of tracked diagnostics per category, as stored in the journal.
struct DiagnosticCounts: Codable, Equatable, Sendable {
    var sendable: Int = 0
    var isolation: Int = 0
    var region: Int = 0
    var other: Int = 0

    var trackedTotal: Int { sendable + isolation + region + other }

    static let zero = DiagnosticCounts()

    mutating func add(_ category: DiagnosticCategory) {
        guard category.isTracked else { return }
        switch category {
        case .sendable: sendable += 1
        case .isolation: isolation += 1
        case .region: region += 1
        case .other: other += 1
        case .unrelated: break
        }
    }

    init(sendable: Int = 0, isolation: Int = 0, region: Int = 0, other: Int = 0) {
        self.sendable = sendable
        self.isolation = isolation
        self.region = region
        self.other = other
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sendable = try container.decodeIfPresent(Int.self, forKey: .sendable) ?? 0
        isolation = try container.decodeIfPresent(Int.self, forKey: .isolation) ?? 0
        region = try container.decodeIfPresent(Int.self, forKey: .region) ?? 0
        other = try container.decodeIfPresent(Int.self, forKey: .other) ?? 0
    }

    static func += (lhs: inout DiagnosticCounts, rhs: DiagnosticCounts) {
        lhs.sendable += rhs.sendable
        lhs.isolation += rhs.isolation
        lhs.region += rhs.region
        lhs.other += rhs.other
    }
}
