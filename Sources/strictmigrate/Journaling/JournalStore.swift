import Foundation
import Yams

/// Loads and saves the journal YAML. The file is meant to be committed, so
/// output is deterministic: sorted keys, block style, fixed header comment.
enum JournalStore {
    static let defaultFileName = "strictmigrate.yaml.journal"
    static let workDirectoryName = ".strictmigrate"

    private static let header = """
        # strictmigrate journal — single source of truth for this repository's
        # Swift 6 strict-concurrency migration. Commit this file.
        # Written by `strictmigrate measure`; safe to edit by hand.

        """

    enum StoreError: Error, CustomStringConvertible {
        case notFound(path: String)
        case alreadyExists(path: String)
        case unreadable(path: String, underlying: Error)

        var description: String {
            switch self {
            case .notFound(let path):
                return "no journal at \(path) — run `strictmigrate init` first"
            case .alreadyExists(let path):
                return "journal already exists at \(path)"
            case .unreadable(let path, let underlying):
                return "could not read journal at \(path): \(underlying)"
            }
        }
    }

    static func load(at path: String) throws -> Journal {
        guard FileManager.default.fileExists(atPath: path) else {
            throw StoreError.notFound(path: path)
        }
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            return try decode(text)
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.unreadable(path: path, underlying: error)
        }
    }

    static func save(_ journal: Journal, to path: String) throws {
        let yaml = try encode(journal)
        try (header + yaml).write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func create(at path: String) throws -> Journal {
        guard !FileManager.default.fileExists(atPath: path) else {
            throw StoreError.alreadyExists(path: path)
        }
        let journal = Journal()
        try save(journal, to: path)
        return journal
    }

    static func decode(_ text: String) throws -> Journal {
        try YAMLDecoder().decode(Journal.self, from: text)
    }

    static func encode(_ journal: Journal) throws -> String {
        let encoder = YAMLEncoder()
        encoder.options.sortKeys = true
        return try encoder.encode(journal)
    }

    /// Creates `.strictmigrate/` (raw build logs live here) with a
    /// self-ignoring `.gitignore`, so nothing but the journal reaches git.
    static func ensureWorkDirectory(in root: String) throws -> String {
        let directory = (root as NSString).appendingPathComponent(workDirectoryName)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let gitignore = (directory as NSString).appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: gitignore) {
            try "*\n".write(toFile: gitignore, atomically: true, encoding: .utf8)
        }
        return directory
    }
}
