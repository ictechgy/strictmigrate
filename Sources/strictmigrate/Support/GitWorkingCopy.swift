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
            .flatMap { parseStatusLine(String($0)) }
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

    /// Restores `paths` to HEAD and removes the rest — the atomic revert
    /// boundary after a failed attempt. Membership is decided against HEAD,
    /// not the index: a file the agent created *and staged* is absent from
    /// HEAD, so `checkout HEAD` would fail — it must be unstaged and deleted
    /// instead.
    func discard(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        for path in paths {
            let inHEAD = (try? Shell.run(
                "git", arguments: ["cat-file", "-e", "HEAD:\(path)"], currentDirectory: root
            ))?.exitCode == 0

            if inHEAD {
                let restore = try Shell.run("git", arguments: ["checkout", "HEAD", "--", path], currentDirectory: root)
                guard restore.exitCode == 0 else {
                    throw GitError.gitFailed(command: "git checkout", exitCode: restore.exitCode, stderr: restore.stderrText)
                }
                continue
            }

            // Not in HEAD: staged-new or untracked. `git rm -f` unstages and
            // deletes in one step; a path that was never staged is removed
            // from the worktree directly.
            let remove = try? Shell.run(
                "git", arguments: ["rm", "-f", "-q", "--", path], currentDirectory: root
            )
            if remove?.exitCode != 0 {
                let absolute = (root as NSString).appendingPathComponent(path)
                try? FileManager.default.removeItem(atPath: absolute)
            }
        }
    }

    /// `?? path` (untracked), `XY path` (index/worktree states). Renames
    /// (`R  old -> new`) yield BOTH paths: the destination with the line's
    /// status and the source as a deletion — reverting a rename must restore
    /// the old path and drop the new one, so callers need both.
    private func parseStatusLine(_ line: String) -> [GitChange] {
        guard line.count >= 4 else { return [] }
        let index = Array(line)[0]
        let worktree = Array(line)[1]
        var rawPath = String(line.dropFirst(3))

        var renameSource: String?
        if let arrow = rawPath.range(of: " -> ") {
            renameSource = String(rawPath[rawPath.startIndex..<arrow.lowerBound])
            rawPath = String(rawPath[arrow.upperBound...])
        }

        var results: [GitChange] = []
        if let renameSource {
            let source = Self.unquoteGitPath(renameSource.trimmingCharacters(in: .whitespaces))
            if !source.isEmpty {
                results.append(GitChange(kind: .deleted, path: source))
            }
        }

        let path = Self.unquoteGitPath(rawPath.trimmingCharacters(in: .whitespaces))
        guard !path.isEmpty else { return results }

        let kind: GitChange.Kind
        switch (index, worktree) {
        case ("?", "?"): kind = .untracked
        case ("A", _), (_, "A"): kind = .added
        case ("D", _), (_, "D"): kind = .deleted
        default: kind = .modified
        }
        results.append(GitChange(kind: kind, path: path))
        return results
    }

    /// Unquotes a porcelain path. Git C-quotes paths containing non-ASCII
    /// bytes, quotes, or control characters (`"\354\225\234.swift"`) whenever
    /// `core.quotepath` is on — the default — so those paths arrive escaped
    /// and must be decoded before they can match repository files.
    static func unquoteGitPath(_ path: String) -> String {
        let bytes = Array(path.utf8)
        guard bytes.count >= 2,
              bytes.first == UInt8(ascii: "\""),
              bytes.last == UInt8(ascii: "\"")
        else { return path }

        let inner = bytes[1..<(bytes.count - 1)]
        var out = [UInt8]()
        out.reserveCapacity(inner.count)
        var index = inner.startIndex
        while index < inner.endIndex {
            let byte = inner[index]
            if byte != UInt8(ascii: "\\") {
                out.append(byte)
                index = inner.index(after: index)
                continue
            }
            let escapeIndex = inner.index(after: index)
            guard escapeIndex < inner.endIndex else {
                out.append(byte) // lone trailing backslash
                index = escapeIndex
                continue
            }
            switch inner[escapeIndex] {
            case UInt8(ascii: "n"):
                out.append(0x0A)
                index = inner.index(after: escapeIndex)
            case UInt8(ascii: "t"):
                out.append(0x09)
                index = inner.index(after: escapeIndex)
            case UInt8(ascii: "r"):
                out.append(0x0D)
                index = inner.index(after: escapeIndex)
            case UInt8(ascii: "\\"), UInt8(ascii: "\""):
                out.append(inner[escapeIndex])
                index = inner.index(after: escapeIndex)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                // Up to three octal digits: one UTF-8 byte, e.g. `\354\225\234` = 한.
                var value = 0
                var cursor = escapeIndex
                var digits = 0
                while digits < 3, cursor < inner.endIndex, let digit = Self.octalDigit(inner[cursor]) {
                    value = value * 8 + Int(digit)
                    digits += 1
                    cursor = inner.index(after: cursor)
                }
                out.append(UInt8(truncatingIfNeeded: value))
                index = cursor
            default:
                out.append(byte)
                index = escapeIndex
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func octalDigit(_ byte: UInt8) -> UInt8? {
        (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(byte) ? byte - UInt8(ascii: "0") : nil
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
            ".cursor/",
            ".gemini/",
            ".omc/",
            ".serena/",
        ]
        self.exactPaths = Set([journalPath])
    }

    func allows(_ path: String) -> Bool {
        exactPaths.contains(path) || prefixes.contains { path.hasPrefix($0) }
    }
}
