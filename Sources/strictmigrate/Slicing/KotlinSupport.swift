import Foundation

/// Kotlin-side support for KMP boundary work: Swift-side strict-concurrency
/// diagnostics point at Swift call sites, but the non-Sendable types they
/// complain about are usually declared in the shared Kotlin module. This file
/// attributes `.kt` files to Gradle modules/source sets and routes diagnostics
/// back to the Kotlin declarations that caused them.

/// Attributes Kotlin files to `module/sourceSet` using Gradle directory
/// conventions, without running Gradle: walk up from the file until an
/// `src/<sourceSet>/(kotlin|java)` segment appears, then on to the nearest
/// directory containing `build.gradle`/`build.gradle.kts` for the module name.
enum GradleTargetHeuristic {
    static func target(forKotlinFile file: String, repoRoot: String) -> String? {
        let components = file.split(separator: "/").map(String.init)
        guard let sourceSetIndex = components.firstIndex(where: { $0 == "src" }),
              sourceSetIndex + 2 < components.count,
              components[sourceSetIndex + 2] == "kotlin" || components[sourceSetIndex + 2] == "java"
        else { return nil }

        let sourceSet = components[sourceSetIndex + 1]
        let moduleDirectory = components[0..<sourceSetIndex].last ?? ""

        let module: String
        if hasGradleBuildFile(directory: Array(components[0..<sourceSetIndex]), repoRoot: repoRoot) {
            module = moduleDirectory.isEmpty ? repoRootFileName(repoRoot) : moduleDirectory
        } else {
            module = moduleDirectory
        }
        return "\(module)/\(sourceSet)"
    }

    /// Enumerates `module/sourceSet` targets present in the repository (for
    /// zero-diagnostic journal entries).
    static func sourceSetTargets(repoRoot: String) -> [String] {
        var targets = Set<String>()
        guard let enumerator = FileManager.default.enumerator(atPath: repoRoot) else { return [] }
        let skippedPrefixes: Set<String> = [".git", ".build", "build", ".strictmigrate", ".gradle", "DerivedData", ".swiftpm", "Pods"]

        while case let path as String = enumerator.nextObject() {
            let components = path.split(separator: "/").map(String.init)
            guard let index = components.firstIndex(of: "src"),
                  index + 2 < components.count,
                  ["kotlin", "java"].contains(components[index + 2]),
                  path.hasSuffix(".kt")
            else { continue }
            if components.contains(where: { skippedPrefixes.contains($0) }) { continue }
            let moduleDirectory = components[0..<index].last ?? ""
            let module = hasGradleBuildFile(directory: Array(components[0..<index]), repoRoot: repoRoot)
                ? (moduleDirectory.isEmpty ? repoRootFileName(repoRoot) : moduleDirectory)
                : moduleDirectory
            targets.insert("\(module)/\(components[index + 1])")
        }
        return targets.sorted()
    }

    private static func hasGradleBuildFile(directory: [String], repoRoot: String) -> Bool {
        guard !directory.isEmpty else {
            // The repository root itself: check build files directly.
            return ["build.gradle", "build.gradle.kts"].contains { FileManager.default.fileExists(atPath: repoRoot + "/" + $0) }
        }
        let path = (repoRoot as NSString).appendingPathComponent(directory.joined(separator: "/"))
        return ["build.gradle", "build.gradle.kts"].contains { FileManager.default.fileExists(atPath: path + "/" + $0) }
    }

    private static func repoRootFileName(_ repoRoot: String) -> String {
        URL(fileURLWithPath: repoRoot).lastPathComponent
    }
}

/// A snapshot of the repository's Kotlin sources, built once per measurement
/// so per-attempt routing does not re-walk (and re-read) the whole tree.
/// Failed attempts revert atomically, which keeps a snapshot valid for every
/// attempt dispatched against the measurement it followed.
struct KotlinSourceIndex: Sendable {
    let sources: [(path: String, source: String)]

    init(repoRoot: String) {
        sources = TaskRouter.kotlinSources(repoRoot: repoRoot)
    }
}

/// Routes Swift-side Sendable diagnostics back to the Kotlin declarations of
/// the types they name — the KMP boundary's actual fix locations.
///
/// Deterministic on both ends: `slice`/`next` use it for prompt guidance and
/// the executor uses the same function to widen the attempt's allowed files,
/// so "which Kotlin file may I edit" never depends on who computed it.
enum TaskRouter {
    /// Kotlin files where the task's non-Sendable types are declared.
    /// Capped so a vague diagnostic can't explode the edit scope.
    /// `index` is an optional prefetch of the Kotlin sources; results are
    /// identical with and without it.
    static func kotlinFixTargets(
        diagnostics: [ConcurrencyDiagnostic],
        task: TaskRecord,
        repoRoot: String,
        index: KotlinSourceIndex? = nil,
        cap: Int = 2
    ) -> [String] {
        let typeNames = typeNames(diagnostics: diagnostics.filter { $0.file == task.file })
        guard !typeNames.isEmpty else { return [] }

        let sources = index?.sources ?? kotlinSources(repoRoot: repoRoot)
        var routed: Set<String> = []
        for (path, source) in sources {
            for typeName in typeNames where declares(typeName, in: source) {
                routed.insert(path)
                if routed.count >= cap { return sortedPaths(routed) }
            }
        }
        return sortedPaths(routed)
    }

    /// Type names extracted from Sendable-flavored diagnostic messages, e.g.
    /// `type 'SharedFoo' does not conform to the 'Sendable' protocol`.
    /// Matching is case-insensitive: toolchains phrase the same rule as both
    /// `non-sendable type 'X'` and `non-Sendable type 'X' of …`.
    static func typeNames(diagnostics: [ConcurrencyDiagnostic]) -> Set<String> {
        let patterns = [
            try! Regex(#"(?i)type '([A-Za-z_][A-Za-z0-9_]*)' does not conform to the 'Sendable'"#),
            try! Regex(#"(?i)non-sendable type '([A-Za-z_][A-Za-z0-9_]*)'"#),
            try! Regex(#"(?i)capture of '[A-Za-z_][A-Za-z0-9_]*' with non-sendable type '([A-Za-z_][A-Za-z0-9_]*)'"#),
        ]
        var names = Set<String>()
        for diagnostic in diagnostics where diagnostic.category == .sendable || diagnostic.category == .other {
            for pattern in patterns {
                if let match = try? pattern.firstMatch(in: diagnostic.message), let name = match.output[1].substring {
                    names.insert(String(name))
                }
            }
        }
        return names
    }

    /// Kotlin declaration line for a type: `(class|object|interface|enum class|value class) Name`.
    private static func declares(_ typeName: String, in source: String) -> Bool {
        let pattern = "(?:^|\\n)\\s*(?:@[A-Za-z]+\\s+)*(?:(?:private|internal|public|protected|open|abstract|sealed|final|expect|actual|data|value|enum|fun)\\s+)*(class|object|interface)\\s+\(typeName)\\b"
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        return regex.firstMatch(in: source, range: range) != nil
    }

    /// All `.kt` files under the repo (bounded), mapped to repo-relative paths.
    static func kotlinSources(repoRoot: String) -> [(path: String, source: String)] {
        guard let enumerator = FileManager.default.enumerator(atPath: repoRoot) else { return [] }
        let skippedPrefixes: Set<String> = [".git", ".build", "build", ".strictmigrate", ".gradle", "DerivedData", ".swiftpm", "Pods"]
        var results: [(String, String)] = []
        while case let path as String = enumerator.nextObject() {
            guard path.hasSuffix(".kt"),
                  !path.split(separator: "/").map(String.init).contains(where: skippedPrefixes.contains)
            else { continue }
            let absolute = (repoRoot as NSString).appendingPathComponent(path)
            if let source = try? String(contentsOfFile: absolute, encoding: .utf8) {
                results.append((path, source))
            }
            if results.count > 200 { break }
        }
        return results
    }

    private static func sortedPaths(_ set: Set<String>) -> [String] {
        set.sorted()
    }
}

/// Extends the SPM-based mapper with Kotlin attribution: `.kt` files map to
/// their Gradle module/source set; everything else behaves as before.
struct HybridTargetMapper: Sendable {
    var spm: TargetMapper
    var repoRoot: String

    func target(forFile file: String) -> String? {
        if let spmTarget = spm.target(forFile: file) {
            return spmTarget
        }
        if SourceLanguage(path: file) == .kotlin {
            return GradleTargetHeuristic.target(forKotlinFile: file, repoRoot: repoRoot)
        }
        return nil
    }

    /// Per-target tallies: every diagnostic is attributed exactly once through
    /// the hybrid mapper — SPM targets for Swift files, Gradle module/source
    /// sets for `.kt` files, `(unattributed)` for the rest. Known targets get
    /// zero entries so clean ones show up in the journal too.
    func tally(_ diagnostics: [ConcurrencyDiagnostic]) -> [String: DiagnosticCounts] {
        var counts: [String: DiagnosticCounts] = [:]
        for target in spm.targets {
            counts[target.name] = .zero
        }
        for target in GradleTargetHeuristic.sourceSetTargets(repoRoot: repoRoot) where counts[target] == nil {
            counts[target] = .zero
        }
        for diagnostic in diagnostics where diagnostic.category.isTracked {
            let name = target(forFile: diagnostic.file) ?? TargetMapper.unattributed
            counts[name, default: .zero].add(diagnostic.category)
        }
        return counts
    }
}
