import Foundation

/// Result of comparing pre/post diagnostics for one attempt.
/// Pass requires BOTH the task's symbols to be clean AND no symbol outside
/// the task getting worse — regressions are enforced per symbol, not just in
/// aggregate.
struct AttemptVerdict: Equatable, Sendable {
    var taskClean: Bool
    /// (file, symbol) identities outside the task that gained diagnostics.
    var regressionsElsewhere: [String]

    var passed: Bool { taskClean && regressionsElsewhere.isEmpty }
}

enum VerdictCalculator {
    static func verdict(
        before: [ConcurrencyDiagnostic],
        after: [ConcurrencyDiagnostic],
        task: TaskRecord,
        packageRoot: String,
        fileTarget: ((String) -> String?)? = nil
    ) -> AttemptVerdict {
        let taskKeys = Set(task.symbols.map { SymbolKey(file: task.file, symbol: $0) })
        // One resolver across both sides: attribution is by name (line drift
        // between measurements is tolerated by design), and both sides resolve
        // against the current sources — sharing the cache halves the reads.
        var resolver = SymbolResolver(packageRoot: packageRoot)
        let beforeCounts = symbolCounts(before, resolver: &resolver)
        let afterCounts = symbolCounts(after, resolver: &resolver)

        let taskClean = taskKeys.isDisjoint(with: Set(afterCounts.keys))
        var regressions: [String] = []
        for (key, afterCount) in afterCounts where !taskKeys.contains(key) {
            let beforeCount = beforeCounts[key] ?? 0
            if afterCount > beforeCount {
                let delta = afterCount - beforeCount
                if let target = fileTarget?(key.file), target != task.target {
                    // Cross-target regression: the fix in one target broke another.
                    regressions.append("\(target):\(key.file) [\(key.symbol)] +\(delta)")
                } else {
                    regressions.append("\(key.file) [\(key.symbol)] +\(delta)")
                }
            }
        }

        return AttemptVerdict(taskClean: taskClean, regressionsElsewhere: regressions.sorted())
    }

    private static func symbolCounts(
        _ diagnostics: [ConcurrencyDiagnostic],
        resolver: inout SymbolResolver
    ) -> [SymbolKey: Int] {
        var counts: [SymbolKey: Int] = [:]
        for diagnostic in diagnostics where diagnostic.category.isTracked {
            let symbol = resolver.symbolName(for: diagnostic)
            counts[SymbolKey(file: diagnostic.file, symbol: symbol), default: 0] += 1
        }
        return counts
    }
}
