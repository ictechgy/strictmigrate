import Foundation

enum PathUtils {
    /// Turns an absolute path into a path relative to `directory`, when the
    /// file lives under it. Symlinked roots (`/tmp` → `/private/tmp`) are
    /// resolved on both sides so paths from the compiler and from the shell
    /// agree. Anything outside the directory is returned unchanged.
    static func relativize(_ path: String, against directory: String?) -> String {
        guard let directory, !directory.isEmpty else { return path }

        let candidates = [directory, resolved(directory)].map(Self.withTrailingSlash)
        let paths = [path, resolved(path)]

        for candidate in candidates {
            for variant in paths where variant.hasPrefix(candidate) {
                return String(variant.dropFirst(candidate.count))
            }
        }
        return path
    }

    static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func withTrailingSlash(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }
}
