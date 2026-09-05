import Foundation

/// Strict-concurrency checking level the measurement was taken at.
/// Mirrors the `-strict-concurrency` swiftc flag values.
enum StrictLevel: String, Codable, Sendable, CaseIterable {
    case minimal
    case targeted
    case complete
}

/// Migration state of one target, as recorded in the journal.
struct TargetState: Codable, Equatable {
    var level: StrictLevel
    /// Latest measured diagnostic counts.
    var diagnosticsBaseline: DiagnosticCounts
    /// Counts at first contact; progress is computed against it. Kept stable
    /// across measures so completion rate only moves when real work happens.
    var diagnosticsInitial: DiagnosticCounts?
    /// ISO-8601 UTC timestamp of the last measure.
    var lastMeasuredAt: String?

    init(
        level: StrictLevel,
        diagnosticsBaseline: DiagnosticCounts = .zero,
        diagnosticsInitial: DiagnosticCounts? = nil,
        lastMeasuredAt: String? = nil
    ) {
        self.level = level
        self.diagnosticsBaseline = diagnosticsBaseline
        self.diagnosticsInitial = diagnosticsInitial
        self.lastMeasuredAt = lastMeasuredAt
    }

    enum CodingKeys: String, CodingKey {
        case level
        case diagnosticsBaseline = "diagnostics_baseline"
        case diagnosticsInitial = "diagnostics_initial"
        case lastMeasuredAt = "last_measured_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        level = try container.decodeIfPresent(StrictLevel.self, forKey: .level) ?? .minimal
        diagnosticsBaseline =
            try container.decodeIfPresent(DiagnosticCounts.self, forKey: .diagnosticsBaseline) ?? .zero
        diagnosticsInitial = try container.decodeIfPresent(DiagnosticCounts.self, forKey: .diagnosticsInitial)
        lastMeasuredAt = try container.decodeIfPresent(String.self, forKey: .lastMeasuredAt)
    }

    /// Completion ratio in `[0 … 1]`, relative to the first measurement.
    /// Over 1.0 or below 0.0 means the diagnostic count regressed; callers
    /// render it honestly rather than clamping.
    var progress: Double {
        let initial = diagnosticsInitial ?? diagnosticsBaseline
        let initialTotal = initial.trackedTotal
        guard initialTotal > 0 else {
            return diagnosticsBaseline.trackedTotal == 0 ? 1.0 : 0.0
        }
        return 1.0 - Double(diagnosticsBaseline.trackedTotal) / Double(initialTotal)
    }
}

/// One atomic migration task (produced by slicing in v0.2; the schema is part
/// of the journal from day one so hand-written task lists survive rewrites).
struct TaskRecord: Codable, Equatable {
    var id: String
    var target: String
    var file: String
    var symbols: [String]
    /// Human-readable diagnostic summary, e.g. `sendable-violation×2`.
    var diagnostics: [String]
    var status: Status
    /// Commit hashes backing this task; one task = one commit = one revert boundary.
    var commits: [String]
    var verdict: Verdict?
    var attempts: Int

    enum Status: String, Codable, Sendable {
        case queued
        case assigned
        case passed
        case reverted
        case skipped
    }

    struct Verdict: Codable, Equatable {
        var build: String
        var tests: String?
        var tsan: String?
    }

    init(
        id: String,
        target: String,
        file: String,
        symbols: [String] = [],
        diagnostics: [String] = [],
        status: Status = .queued,
        commits: [String] = [],
        verdict: Verdict? = nil,
        attempts: Int = 0
    ) {
        self.id = id
        self.target = target
        self.file = file
        self.symbols = symbols
        self.diagnostics = diagnostics
        self.status = status
        self.commits = commits
        self.verdict = verdict
        self.attempts = attempts
    }

    enum CodingKeys: String, CodingKey {
        case id, target, file, symbols, diagnostics, status, commits, verdict, attempts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        target = try container.decode(String.self, forKey: .target)
        file = try container.decode(String.self, forKey: .file)
        symbols = try container.decodeIfPresent([String].self, forKey: .symbols) ?? []
        diagnostics = try container.decodeIfPresent([String].self, forKey: .diagnostics) ?? []
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .queued
        commits = try container.decodeIfPresent([String].self, forKey: .commits) ?? []
        verdict = try container.decodeIfPresent(Verdict.self, forKey: .verdict)
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
    }
}

/// The migration journal — one YAML file per repository, commit target,
/// single source of truth for migration progress.
struct Journal: Codable, Equatable {
    var version: Int
    var targets: [String: TargetState]
    var tasks: [TaskRecord]

    init(version: Int = 1, targets: [String: TargetState] = [:], tasks: [TaskRecord] = []) {
        self.version = version
        self.targets = targets
        self.tasks = tasks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        targets = try container.decodeIfPresent([String: TargetState].self, forKey: .targets) ?? [:]
        tasks = try container.decodeIfPresent([TaskRecord].self, forKey: .tasks) ?? []
    }

    /// Merge a fresh measurement into the journal: updates baselines, carries
    /// initial counts forward, records level and timestamp. Existing entries
    /// not covered by this measurement are left untouched.
    mutating func applyMeasurement(at date: Date, level: StrictLevel, results: [String: DiagnosticCounts]) {
        let timestamp = Self.utcTimestamp(date)
        for (name, counts) in results {
            var state = targets[name] ?? TargetState(level: level)
            state.diagnosticsInitial = state.diagnosticsInitial ?? counts
            state.diagnosticsBaseline = counts
            state.level = level
            state.lastMeasuredAt = timestamp
            targets[name] = state
        }
    }

    var aggregateBaseline: DiagnosticCounts {
        targets.values.reduce(DiagnosticCounts.zero) { acc, state in
            var acc = acc
            acc += state.diagnosticsBaseline
            return acc
        }
    }

    var aggregateInitial: DiagnosticCounts {
        targets.values.reduce(DiagnosticCounts.zero) { acc, state in
            var acc = acc
            acc += (state.diagnosticsInitial ?? state.diagnosticsBaseline)
            return acc
        }
    }
}

extension Journal {
    /// ISO-8601 UTC, second precision — stable across journal rewrites.
    /// A fresh formatter per call keeps this free of shared mutable state.
    static func utcTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
