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
    /// Preferred entry point for the executor loop: `beforeCounts` must be
    /// resolved against the PRE-edit sources (captured right after the
    /// previous measurement). Resolving the before side lazily against
    /// post-edit sources would misattribute diagnostics whose lines shifted
    /// when lines were added or removed above them — a pure line shift must
    /// not read as a new regression.
    static func verdict(
        beforeCounts: [SymbolKey: Int],
        after: [ConcurrencyDiagnostic],
        task: TaskRecord,
        packageRoot: String,
        fileTarget: ((String) -> String?)? = nil
    ) -> AttemptVerdict {
        let taskKeys = Set(task.symbols.map { SymbolKey(file: task.file, symbol: $0) })
        var resolver = SymbolResolver(packageRoot: packageRoot)
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

    /// Convenience for callers that hold both sides of one snapshot (tests,
    /// offline analysis): both counts resolve against the current sources.
    static func verdict(
        before: [ConcurrencyDiagnostic],
        after: [ConcurrencyDiagnostic],
        task: TaskRecord,
        packageRoot: String,
        fileTarget: ((String) -> String?)? = nil
    ) -> AttemptVerdict {
        verdict(
            beforeCounts: symbolCounts(before, packageRoot: packageRoot),
            after: after,
            task: task,
            packageRoot: packageRoot,
            fileTarget: fileTarget
        )
    }

    /// (file, symbol) → diagnostic count, resolved against the sources as
    /// they are right now. Call this immediately after a measurement to
    /// freeze that measurement's attribution.
    static func symbolCounts(
        _ diagnostics: [ConcurrencyDiagnostic],
        packageRoot: String
    ) -> [SymbolKey: Int] {
        var resolver = SymbolResolver(packageRoot: packageRoot)
        return symbolCounts(diagnostics, resolver: &resolver)
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
