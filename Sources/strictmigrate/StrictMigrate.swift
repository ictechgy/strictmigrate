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
        version: "0.5.0",
        subcommands: [
            Init.self, Measure.self, Status.self, Slice.self, Next.self, Tasks.self, Run.self, Skip.self,
        ]
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
                journal.measuredWith = MeasureRunner.swiftVersionLabel()
            }

            let previous = journal.targets
            journal.applyMeasurement(at: Date(), level: level, results: outcome.perTarget)
            let closedTasks = journal.reconcileTasks(
                against: outcome.diagnostics,
                packageRoot: root,
                buildExitCode: outcome.buildExitCode
            )
            try JournalStore.save(journal, to: journalPath)

            let workDirectory = try JournalStore.ensureWorkDirectory(in: root)
            let logPath = (workDirectory as NSString).appendingPathComponent(
                xcresult == nil ? "last-build.log" : "last-xcresult.json"
            )
            try outcome.rawLog.write(toFile: logPath, atomically: true, encoding: .utf8)

            print(Self.summary(outcome: outcome, previous: previous, journalPath: journalPath, logPath: logPath))
            if !closedTasks.isEmpty {
                let names = closedTasks.joined(separator: ", ")
                print("tasks passed: \(closedTasks.count) (\(names)) — diagnostics gone, journal closed them")
                if journal.openTasks.count > 0 {
                    print("tasks still open: \(journal.openTasks.count)")
                }
            }
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

// MARK: - slice

extension StrictMigrate {
    struct Slice: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "slice",
            abstract: "Turn the last measurement into atomic tasks (one symbol group = one task).",
            discussion: """
                Reads the raw log saved by the last `strictmigrate measure`, clusters tracked \
                diagnostics by (target, file, enclosing symbol), and replaces the queued backlog \
                in the journal. Leaf targets come first — fix dependencies before dependents.
                """
        )

        @OptionGroup var location: LocationOptions

        @Option(name: .long, help: "Build log to slice from (default: .strictmigrate/last-build.log).")
        var fromLog: String?

        func run() throws {
            let root = location.resolvedRoot
            let journalPath = location.resolvedJournalPath
            var journal = try JournalStore.load(at: journalPath)

            let logPath = try Self.resolvedLogPath(fromLog, root: root)
            let log = try String(contentsOfFile: logPath, encoding: .utf8)
            let diagnostics = CompilerLogParser().parse(log, workingDirectory: root)
            guard diagnostics.contains(where: { $0.category.isTracked }) else {
                print("No tracked diagnostics in \(PathUtils.relativize(logPath, against: FileManager.default.currentDirectoryPath)) — nothing to slice.")
                return
            }

            let warn: (String) -> Void = { message in
                FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
            }
            let targets = (try? PackageInspector.targets(packageRoot: root)) ?? []
            if targets.isEmpty {
                warn("target list unavailable; ordering falls back to diagnostics count and SPM targets attribute to \(TargetMapper.unattributed)")
            }
            let mapper = HybridTargetMapper(spm: TargetMapper(targets: targets), repoRoot: root)
            let order = TargetPriority.leafFirstOrder(dependencies: PackageInspector.dependencyGraph(targets))

            let fresh = TaskSlicer.slice(
                diagnostics: diagnostics,
                packageRoot: root,
                mapper: mapper,
                options: TaskSlicer.Options(targetOrder: order, firstTaskNumber: journal.nextTaskNumber)
            )
            let dropped = journal.replaceQueue(with: fresh)
            try JournalStore.save(journal, to: journalPath)

            print("Queued \(fresh.count) task\(fresh.count == 1 ? "" : "s") (dropped \(dropped) stale queued) — journal updated: \(journalPath)")
            print("")
            print("Next up:")
            for task in fresh.prefix(5) {
                print("  \(task.id)  \(task.target)  \(task.file)  [\(task.symbols.joined(separator: ", "))]  (\(task.diagnostics.joined(separator: ", ")))")
            }
            if fresh.count > 5 {
                print("  … and \(fresh.count - 5) more — `strictmigrate tasks`")
            }
            print("")
            print("Start with `strictmigrate next`.")
        }

        static func resolvedLogPath(_ fromLog: String?, root: String) throws -> String {
            if let fromLog {
                let path = fromLog.hasPrefix("/") ? fromLog : (root as NSString).appendingPathComponent(fromLog)
                guard FileManager.default.fileExists(atPath: path) else {
                    throw ValidationError("log not found: \(path)")
                }
                return path
            }
            let workDirectory = (root as NSString).appendingPathComponent(JournalStore.workDirectoryName)
            let path = (workDirectory as NSString).appendingPathComponent("last-build.log")
            guard FileManager.default.fileExists(atPath: path) else {
                throw ValidationError("no build log at \(path) — run `strictmigrate measure` first (or pass --from-log)")
            }
            return path
        }
    }
}

// MARK: - next

extension StrictMigrate {
    struct Next: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the next task with a ready-to-paste prompt (manual mode).",
            discussion: """
                Marks the task `assigned` in the journal so repeated calls walk the queue; \
                pass --peek to leave it queued. After fixing, run `strictmigrate measure` — \
                it closes the task automatically when the diagnostics are gone.
                """
        )

        @OptionGroup var location: LocationOptions

        @Flag(name: .long, help: "Show the next task without marking it assigned.")
        var peek = false

        @Flag(name: .long, inversion: .prefixedNo, help: "Include task diagnostics resolved from the last build log (default when available).")
        var withLocations = true

        func run() throws {
            let root = location.resolvedRoot
            let journalPath = location.resolvedJournalPath
            var journal = try JournalStore.load(at: journalPath)

            guard var task = journal.nextQueuedTask else {
                let open = journal.openTasks.count
                if open > 0 {
                    print("No queued tasks — \(open) task(s) assigned and awaiting a measure. Run `strictmigrate measure` or `strictmigrate tasks`.")
                } else {
                    print("Queue is empty. Run `strictmigrate measure` and `strictmigrate slice`.")
                }
                return
            }

            if !peek {
                _ = journal.markAssigned(id: task.id)
                try JournalStore.save(journal, to: journalPath)
                task.status = .assigned
            }

            let level = journal.targets[task.target]?.level ?? .complete
            var diagnostics: [ConcurrencyDiagnostic] = []
            if withLocations {
                diagnostics = Self.diagnosticsFor(task, root: root)
            }
            let routed = TaskRouter.kotlinFixTargets(diagnostics: diagnostics, task: task, repoRoot: root)
            print(
                TaskPrompt.render(
                    task: task, diagnostics: diagnostics, level: level, kotlinFixTargets: routed
                ),
                terminator: ""
            )
        }

        /// Locates the task's diagnostics in the last build log, resolved to
        /// the task's symbol so line drift between slicing and fixing is fine.
        static func diagnosticsFor(_ task: TaskRecord, root: String) -> [ConcurrencyDiagnostic] {
            let workDirectory = (root as NSString).appendingPathComponent(JournalStore.workDirectoryName)
            let logPath = (workDirectory as NSString).appendingPathComponent("last-build.log")
            guard let log = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }

            let all = CompilerLogParser().parse(log, workingDirectory: root)
            guard !all.isEmpty else { return [] }
            let keys = Set(task.symbols.map { SymbolKey(file: task.file, symbol: $0) })
            var resolver = SymbolResolver(packageRoot: root)
            let resolved = resolver.symbolKeys(for: all)
            // Map diagnostics to their symbol identity, keep those in the task.
            return all.filter { diagnostic in
                guard diagnostic.category.isTracked else { return false }
                let symbol = resolver.symbolName(for: diagnostic)
                return keys.contains(SymbolKey(file: diagnostic.file, symbol: symbol))
                    && resolved.contains(SymbolKey(file: diagnostic.file, symbol: symbol))
            }
        }
    }
}

// MARK: - tasks

extension StrictMigrate {
    struct Tasks: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List tasks in the journal."
        )

        @OptionGroup var location: LocationOptions

        @Option(name: .shortAndLong, help: "Only show tasks with this status: queued, assigned, passed, reverted, skipped.")
        var status: TaskRecord.Status?

        func run() throws {
            let journal = try JournalStore.load(at: location.resolvedJournalPath)
            let selected = journal.tasks.filter { status == nil || $0.status == status }

            guard !selected.isEmpty else {
                print(journal.tasks.isEmpty
                    ? "No tasks. Run `strictmigrate measure` and `strictmigrate slice`."
                    : "No tasks with status \(status!.rawValue).")
                return
            }

            let idWidth = 7
            let statusWidth = 9
            let targetWidth = max(6, selected.map { $0.target.count }.max() ?? 6)
            print(
                pad("ID", idWidth), pad("Status", statusWidth), pad("Target", targetWidth),
                "File / Symbols / Diagnostics"
            )
            for task in selected {
                print(
                    pad(task.id, idWidth), pad(task.status.rawValue, statusWidth), pad(task.target, targetWidth),
                    "\(task.file)  [\(task.symbols.joined(separator: ", "))]  (\(task.diagnostics.joined(separator: ", ")))"
                )
            }
            let counts = Dictionary(grouping: journal.tasks, by: \.status).mapValues(\.count)
            let summary = TaskRecord.Status.allCases
                .filter { counts[$0] != nil }
                .map { "\($0.rawValue): \(counts[$0]!)" }
                .joined(separator: ", ")
            print("")
            print("\(journal.tasks.count) tasks total (\(summary))")
        }

        private func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
        }
    }
}

// MARK: - run

extension StrictMigrate {
    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Execute queued tasks through an agent: dispatch, judge, commit or revert.",
            discussion: """
                One task = one commit = one revert boundary. The agent edits code; \
                the compiler judges (task clean, no regressions elsewhere); the journal records. \
                Failed attempts are reverted atomically; after --max-attempts the task lands \
                in `reverted` with reasons in its notes. Prompts, transcripts and build logs \
                are kept under .strictmigrate/.
                """
        )

        @OptionGroup var location: LocationOptions

        @Option(name: .shortAndLong, help: "Execute exactly this task id (must be queued or assigned).")
        var task: String?

        @Option(name: .long, help: "How many queued tasks to execute (0 = drain the queue).")
        var maxTasks: Int = 1

        @Option(name: .long, help: "Attempts per task before giving up as `reverted`.")
        var maxAttempts: Int = 2

        @Option(name: .shortAndLong, help: "Strict concurrency level for verdict builds.")
        var level: StrictLevel = .complete

        @Option(name: .long, help: "Agent backend: `claude`, `codex`, `acp`, or `command` (generic shell).")
        var adapter: String = "claude"

        @Option(name: .long, help: """
            Shell command for --adapter command. Runs in the package root with \
            STRICTMIGRATE_PROMPT_FILE pointing at the prompt; e.g. \
            `codex exec --full-auto "$(cat $STRICTMIGRATE_PROMPT_FILE)"`.
            """)
        var adapterCommand: String?

        @Option(name: .long, help: "ACP agent command for --adapter acp, e.g. `claude-code-acp` or `node agent.js`.")
        var acpCommand: String?

        @Option(name: .long, parsing: .unconditionalSingleValue, help: "Extra argument passed to the claude CLI (repeatable).")
        var claudeArg: [String] = []

        @Option(name: .long, parsing: .unconditionalSingleValue, help: "Extra argument passed to the codex CLI (repeatable).")
        var codexArg: [String] = []

        @Flag(name: .long, help: "Run `swift test` as part of the verdict once the build passes; failures revert the attempt.")
        var tests = false

        @Flag(name: .long, help: "Run tests under ThreadSanitizer; races fail the attempt (implies --tests).")
        var tsan = false

        func run() throws {
            let root = location.resolvedRoot
            let journalPath = location.resolvedJournalPath
            var journal = try JournalStore.load(at: journalPath)

            let ids: [String]
            if let task {
                ids = [task]
            } else {
                ids = journal.queuedTaskIDs(limit: maxTasks)
            }
            guard !ids.isEmpty else {
                print("No queued tasks. Run `strictmigrate measure` and `strictmigrate slice` first.")
                return
            }

            let adapter = try AgentAdapterFactory.make(
                kind: adapter,
                commandLine: adapterCommand,
                claudeArguments: claudeArg,
                codexArguments: codexArg,
                acpCommand: acpCommand
            )
            let workDirectory = try JournalStore.ensureWorkDirectory(in: root)
            let spmTargets = (try? PackageInspector.targets(packageRoot: root)) ?? []
            let executor = TaskExecutor(
                adapter: adapter,
                root: root,
                git: GitWorkingCopy(root: root),
                whitelist: PathWhitelist(journalPath: PathUtils.relativize(journalPath, against: root)),
                journalPath: journalPath,
                workDirectory: workDirectory,
                options: TaskExecutor.Options(
                    level: level,
                    buildTests: false,
                    maxAttempts: maxAttempts,
                    runTests: tests || tsan,
                    tsan: tsan
                ),
                mapper: HybridTargetMapper(spm: TargetMapper(targets: spmTargets), repoRoot: root)
            )

            let reports = try executor.execute(taskIDs: ids, journal: &journal) { line in
                print(line)
            }

            print("")
            print("── summary ──────────────────────────")
            for report in reports {
                let commit = report.commit.map { " commit \($0)" } ?? ""
                print("\(report.taskID): \(report.finalStatus.rawValue)\(commit)")
                for attempt in report.attempts where !attempt.passed {
                    print("   a\(attempt.number): \(attempt.note)")
                }
            }
            let passedCount = reports.filter(\.passed).count
            print("")
            print("\(passedCount)/\(reports.count) passed — journal: \(journalPath)")
        }
    }
}

// MARK: - skip

extension StrictMigrate {
    struct Skip: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Mark a task skipped so the queue moves past it."
        )

        @OptionGroup var location: LocationOptions

        @Argument(help: "Task id, e.g. t-0003.")
        var taskID: String

        func run() throws {
            let journalPath = location.resolvedJournalPath
            var journal = try JournalStore.load(at: journalPath)
            guard journal.markSkipped(id: taskID) else {
                throw ValidationError("no open task \(taskID) in \(journalPath)")
            }
            try JournalStore.save(journal, to: journalPath)
            print("\(taskID) → skipped")
        }
    }
}

extension TaskRecord.Status: ExpressibleByArgument {}
