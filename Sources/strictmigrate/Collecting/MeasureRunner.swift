import Foundation

/// Result of one measurement pass, before it is merged into the journal.
struct MeasureOutcome {
    var diagnostics: [ConcurrencyDiagnostic]
    var perTarget: [String: DiagnosticCounts]
    var targetsKnown: Bool
    var buildCommand: String?
    var buildExitCode: Int32?
    var rawLog: String

    var tracked: DiagnosticCounts {
        var counts = DiagnosticCounts.zero
        for diagnostic in diagnostics {
            counts.add(diagnostic.category)
        }
        return counts
    }

    var unrelatedCount: Int {
        diagnostics.filter { $0.category == .unrelated }.count
    }

    /// False when the build produced non-concurrency errors (syntax,
    /// unresolved identifiers, …): the compiler may have stopped before
    /// emitting every concurrency diagnostic, so tracked counts can be
    /// incomplete and tasks must not be closed — or attempts passed — on
    /// such a measurement. Unrelated *warnings* (style noise) stay
    /// trustworthy; a build failing on tracked concurrency errors alone is
    /// the normal mid-migration case and trustworthy too.
    var isTrustworthy: Bool {
        !diagnostics.contains { $0.category == .unrelated && $0.severity == .error }
    }
}

/// Orchestrates collection: run (or read) the build, parse, attribute to targets.
enum MeasureRunner {
    enum RunError: Error, CustomStringConvertible {
        case noPackage(root: String)
        case xcresultExportFailed(path: String, detail: String)

        var description: String {
            switch self {
            case .noPackage(let root):
                return "no Package.swift in \(root) — pass --xcresult for Xcode projects"
            case .xcresultExportFailed(let path, let detail):
                return "could not export \(path) via xcresulttool: \(detail)"
            }
        }
    }

    /// Full SPM pipeline: `swift package describe` for targets, `swift build`
    /// under the requested strict-concurrency level, parse the log.
    ///
    /// Unless `incremental` is set, the build runs in a throw-away scratch
    /// directory under `.strictmigrate/` so every file recompiles and every
    /// diagnostic is emitted; the package's own `.build` is left untouched.
    static func measureSwiftPackage(
        root: String,
        options: SPMBuilder.Options,
        incremental: Bool = false,
        warn: (String) -> Void = { _ in }
    ) throws -> MeasureOutcome {
        let manifest = (root as NSString).appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: manifest) else {
            throw RunError.noPackage(root: root)
        }

        var options = options
        var scratch: String?
        if !incremental {
            let workDirectory = try JournalStore.ensureWorkDirectory(in: root)
            let path = (workDirectory as NSString).appendingPathComponent("measure-scratch")
            try? FileManager.default.removeItem(atPath: path)
            options.scratchPath = path
            scratch = path
        }
        defer {
            if let scratch {
                try? FileManager.default.removeItem(atPath: scratch)
            }
        }

        let mapper = hybridMapper(root: root, warn: warn)
        let result = try SPMBuilder.build(packageRoot: root, options: options)
        let log = result.combinedText
        let diagnostics = CompilerLogParser().parse(log, workingDirectory: root)

        return MeasureOutcome(
            diagnostics: diagnostics,
            perTarget: mapper.tally(diagnostics),
            targetsKnown: !mapper.spm.targets.isEmpty,
            buildCommand: (["swift"] + SPMBuilder.arguments(for: options)).joined(separator: " "),
            buildExitCode: result.exitCode,
            rawLog: log
        )
    }

    /// Xcode pipeline: export an existing `.xcresult` bundle to JSON and parse
    /// its issue summaries. Targets are attributed through `Package.swift`
    /// when one is present (xcodebuild on a package), plus Gradle module/source-
    /// sets for `.kt` files — the KMP boundary case, where Swift-side
    /// diagnostics are fixed in the shared Kotlin module.
    static func measureXcresult(
        bundlePath: String,
        root: String,
        warn: (String) -> Void = { _ in }
    ) throws -> MeasureOutcome {
        let json = try exportXcresult(bundlePath: bundlePath)
        let diagnostics = try XcresultParser().parse(jsonData: json, workingDirectory: root)

        let manifest = (root as NSString).appendingPathComponent("Package.swift")
        let spmMapper = FileManager.default.fileExists(atPath: manifest)
            ? targetMapper(root: root, warn: warn)
            : TargetMapper(targets: [])
        let mapper = HybridTargetMapper(spm: spmMapper, repoRoot: root)

        return MeasureOutcome(
            diagnostics: diagnostics,
            perTarget: mapper.tally(diagnostics),
            targetsKnown: !mapper.spm.targets.isEmpty,
            buildCommand: nil,
            buildExitCode: nil,
            rawLog: String(decoding: json, as: UTF8.self)
        )
    }

    /// Short toolchain identity recorded in the journal (`measured_with`), so
    /// diagnostic-count changes can be traced to compiler/SDK drift — the
    /// surface genuinely differs per toolchain pair.
    static func swiftVersionLabel() -> String? {
        guard let result = try? Shell.run("swift", arguments: ["--version"]) else { return nil }
        let text = result.stdoutText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(2)
            .joined(separator: "; ")
        return text.isEmpty ? nil : text
    }

    private static func targetMapper(root: String, warn: (String) -> Void) -> TargetMapper {
        do {
            return TargetMapper(targets: try PackageInspector.targets(packageRoot: root))
        } catch {
            warn("target attribution unavailable (\(error)); diagnostics will be reported as \(TargetMapper.unattributed)")
            return TargetMapper(targets: [])
        }
    }

    /// SPM targets plus Kotlin/Gradle attribution for KMP repositories.
    private static func hybridMapper(root: String, warn: (String) -> Void) -> HybridTargetMapper {
        HybridTargetMapper(spm: targetMapper(root: root, warn: warn), repoRoot: root)
    }

    /// Xcode 16+ requires `--legacy` for the ActionsInvocationRecord shape;
    /// older xcresulttool rejects the flag. Try both.
    private static func exportXcresult(bundlePath: String) throws -> Data {
        let attempts: [[String]] = [
            ["xcresulttool", "get", "--legacy", "--format", "json", "--path", bundlePath],
            ["xcresulttool", "get", "--format", "json", "--path", bundlePath],
        ]
        var lastError = ""
        for arguments in attempts {
            let result = try Shell.run("xcrun", arguments: arguments)
            if result.exitCode == 0, !result.stdout.isEmpty {
                return result.stdout
            }
            lastError = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw RunError.xcresultExportFailed(path: bundlePath, detail: lastError)
    }
}
