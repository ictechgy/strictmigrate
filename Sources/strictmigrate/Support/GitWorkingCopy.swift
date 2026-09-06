import Foundation

/// One entry of `git status --porcelain`.
struct GitChange: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case modified
        case added
        case untracked
        case deleted
    }

    var kind: Kind
    /// Repository-relative path.
    var path: String
}

/// Git operations the executor needs for its revert boundaries.
/// Every path is repository-relative; every command runs in `root`.
struct GitWorkingCopy {
    var root: String

    enum GitError: Error, CustomStringConvertible {
        case notARepository(root: String)
        case gitFailed(command: String, exitCode: Int32, stderr: String)
        case commitFailed(String)

        var description: String {
            switch self {
            case .notARepository(let root):
                return "\(root) is not a git repository — execution requires git for commit/revert boundaries"
            case .gitFailed(let command, let exitCode, let stderr):
                return "`\(command)` failed (exit \(exitCode)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            case .commitFailed(let reason):
                return "commit failed: \(reason)"
            }
        }
    }

    /// Verifies git is available and `root` is inside a work tree.
    func requireRepository() throws {
        let result = try Shell.run("git", arguments: ["rev-parse", "--is-inside-work-tree"], currentDirectory: root)
        guard result.exitCode == 0, result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            throw GitError.notARepository(root: root)
        }
    }

    /// Uncommitted changes, parsed from `git status --porcelain`.
    func changes() throws -> [GitChange] {
        let result = try Shell.run(
            "git", arguments: ["status", "--porcelain", "--untracked-files=all"], currentDirectory: root
        )
        guard result.exitCode == 0 else {
            throw GitError.gitFailed(command: "git status", exitCode: result.exitCode, stderr: result.stderrText)
        }

        return result.stdoutText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in parseStatusLine(String(line)) }
    }

    /// True when the only uncommitted changes are under the whitelisted
    /// harness paths (journal, `.strictmigrate/`, build directories).
    func isClean(allowing whitelist: PathWhitelist) throws -> Bool {
        try changes().allSatisfy { whitelist.allows($0.path) }
    }

    /// Stages exactly `paths` (nothing else) and commits them.
    /// Returns the new commit's short hash.
    @discardableResult
    func commit(paths: [String], message: String) throws -> String {
        guard !paths.isEmpty else { throw GitError.commitFailed("nothing to commit") }
        for path in paths {
            let add = try Shell.run("git", arguments: ["add", "--", path], currentDirectory: root)
            guard add.exitCode == 0 else {
                throw GitError.gitFailed(command: "git add \(path)", exitCode: add.exitCode, stderr: add.stderrText)
            }
        }
        // Scope guard: refuse to commit if anything staged beyond `paths`.
        let staged = try Shell.run("git", arguments: ["diff", "--cached", "--name-only"], currentDirectory: root)
        guard staged.exitCode == 0 else {
            throw GitError.gitFailed(command: "git diff --cached", exitCode: staged.exitCode, stderr: staged.stderrText)
        }
        let stagedPaths = staged.stdoutText.split(separator: "\n").map(String.init)
        guard Set(stagedPaths) == Set(paths) else {
            throw GitError.commitFailed("staged files \(stagedPaths) do not match intended commit scope \(paths)")
        }

        let commit = try Shell.run("git", arguments: ["commit", "-m", message], currentDirectory: root)
        guard commit.exitCode == 0 else {
            throw GitError.gitFailed(command: "git commit", exitCode: commit.exitCode, stderr: commit.stderrText)
        }
        return try shortHEAD()
    }

    func shortHEAD() throws -> String {
        let result = try Shell.run("git", arguments: ["rev-parse", "--short", "HEAD"], currentDirectory: root)
        guard result.exitCode == 0 else {
            throw GitError.gitFailed(command: "git rev-parse", exitCode: result.exitCode, stderr: result.stderrText)
        }
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Restores `paths` to HEAD and removes untracked ones — the atomic
    /// revert boundary after a failed attempt.
    func discard(paths: [String]) throws {
        let tracked = paths.filter { path in
            let check = try? Shell.run(
                "git", arguments: ["ls-files", "--error-unmatch", "--", path], currentDirectory: root
            )
            return (check?.exitCode ?? 1) == 0
        }
        let untracked = paths.filter { !tracked.contains($0) }

        if !tracked.isEmpty {
            let restore = try Shell.run("git", arguments: ["checkout", "HEAD", "--"] + tracked, currentDirectory: root)
            guard restore.exitCode == 0 else {
                throw GitError.gitFailed(command: "git checkout", exitCode: restore.exitCode, stderr: restore.stderrText)
            }
        }
        for path in untracked {
            let absolute = (root as NSString).appendingPathComponent(path)
            try? FileManager.default.removeItem(atPath: absolute)
        }
    }

    /// `?? path` (untracked), `XY path` (index/worktree states), renames as
    /// the destination path only.
    private func parseStatusLine(_ line: String) -> GitChange? {
        guard line.count >= 4 else { return nil }
        let index = Array(line)[0]
        let worktree = Array(line)[1]
        var path = String(line.dropFirst(3))

        if let arrow = path.range(of: " -> ") {
            path = String(path[arrow.upperBound...])
        }
        path = path.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }

        let kind: GitChange.Kind
        switch (index, worktree) {
        case ("?", "?"): kind = .untracked
        case ("A", _), (_, "A"): kind = .added
        case ("D", _), (_, "D"): kind = .deleted
        default: kind = .modified
        }
        return GitChange(kind: kind, path: path)
    }
}

/// Paths that never count as scope violations and never block the
/// clean-tree precondition: the harness's own state, build directories, and
/// agent-harness session state (claude-code/.omc/codex drop bookkeeping
/// files into the working directory — that is not a code edit).
struct PathWhitelist: Sendable {
    var prefixes: [String]
    var exactPaths: Set<String>

    /// Journal path is passed relative to the repository root.
    init(journalPath: String) {
        self.prefixes = [
            ".strictmigrate/",
            ".build/",
            ".swiftpm/",
            ".claude/",
            ".codex/",
            ".omc/",
            ".cursor/",
        ]
        self.exactPaths = Set([journalPath])
    }

    func allows(_ path: String) -> Bool {
        exactPaths.contains(path) || prefixes.contains { path.hasPrefix($0) }
    }
}
