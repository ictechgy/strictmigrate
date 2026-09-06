import Foundation

/// Renders the copy-paste prompt for one atomic task — the "agent holds the
/// pen" contract: fix exactly these diagnostics in exactly this symbol,
/// nothing else. Works pasted into a human's editor, a chat agent, or (v0.3)
/// an automated executor.
enum TaskPrompt {
    static func render(
        task: TaskRecord,
        diagnostics: [ConcurrencyDiagnostic],
        level: StrictLevel,
        kotlinFixTargets: [String] = []
    ) -> String {
        var out: [String] = []
        out.append("Task \(task.id) — target \(task.target)")
        out.append("File: \(task.file)")
        out.append("Symbol(s): \(task.symbols.joined(separator: ", "))")
        out.append("")

        out.append("Diagnostics to fix — only these:")
        if diagnostics.isEmpty {
            for summary in task.diagnostics {
                out.append("  - \(summary) (see journal; locations from the last build log unavailable)")
            }
        } else {
            for diagnostic in diagnostics.sorted(by: { ($0.line, $0.column) < ($1.line, $1.column) }) {
                out.append("  - \(diagnostic.file):\(diagnostic.line):\(diagnostic.column) [\(diagnostic.category.rawValue)] \(diagnostic.severity.rawValue): \(diagnostic.message)")
            }
        }
        out.append("")

        out.append("Scope rules (hard boundaries):")
        out.append("1. Modify ONLY `\(task.file)`, ONLY the symbol(s) above.")
        if !kotlinFixTargets.isEmpty {
            out.append("   KMP boundary: the offending type is declared in Kotlin. You may ALSO edit:")
            for path in kotlinFixTargets {
                out.append("   - \(path)")
            }
            out.append("   Prefer fixing the Kotlin declaration (immutability, @ThreadSafe, removing shared mutable state) over patching the Swift call site.")
        }
        out.append("2. Do not touch other files or symbols, even if you see problems there — they belong to other tasks.")
        out.append("3. Do not silence diagnostics with `@unchecked Sendable`, `nonisolated(unsafe)`, or force-unwrapping unless the semantics genuinely allow it; prefer real isolation design.")
        out.append("4. Success = these diagnostics disappear and no new diagnostics appear anywhere in the package.")
        out.append("")

        out.append("Verify (the compiler is the judge):")
        out.append("  swift build --no-color-diagnostics -Xswiftc -strict-concurrency=\(level.rawValue)")
        out.append("  strictmigrate measure   # updates the journal; closes \(task.id) when clean")
        return out.joined(separator: "\n") + "\n"
    }
}
