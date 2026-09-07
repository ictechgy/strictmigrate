import Foundation

enum PathUtils {
    /// Turns an absolute path into a path relative to `directory`, when the
    /// file lives under it. Symlinked roots (`/tmp` → `/private/tmp`) are
    /// resolved on both sides so paths from the compiler and from the shell
    /// agree. Anything outside the directory is returned unchanged.
    static func relativize(_ path: String, against directory: String?) -> String {
        guard let directory, !directory.isEmpty else { return path }
        return PathRelativizer(directory: directory).relativize(path)
    }

    static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}

/// Precomputed prefix candidates for relativizing many paths against one
/// directory. `PathUtils.resolved` walks symlinks — a filesystem call per
/// invocation — so log parsing must resolve the working directory once, not
/// once per diagnostic line.
struct PathRelativizer {
    private let candidates: [String]

    init(directory: String) {
        candidates = [directory, PathUtils.resolved(directory)]
            .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
    }

    /// Absolute `path` relative to the directory when it lives under it;
    /// unchanged otherwise. Falls back to a resolved match so a `/tmp` root
    /// agrees with `/private/tmp` compiler paths.
    func relativize(_ path: String) -> String {
        for candidate in candidates where path.hasPrefix(candidate) {
            return String(path.dropFirst(candidate.count))
        }
        let resolved = PathUtils.resolved(path)
        for candidate in candidates where resolved.hasPrefix(candidate) {
            return String(resolved.dropFirst(candidate.count))
        }
        return path
    }
}
