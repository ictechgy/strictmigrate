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
    /// Per-attempt failure reasons (executor) — why attempts were reverted.
    var notes: [String]

    enum Status: String, Codable, Sendable, CaseIterable {
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
        attempts: Int = 0,
        notes: [String] = []
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
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case id, target, file, symbols, diagnostics, status, commits, verdict, attempts, notes
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
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
    }
}

/// The migration journal — one YAML file per repository, commit target,
/// single source of truth for migration progress.
struct Journal: Codable, Equatable {
    var version: Int
    var targets: [String: TargetState]
    var tasks: [TaskRecord]
    /// Toolchain that produced the latest measurement, e.g.
    /// `Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3)`. The diagnostic
    /// surface differs per compiler/SDK pair, so recording it makes count
    /// changes attributable instead of mysterious.
    var measuredWith: String?

    init(
        version: Int = 1,
        targets: [String: TargetState] = [:],
        tasks: [TaskRecord] = [],
        measuredWith: String? = nil
    ) {
        self.version = version
        self.targets = targets
        self.tasks = tasks
        self.measuredWith = measuredWith
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        targets = try container.decodeIfPresent([String: TargetState].self, forKey: .targets) ?? [:]
        tasks = try container.decodeIfPresent([TaskRecord].self, forKey: .tasks) ?? []
        measuredWith = try container.decodeIfPresent(String.self, forKey: .measuredWith)
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

extension Journal {
    /// Resolves tracked diagnostics to their (file, symbol) identities.
    /// Kotlin files resolve with the Kotlin lexicon.
    static func symbolKeys(
        for diagnostics: [ConcurrencyDiagnostic],
        packageRoot: String
    ) -> Set<SymbolKey> {
        var resolver = SymbolResolver(packageRoot: packageRoot)
        return resolver.symbolKeys(for: diagnostics)
    }

    /// Next sequential task number (ids look like `t-0142`).
    var nextTaskNumber: Int {
        (tasks.compactMap { Int($0.id.dropFirst(2)) }.max() ?? 0) + 1
    }

    /// Tasks still in flight.
    var openTasks: [TaskRecord] {
        tasks.filter { $0.status == .queued || $0.status == .assigned }
    }

    /// Replace the queued backlog with freshly sliced tasks — the queue is
    /// always derived from the latest measurement, so stale entries go;
    /// assigned/passed/reverted/skipped history is never touched.
    /// Returns the number of stale tasks dropped.
    @discardableResult
    mutating func replaceQueue(with fresh: [TaskRecord]) -> Int {
        let stale = tasks.filter { $0.status == .queued }.count
        tasks.removeAll { $0.status == .queued }
        tasks.append(contentsOf: fresh)
        return stale
    }

    /// Close open tasks whose (file, symbol) pairs no longer produce tracked
    /// diagnostics. A task passes when its fix survived the latest build;
    /// `buildExitCode` is recorded honestly (other targets may still fail).
    /// - Parameter measurementValid: false when the measurement is not
    ///   trustworthy (non-concurrency build errors — counts may be
    ///   incomplete); then nothing closes and tasks stay open.
    /// Returns ids of tasks closed as passed.
    @discardableResult
    mutating func reconcileTasks(
        against diagnostics: [ConcurrencyDiagnostic],
        packageRoot: String,
        buildExitCode: Int32?,
        measurementValid: Bool = true
    ) -> [String] {
        guard measurementValid, !openTasks.isEmpty else { return [] }
        let remaining = Journal.symbolKeys(for: diagnostics, packageRoot: packageRoot)

        var closed: [String] = []
        for index in tasks.indices where tasks[index].status == .queued || tasks[index].status == .assigned {
            let task = tasks[index]
            let keys = task.symbols.map { SymbolKey(file: task.file, symbol: $0) }
            guard !keys.isEmpty, !keys.contains(where: remaining.contains) else { continue }
            tasks[index].status = .passed
            tasks[index].verdict = TaskRecord.Verdict(
                build: buildExitCode.map { $0 == 0 ? "pass" : "fail" } ?? "unknown",
                tests: nil,
                tsan: nil
            )
            tasks[index].attempts += 1
            closed.append(task.id)
        }
        return closed
    }

    /// Highest-priority queued task (queue order is slice order).
    var nextQueuedTask: TaskRecord? {
        tasks.first { $0.status == .queued }
    }

    /// Queued task ids, in queue order, up to `limit` (0 = all).
    func queuedTaskIDs(limit: Int) -> [String] {
        let ids = tasks.filter { $0.status == .queued || $0.status == .assigned }.map(\.id)
        return limit > 0 ? Array(ids.prefix(limit)) : ids
    }

    @discardableResult
    mutating func markAssigned(id: String) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.status == .queued }) else { return false }
        tasks[index].status = .assigned
        return true
    }

    /// Terminal failure after exhausting attempts: reverted, with reasons.
    @discardableResult
    mutating func markReverted(id: String, attempts: Int, notes: [String]) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        tasks[index].status = .reverted
        tasks[index].attempts = attempts
        tasks[index].notes = notes
        return true
    }

    /// Attach the commit hash of a passed attempt (reconcile already closed
    /// the status; this records the revert boundary and optional test/TSan
    /// verdicts from the same attempt).
    @discardableResult
    mutating func recordCommit(
        taskID: String,
        commit: String,
        attempts: Int,
        notes: [String],
        tests: String? = nil,
        tsan: String? = nil
    ) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return false }
        tasks[index].commits.append(commit)
        tasks[index].attempts = attempts
        if !notes.isEmpty {
            tasks[index].notes = notes
        }
        if tests != nil || tsan != nil {
            var verdict = tasks[index].verdict ?? TaskRecord.Verdict(build: "pass")
            if let tests { verdict.tests = tests }
            if let tsan { verdict.tsan = tsan }
            tasks[index].verdict = verdict
        }
        return true
    }

    @discardableResult
    mutating func markSkipped(id: String) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.status != .passed }) else { return false }
        tasks[index].status = .skipped
        return true
    }
}
