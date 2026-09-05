import ArgumentParser
import Foundation

@main
struct StrictMigrate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "strictmigrate",
        abstract: "Measure, journal, and report a Swift 6 strict-concurrency migration.",
        discussion: """
            The compiler is the judge, the journal is the source of truth.
            v0.1 measures diagnostics per target and tracks progress — no agent required.
            """,
        version: "0.1.0",
        subcommands: [Init.self, Measure.self, Status.self]
    )
}

/// Options shared by every subcommand: where the package and journal live.
struct LocationOptions: ParsableArguments {
    @Option(name: .long, help: "Package root (directory containing Package.swift).")
    var packagePath: String = "."

    @Option(name: .shortAndLong, help: "Journal file, relative to the package root unless absolute.")
    var journal: String = JournalStore.defaultFileName

    var resolvedRoot: String {
        PathUtils.resolved(URL(fileURLWithPath: packagePath).standardizedFileURL.path)
    }

    var resolvedJournalPath: String {
        journal.hasPrefix("/") ? journal : (resolvedRoot as NSString).appendingPathComponent(journal)
    }
}

extension StrictLevel: ExpressibleByArgument {}
extension StatusReport.Format: ExpressibleByArgument {}

// MARK: - init

extension StrictMigrate {
    struct Init: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "init",
            abstract: "Create an empty migration journal in the package root."
        )

        @OptionGroup var location: LocationOptions

        func run() throws {
            let path = location.resolvedJournalPath
            _ = try JournalStore.create(at: path)
            _ = try JournalStore.ensureWorkDirectory(in: location.resolvedRoot)

            print("Created \(path)")
            print("Next: `strictmigrate measure` to record the first baseline, then `strictmigrate status`.")
        }
    }
}

// MARK: - measure

extension StrictMigrate {
    struct Measure: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build with strict concurrency, count diagnostics per target, update the journal.",
            discussion: """
                SwiftPM packages are built in place with `swift build -Xswiftc -strict-concurrency=<level>`.
                For Xcode projects, build once with `xcodebuild … -resultBundlePath out.xcresult` and pass --xcresult.
                A failing build is expected mid-migration; the exit code is reported, not treated as an error.
                """
        )

        @OptionGroup var location: LocationOptions

        @Option(name: .shortAndLong, help: "Strict concurrency level to measure at: minimal, targeted, complete.")
        var level: StrictLevel = .complete

        @Flag(name: .long, help: "Also build test targets (`swift build --build-tests`).")
        var withTests = false

        @Flag(name: .long, help: """
            Reuse the package's own .build (fast, but warnings from files that did not \
            recompile are not re-emitted and will be undercounted).
            """)
        var incremental = false

        @Option(name: .long, help: "Parse an existing .xcresult bundle instead of running `swift build`.")
        var xcresult: String?

        @Option(name: .customLong("Xswiftc"), parsing: .unconditionalSingleValue, help: "Extra swiftc flag (repeatable).")
        var swiftcFlags: [String] = []

        @Flag(name: .long, help: "Print every tracked diagnostic after the summary.")
        var verbose = false

        func run() throws {
            let root = location.resolvedRoot
            let journalPath = location.resolvedJournalPath
            var journal = try JournalStore.load(at: journalPath)

            let warn: (String) -> Void = { message in
                FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
            }

            let outcome: MeasureOutcome
            if let xcresult {
                outcome = try MeasureRunner.measureXcresult(bundlePath: xcresult, root: root, warn: warn)
            } else {
                var extra: [String] = []
                for flag in swiftcFlags {
                    extra += ["-Xswiftc", flag]
                }
                let options = SPMBuilder.Options(level: level, buildTests: withTests, extraArguments: extra)
                print("Building with -strict-concurrency=\(level.rawValue) …")
                outcome = try MeasureRunner.measureSwiftPackage(
                    root: root,
                    options: options,
                    incremental: incremental,
                    warn: warn
                )
            }

            let previous = journal.targets
            journal.applyMeasurement(at: Date(), level: level, results: outcome.perTarget)
            try JournalStore.save(journal, to: journalPath)

            let workDirectory = try JournalStore.ensureWorkDirectory(in: root)
            let logPath = (workDirectory as NSString).appendingPathComponent(
                xcresult == nil ? "last-build.log" : "last-xcresult.json"
            )
            try outcome.rawLog.write(toFile: logPath, atomically: true, encoding: .utf8)

            print(Self.summary(outcome: outcome, previous: previous, journalPath: journalPath, logPath: logPath))
            if verbose {
                print(Self.listing(outcome.diagnostics))
            }
        }

        static func summary(
            outcome: MeasureOutcome,
            previous: [String: TargetState],
            journalPath: String,
            logPath: String
        ) -> String {
            var out: [String] = []
            if let command = outcome.buildCommand {
                let exit = outcome.buildExitCode.map { "exit \($0)" } ?? "exit ?"
                out.append("build: \(command) (\(exit))")
            }
            let t = outcome.tracked
            out.append(
                "diagnostics: \(t.trackedTotal) tracked (sendable \(t.sendable), isolation \(t.isolation), "
                    + "region \(t.region), other \(t.other)); \(outcome.unrelatedCount) unrelated, not counted"
            )
            if !outcome.targetsKnown {
                out.append("targets: unknown — all diagnostics attributed to \(TargetMapper.unattributed)")
            }
            out.append("")

            let rows = outcome.perTarget.sorted { lhs, rhs in
                if lhs.value.trackedTotal != rhs.value.trackedTotal {
                    return lhs.value.trackedTotal > rhs.value.trackedTotal
                }
                return lhs.key < rhs.key
            }
            let nameWidth = max(6, rows.map { $0.key.count }.max() ?? 6)
            out.append(
                "\(pad("Target", nameWidth)) \(padLeft("Sendable", 9)) \(padLeft("Isolation", 10)) "
                    + "\(padLeft("Region", 7)) \(padLeft("Other", 6)) \(padLeft("Total", 6))   Δ vs previous"
            )
            for (name, counts) in rows {
                let delta: String
                if let before = previous[name]?.diagnosticsBaseline {
                    let diff = counts.trackedTotal - before.trackedTotal
                    delta = diff == 0 ? "±0" : (diff > 0 ? "+\(diff)" : "\(diff)")
                } else {
                    delta = "new"
                }
                out.append(
                    "\(pad(name, nameWidth)) \(padLeft(String(counts.sendable), 9)) \(padLeft(String(counts.isolation), 10)) "
                        + "\(padLeft(String(counts.region), 7)) \(padLeft(String(counts.other), 6)) "
                        + "\(padLeft(String(counts.trackedTotal), 6))   \(delta)"
                )
            }
            out.append("")
            out.append("journal updated: \(journalPath)")
            out.append("raw log: \(logPath)")
            return out.joined(separator: "\n")
        }

        static func listing(_ diagnostics: [ConcurrencyDiagnostic]) -> String {
            diagnostics
                .filter { $0.category.isTracked }
                .sorted { ($0.file, $0.line, $0.column) < ($1.file, $1.line, $1.column) }
                .map { "\($0.file):\($0.line):\($0.column): [\($0.category.rawValue)] \($0.severity.rawValue): \($0.message)" }
                .joined(separator: "\n")
        }

        private static func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
        }

        private static func padLeft(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
        }
    }
}

// MARK: - status

extension StrictMigrate {
    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Report per-target remaining diagnostics and completion rate from the journal."
        )

        @OptionGroup var location: LocationOptions

        @Option(name: .shortAndLong, help: "Output format: pretty, markdown, json.")
        var format: StatusReport.Format = .pretty

        func run() throws {
            let journalPath = location.resolvedJournalPath
            let journal = try JournalStore.load(at: journalPath)
            let displayPath = PathUtils.relativize(journalPath, against: FileManager.default.currentDirectoryPath)
            print(try StatusReport.render(journal, format: format, journalPath: displayPath), terminator: "")
        }
    }
}
