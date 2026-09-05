import Foundation

/// A SwiftPM target and its source root, relative to the package root.
struct PackageTarget: Equatable, Sendable {
    var name: String
    var path: String
    var dependencies: [String] = []
}

/// Maps diagnostic file paths to targets by longest matching source root.
struct TargetMapper: Sendable {
    static let unattributed = "(unattributed)"

    var targets: [PackageTarget]

    init(targets: [PackageTarget]) {
        self.targets = targets.sorted { $0.path.count > $1.path.count }
    }

    /// - Parameter file: repository-relative path.
    func target(forFile file: String) -> String? {
        for target in targets {
            let root = target.path.hasSuffix("/") ? target.path : target.path + "/"
            if file.hasPrefix(root) || file == target.path {
                return target.name
            }
        }
        return nil
    }

    /// Groups diagnostics into per-target counts. Every known target gets an
    /// entry (possibly zero) so clean targets show up in the journal too;
    /// diagnostics outside any target root land under `(unattributed)`.
    func tally(_ diagnostics: [ConcurrencyDiagnostic]) -> [String: DiagnosticCounts] {
        var counts: [String: DiagnosticCounts] = [:]
        for target in targets {
            counts[target.name] = .zero
        }
        for diagnostic in diagnostics where diagnostic.category.isTracked {
            let name = target(forFile: diagnostic.file) ?? Self.unattributed
            counts[name, default: .zero].add(diagnostic.category)
        }
        return counts
    }
}

/// Reads the target list from `swift package describe --type json`.
enum PackageInspector {
    enum InspectError: Error, CustomStringConvertible {
        case describeFailed(exitCode: Int32, stderr: String)
        case malformed

        var description: String {
            switch self {
            case .describeFailed(let exitCode, let stderr):
                return "`swift package describe` failed (exit \(exitCode)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            case .malformed:
                return "`swift package describe` returned JSON without a targets array"
            }
        }
    }

    static func targets(packageRoot: String) throws -> [PackageTarget] {
        let result = try Shell.run(
            "swift",
            arguments: ["package", "describe", "--type", "json"],
            currentDirectory: packageRoot
        )
        guard result.exitCode == 0 else {
            throw InspectError.describeFailed(exitCode: result.exitCode, stderr: result.stderrText)
        }
        return try parse(describeJSON: result.stdout, packageRoot: packageRoot)
    }

    static func parse(describeJSON data: Data, packageRoot: String) throws -> [PackageTarget] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawTargets = root["targets"] as? [[String: Any]]
        else { throw InspectError.malformed }

        return rawTargets.compactMap { raw in
            guard let name = raw["name"] as? String, let path = raw["path"] as? String else { return nil }
            let relative = path.hasPrefix("/") ? PathUtils.relativize(path, against: packageRoot) : path
            let dependencies = raw["target_dependencies"] as? [String] ?? []
            return PackageTarget(name: name, path: relative, dependencies: dependencies)
        }
    }

    /// Target name → names of targets it depends on, for leaf-first ordering.
    static func dependencyGraph(_ targets: [PackageTarget]) -> [String: [String]] {
        targets.reduce(into: [:]) { graph, target in
            graph[target.name] = target.dependencies
        }
    }
}

/// Runs `swift build` with strict concurrency enforced and returns the raw log.
enum SPMBuilder {
    struct Options: Sendable {
        var level: StrictLevel
        var buildTests: Bool
        var extraArguments: [String] = []
        /// Dedicated scratch directory. Measuring from a fresh scratch is the
        /// default: incremental builds do not re-emit warnings from files that
        /// did not recompile, which would silently shrink the counts.
        var scratchPath: String?
    }

    static func arguments(for options: Options) -> [String] {
        var args = ["build", "--no-color-diagnostics"]
        if options.buildTests {
            args.append("--build-tests")
        }
        if let scratchPath = options.scratchPath {
            args += ["--scratch-path", scratchPath]
        }
        args += ["-Xswiftc", "-strict-concurrency=\(options.level.rawValue)"]
        args += options.extraArguments
        return args
    }

    static func build(packageRoot: String, options: Options) throws -> ShellResult {
        try Shell.run("swift", arguments: arguments(for: options), currentDirectory: packageRoot)
    }
}
