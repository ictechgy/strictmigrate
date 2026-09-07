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
        var resolver = SymbolResolver(packageRoot: packageRoot)

        for diagnostic in diagnostics where diagnostic.category.isTracked {
            let target = mapper.target(forFile: diagnostic.file) ?? TargetMapper.unattributed
            let symbol = resolver.symbolName(for: diagnostic)
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
