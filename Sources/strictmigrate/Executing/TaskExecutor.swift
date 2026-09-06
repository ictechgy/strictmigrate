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
        packageRoot: String
    ) -> AttemptVerdict {
        let taskKeys = Set(task.symbols.map { SymbolKey(file: task.file, symbol: $0) })
        let beforeCounts = symbolCounts(before, packageRoot: packageRoot)
        let afterCounts = symbolCounts(after, packageRoot: packageRoot)

        let taskClean = taskKeys.isDisjoint(with: Set(afterCounts.keys))
        var regressions: [String] = []
        for (key, afterCount) in afterCounts where !taskKeys.contains(key) {
            let beforeCount = beforeCounts[key] ?? 0
            if afterCount > beforeCount {
                regressions.append("\(key.file) [\(key.symbol)] +\(afterCount - beforeCount)")
            }
        }

        return AttemptVerdict(taskClean: taskClean, regressionsElsewhere: regressions.sorted())
    }

    private static func symbolCounts(
        _ diagnostics: [ConcurrencyDiagnostic],
        packageRoot: String
    ) -> [SymbolKey: Int] {
        var cache: [String: [SymbolRange]] = [:]
        var counts: [SymbolKey: Int] = [:]
        for diagnostic in diagnostics where diagnostic.category.isTracked {
            if cache[diagnostic.file] == nil {
                let absolute = (packageRoot as NSString).appendingPathComponent(diagnostic.file)
                cache[diagnostic.file] = (try? String(contentsOfFile: absolute, encoding: .utf8))
                    .map { SymbolLocator.symbols(in: $0) } ?? []
            }
            let symbol = SymbolLocator.symbolName(for: diagnostic, symbols: cache[diagnostic.file] ?? [])
            counts[SymbolKey(file: diagnostic.file, symbol: symbol), default: 0] += 1
        }
        return counts
    }
}

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
    }

    let adapter: AgentAdapter
    let root: String
    let git: GitWorkingCopy
    let whitelist: PathWhitelist
    let journalPath: String
    let workDirectory: String
    let options: Options

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
                persist(lastBuildLog: outcome.rawLog)
            }

            log("── \(id) [\(task.target)] \(task.file) · \(task.symbols.joined(separator: ", "))")

            var attempts: [AttemptReport] = []
            var failureNote = ""
            var passed = false

            for attempt in 1...max(1, options.maxAttempts) {
                _ = journal.markAssigned(id: id)
                try JournalStore.save(journal, to: journalPath)

                var prompt = TaskPrompt.render(
                    task: task,
                    diagnostics: preDiagnostics!.filter { $0.file == task.file },
                    level: options.level
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

                // Scope check: the agent may edit exactly the task's file.
                let changed = (try git.changes()).filter { !whitelist.allows($0.path) }
                let violations = changed.map(\.path).filter { $0 != task.file }
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
                    packageRoot: root
                )

                if verdict.passed {
                    let commit = try git.commit(
                        paths: [task.file],
                        message: "strictmigrate(\(id)): \(task.target) \(task.file) \(task.symbols.joined(separator: ","))"
                    )
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
                    _ = journal.recordCommit(
                        taskID: id, commit: commit, attempts: attempt,
                        notes: attempts.map(\.note).filter { $0 != "passed" }
                    )
                    try JournalStore.save(journal, to: journalPath)
                    preDiagnostics = post.diagnostics
                    log("   passed — committed \(commit), journal updated.")
                    reports.append(
                        TaskExecutionReport(taskID: id, attempts: attempts, finalStatus: .passed, commit: commit)
                    )
                    passed = true
                    break
                }

                try git.discard(paths: changed.map(\.path))
                failureNote = verdict.taskClean
                    ? "new diagnostics appeared elsewhere: \(verdict.regressionsElsewhere.joined(separator: ", "))"
                    : "task diagnostics still present — fix was insufficient"
                attempts.append(
                    AttemptReport(
                        number: attempt, agentExitCode: outcome.exitCode,
                        verdict: verdict, note: failureNote
                    )
                )
                log("   \(failureNote); reverted.")
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
