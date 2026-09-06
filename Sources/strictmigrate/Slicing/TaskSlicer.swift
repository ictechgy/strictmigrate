import Foundation

/// Slices measured diagnostics into atomic migration tasks.
///
/// Clustering rule: one task per (target, file, enclosing symbol). Half-fixed
/// symbols are the classic cause of re-appearing diagnostics, so a symbol's
/// diagnostics always travel together. Ordering rule: leaf targets first —
/// fixing a dependency before its dependents means downstream recompiles
/// confirm the fix instead of masking it.
enum TaskSlicer {
    struct Options: Sendable {
        /// Targets in leaf-first priority order (see `TargetPriority`).
        var targetOrder: [String]
        /// First task id number to hand out.
        var firstTaskNumber: Int
    }

    static func slice(
        diagnostics: [ConcurrencyDiagnostic],
        packageRoot: String,
        mapper: HybridTargetMapper,
        options: Options
    ) -> [TaskRecord] {
        // (target, file, symbol) → diagnostics
        var clusters: [ClusterKey: [ConcurrencyDiagnostic]] = [:]
        var symbolCache: [String: [SymbolRange]] = [:]

        for diagnostic in diagnostics where diagnostic.category.isTracked {
            let target = mapper.target(forFile: diagnostic.file) ?? TargetMapper.unattributed
            if symbolCache[diagnostic.file] == nil {
                let absolute = (packageRoot as NSString).appendingPathComponent(diagnostic.file)
                symbolCache[diagnostic.file] = (try? String(contentsOfFile: absolute, encoding: .utf8))
                    .map { SymbolLocator.symbols(in: $0, language: SourceLanguage(path: diagnostic.file)) } ?? []
            }
            let symbol = SymbolLocator.symbolName(for: diagnostic, symbols: symbolCache[diagnostic.file] ?? [])
            clusters[ClusterKey(target: target, file: diagnostic.file, symbol: symbol), default: []].append(diagnostic)
        }

        let targetRank: [String: Int] = options.targetOrder.enumerated()
            .reduce(into: [:]) { ranks, entry in
                if ranks[entry.element] == nil { ranks[entry.element] = entry.offset }
            }

        return clusters
            .map { key, members -> TaskRecord in
                TaskRecord(
                    id: "",
                    target: key.target,
                    file: key.file,
                    symbols: [key.symbol],
                    diagnostics: Self.summaries(for: members),
                    status: .queued,
                    commits: [],
                    verdict: nil,
                    attempts: 0
                )
            }
            .sorted { lhs, rhs in
                let lhsRank = targetRank[lhs.target] ?? Int.max
                let rhsRank = targetRank[rhs.target] ?? Int.max
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                if lhs.diagnostics.count != rhs.diagnostics.count {
                    return lhs.diagnostics.count < rhs.diagnostics.count
                }
                return (lhs.file, lhs.symbols.first ?? "") < (rhs.file, rhs.symbols.first ?? "")
            }
            .enumerated()
            .map { index, task in
                var task = task
                task.id = Self.taskID(options.firstTaskNumber + index)
                return task
            }
    }

    /// Human-readable per-category counts, journal style:
    /// `["sendable-violation×2", "actor-isolation×1"]`.
    static func summaries(for diagnostics: [ConcurrencyDiagnostic]) -> [String] {
        let labels: [DiagnosticCategory: String] = [
            .sendable: "sendable-violation",
            .isolation: "actor-isolation",
            .region: "region-violation",
            .other: "other",
        ]
        var counts: [DiagnosticCategory: Int] = [:]
        for diagnostic in diagnostics {
            counts[diagnostic.category, default: 0] += 1
        }
        return DiagnosticCategory.allCases.compactMap { category in
            guard category.isTracked, let count = counts[category] else { return nil }
            return "\(labels[category] ?? category.rawValue)×\(count)"
        }
    }

    static func taskID(_ number: Int) -> String {
        String(format: "t-%04d", number)
    }

    private struct ClusterKey: Hashable {
        var target: String
        var file: String
        var symbol: String
    }
}

/// Identity of one atomic unit of work: a symbol within a file.
struct SymbolKey: Hashable, Sendable {
    var file: String
    var symbol: String
}

extension Journal {
    /// Resolves tracked diagnostics to their (file, symbol) identities.
    /// Source files are read (and symbol sets cached) per call; Kotlin files
    /// resolve with the Kotlin lexicon.
    static func symbolKeys(
        for diagnostics: [ConcurrencyDiagnostic],
        packageRoot: String
    ) -> Set<SymbolKey> {
        var symbolCache: [String: [SymbolRange]] = [:]
        var keys = Set<SymbolKey>()
        for diagnostic in diagnostics where diagnostic.category.isTracked {
            if symbolCache[diagnostic.file] == nil {
                let absolute = (packageRoot as NSString).appendingPathComponent(diagnostic.file)
                symbolCache[diagnostic.file] = (try? String(contentsOfFile: absolute, encoding: .utf8))
                    .map { SymbolLocator.symbols(in: $0, language: SourceLanguage(path: diagnostic.file)) } ?? []
            }
            let symbol = SymbolLocator.symbolName(for: diagnostic, symbols: symbolCache[diagnostic.file] ?? [])
            keys.insert(SymbolKey(file: diagnostic.file, symbol: symbol))
        }
        return keys
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
    /// Returns ids of tasks closed as passed.
    @discardableResult
    mutating func reconcileTasks(
        against diagnostics: [ConcurrencyDiagnostic],
        packageRoot: String,
        buildExitCode: Int32?
    ) -> [String] {
        guard !openTasks.isEmpty else { return [] }
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

/// Computes a leaf-first target order from `swift package describe` target
/// dependencies: dependencies come before their dependents, so fixes
/// propagate downstream and get confirmed by recompilation.
enum TargetPriority {
    /// - Parameter dependencies: target name → names of targets it depends on.
    static func leafFirstOrder(dependencies: [String: [String]]) -> [String] {
        var order: [String] = []
        var state: [String: VisitState] = dependencies.keys.reduce(into: [:]) { $0[$1] = .unvisited }

        func visit(_ name: String) {
            guard state[name] != .done else { return }
            state[name] = .visiting
            for dependency in dependencies[name] ?? [] {
                if state[dependency] == .visiting { continue } // cycle: pick a stable order anyway
                visit(dependency)
            }
            state[name] = .done
            order.append(name)
        }

        for name in dependencies.keys.sorted() {
            visit(name)
        }
        return order
    }

    private enum VisitState {
        case unvisited
        case visiting
        case done
    }
}
