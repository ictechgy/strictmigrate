import Foundation

/// One attempt within a task execution.
struct AttemptReport: Equatable, Sendable {
    var number: Int
    var agentExitCode: Int32
    var scopeViolations: [String] = []
    var verdict: AttemptVerdict?
    var note: String
    var passed: Bool { verdict?.passed == true && scopeViolations.isEmpty }
}

/// Final outcome for one task.
struct TaskExecutionReport: Equatable, Sendable {
    var taskID: String
    var attempts: [AttemptReport]
    var finalStatus: TaskRecord.Status
    var commit: String?

    var passed: Bool { finalStatus == .passed }
}

/// The v0.3 agent loop: dispatch → scope-check → measure → verdict →
/// commit-or-revert → journal. Everything is deterministic except the agent's
/// edits; every failure leaves the tree exactly as it was found.
struct TaskExecutor {
    struct Options: Sendable {
        var level: StrictLevel = .complete
        var buildTests = false
        var maxAttempts: Int = 2
        /// Run `swift test` as part of the verdict (once the build succeeds).
        var runTests = false
        /// Run tests under ThreadSanitizer; races fail the attempt.
        var tsan = false
    }

    let adapter: AgentAdapter
    let root: String
    let git: GitWorkingCopy
    let whitelist: PathWhitelist
    let journalPath: String
    let workDirectory: String
    let options: Options
    /// Optional target attribution for cross-target regression labels.
    var mapper: HybridTargetMapper? = nil

    /// Executes tasks in the given order, updating the journal in place and
    /// writing prompts/transcripts/logs under the work directory.
    /// `log` receives human-readable progress lines.
    func execute(
        taskIDs: [String],
        journal: inout Journal,
        log: (String) -> Void
    ) throws -> [TaskExecutionReport] {
        try git.requireRepository()
        guard try git.isClean(allowing: whitelist) else {
            log("Working tree has uncommitted changes outside the harness whitelist — commit or stash them first.")
            log("The revert boundary only works from a clean tree.")
            return []
        }

        var reports: [TaskExecutionReport] = []
        // Diagnostics of the tree as last measured: computed lazily once per
        // run and chained across passed tasks (failed attempts restore the
        // exact pre-state, so the cache stays valid).
        var preDiagnostics: [ConcurrencyDiagnostic]?
        // Kotlin source snapshot for boundary routing, rebuilt after each
        // measurement — routing every attempt against fresh tree walks would
        // re-read the whole repository each time.
        var kotlinIndex: KotlinSourceIndex?

        for id in taskIDs {
            guard let index = journal.tasks.firstIndex(where: { $0.id == id }) else {
                log("Task \(id) not found — skipped.")
                continue
            }
            let task = journal.tasks[index]
            guard task.status == .queued || task.status == .assigned else {
                log("Task \(id) is \(task.status.rawValue) — only queued tasks execute.")
                continue
            }
            guard try git.isClean(allowing: whitelist) else {
                log("Tree became dirty mid-run at \(id) — stopping. Remaining tasks stay queued.")
                break
            }

            if preDiagnostics == nil {
                log("Measuring current state before dispatch …")
                let outcome = try measure()
                preDiagnostics = outcome.diagnostics
                kotlinIndex = KotlinSourceIndex(repoRoot: root)
                persist(lastBuildLog: outcome.rawLog)
            }

            log("── \(id) [\(task.target)] \(task.file) · \(task.symbols.joined(separator: ", "))")

            var attempts: [AttemptReport] = []
            var failureNote = ""
            var passed = false

            for attempt in 1...max(1, options.maxAttempts) {
                _ = journal.markAssigned(id: id)
                try JournalStore.save(journal, to: journalPath)

                // KMP boundary routing: non-Sendable types named by this task's
                // diagnostics may be declared in Kotlin — same deterministic
                // function widens the allowed edit scope.
                let allowedFiles: Set<String> = {
                    var files: Set<String> = [task.file]
                    for path in TaskRouter.kotlinFixTargets(
                        diagnostics: preDiagnostics!, task: task, repoRoot: root, index: kotlinIndex
                    ) {
                        files.insert(path)
                    }
                    return files
                }()

                var prompt = TaskPrompt.render(
                    task: task,
                    diagnostics: preDiagnostics!.filter { $0.file == task.file },
                    level: options.level,
                    kotlinFixTargets: allowedFiles.sorted().filter { $0 != task.file }
                )
                if attempt > 1 {
                    prompt +=
                        "\nPrevious attempt (\(attempt - 1)/\(options.maxAttempts)) failed: \(failureNote)\nDiagnose the isolation design before editing again.\n"
                }

                let promptPath = (workDirectory as NSString)
                    .appendingPathComponent("prompt-\(id)-a\(attempt).md")
                try prompt.write(toFile: promptPath, atomically: true, encoding: .utf8)

                let invocation = AgentInvocation(
                    prompt: prompt,
                    promptFilePath: promptPath,
                    workingDirectory: root,
                    taskID: id
                )
                log("   attempt \(attempt)/\(options.maxAttempts): dispatching \(adapter.name) …")
                let outcome = try adapter.run(invocation)
                let transcriptPath = (workDirectory as NSString)
                    .appendingPathComponent("transcript-\(id)-a\(attempt).log")
                try outcome.transcript.write(toFile: transcriptPath, atomically: true, encoding: .utf8)

                // Scope check: the agent may edit exactly the task's file, plus
                // any Kotlin file the boundary routing identified.
                let changed = (try git.changes()).filter { !whitelist.allows($0.path) }
                let violations = changed.map(\.path).filter { !allowedFiles.contains($0) }
                if !violations.isEmpty {
                    try git.discard(paths: changed.map(\.path))
                    failureNote =
                        "scope violation — edited outside the task: \(violations.joined(separator: ", "))"
                    attempts.append(
                        AttemptReport(
                            number: attempt, agentExitCode: outcome.exitCode,
                            scopeViolations: violations, note: failureNote
                        )
                    )
                    log("   \(failureNote); reverted.")
                    continue
                }
                if changed.isEmpty, !outcome.succeeded {
                    failureNote = "agent exited \(outcome.exitCode) without editing anything"
                    attempts.append(
                        AttemptReport(number: attempt, agentExitCode: outcome.exitCode, note: failureNote)
                    )
                    log("   \(failureNote).")
                    continue
                }

                log("   agent finished (exit \(outcome.exitCode)); measuring …")
                let post = try measure()
                persist(lastBuildLog: post.rawLog)
                let verdict = VerdictCalculator.verdict(
                    before: preDiagnostics!,
                    after: post.diagnostics,
                    task: task,
                    packageRoot: root,
                    fileTarget: mapper.map { targetMapper in { targetMapper.target(forFile: $0) } }
                )

                // Test / ThreadSanitizer stage — only when the whole package
                // builds; results alongside a broken build elsewhere are noise.
                var tests: TestRunOutcome?
                var attemptFailure: String?
                if verdict.passed, options.runTests || options.tsan {
                    if post.buildExitCode == 0 {
                        log("   running tests\(options.tsan ? " under ThreadSanitizer" : "") …")
                        let outcome = try TestRunner.run(packageRoot: root, tsan: options.tsan)
                        if outcome.passed {
                            tests = outcome
                        } else if outcome.tsanRaces > 0 {
                            attemptFailure = "ThreadSanitizer reported \(outcome.tsanRaces) race(s)"
                        } else {
                            attemptFailure = "test suite failed (\(outcome.summaryLabel))"
                        }
                    } else {
                        log("   tests skipped — the package still fails to build elsewhere")
                    }
                } else if !verdict.passed {
                    attemptFailure = verdict.taskClean
                        ? "new diagnostics appeared elsewhere: \(verdict.regressionsElsewhere.joined(separator: ", "))"
                        : "task diagnostics still present — fix was insufficient"
                }

                if let attemptFailure {
                    try git.discard(paths: changed.map(\.path))
                    failureNote = attemptFailure
                    attempts.append(
                        AttemptReport(
                            number: attempt, agentExitCode: outcome.exitCode,
                            verdict: verdict, note: failureNote
                        )
                    )
                    log("   \(failureNote); reverted.")
                    continue
                }

                // Commit exactly what the agent changed within the allowed
                // scope (task file + routed Kotlin files) — one task, one
                // commit, possibly spanning the language boundary.
                let commitPaths = changed.map(\.path).filter { allowedFiles.contains($0) }
                var commitHash: String?
                if !commitPaths.isEmpty {
                    commitHash = try git.commit(
                        paths: commitPaths,
                        message: "strictmigrate(\(id)): \(task.target) \(task.file) \(task.symbols.joined(separator: ","))"
                    )
                }
                attempts.append(
                    AttemptReport(
                        number: attempt, agentExitCode: outcome.exitCode,
                        verdict: verdict, note: "passed"
                    )
                )
                journal.applyMeasurement(at: Date(), level: options.level, results: post.perTarget)
                _ = journal.reconcileTasks(
                    against: post.diagnostics, packageRoot: root, buildExitCode: post.buildExitCode
                )
                if let commitHash {
                    _ = journal.recordCommit(
                        taskID: id, commit: commitHash, attempts: attempt,
                        notes: attempts.map(\.note).filter { $0 != "passed" },
                        tests: tests?.summaryLabel,
                        tsan: options.tsan && post.buildExitCode == 0
                            ? (tests?.tsanRaces == 0 ? "clean" : "dirty") : nil
                    )
                }
                try JournalStore.save(journal, to: journalPath)
                preDiagnostics = post.diagnostics
                kotlinIndex = KotlinSourceIndex(repoRoot: root)
                if let commitHash {
                    log("   passed — committed \(commitHash) (\(commitPaths.count) file\(commitPaths.count == 1 ? "" : "s")), journal updated.")
                } else {
                    log("   passed without edits — symbols were already clean; journal updated.")
                }
                reports.append(
                    TaskExecutionReport(taskID: id, attempts: attempts, finalStatus: .passed, commit: commitHash)
                )
                passed = true
                break
            }

            if !passed {
                _ = journal.markReverted(id: id, attempts: attempts.count, notes: attempts.map(\.note))
                try JournalStore.save(journal, to: journalPath)
                log("   \(id) → reverted after \(attempts.count) attempt(s).")
                reports.append(
                    TaskExecutionReport(taskID: id, attempts: attempts, finalStatus: .reverted, commit: nil)
                )
            }
        }

        return reports
    }

    // MARK: - Plumbing

    private func measure() throws -> MeasureOutcome {
        try MeasureRunner.measureSwiftPackage(
            root: root,
            options: SPMBuilder.Options(
                level: options.level,
                buildTests: options.buildTests,
                extraArguments: [],
                scratchPath: nil
            )
        )
    }

    private func persist(lastBuildLog raw: String) {
        let path = (workDirectory as NSString).appendingPathComponent("last-build.log")
        try? raw.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
