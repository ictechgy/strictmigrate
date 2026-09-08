import Foundation

struct ShellResult: Sendable {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    /// stderr first: compilers write diagnostics there, so they lead the log.
    var combinedText: String { stderrText + "\n" + stdoutText }
}

enum ShellError: Error, CustomStringConvertible {
    case launchFailed(command: String, underlying: Error)

    var description: String {
        switch self {
        case .launchFailed(let command, let underlying):
            return "could not launch `\(command)`: \(underlying)"
        }
    }
}

/// Synchronous process runner. Reads stdout and stderr concurrently so large
/// compiler logs cannot deadlock on a full pipe. A non-zero exit is *not* an
/// error here — a failing build is the normal case during a migration.
enum Shell {
    /// - Parameter stdin: Optional payload written to the child's standard
    ///   input. Used to hand agent prompts to CLIs without putting them on
    ///   argv, where they would be visible to `ps` on shared machines.
    static func run(
        _ command: String,
        arguments: [String],
        currentDirectory: String? = nil,
        environment: [String: String]? = nil,
        stdin: Data? = nil
    ) throws -> ShellResult {
        let process = Process()
        if command.contains("/") {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + arguments
        }
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        }
        if let environment {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                merged[key] = value
            }
            process.environment = merged
        }

        var stdinPipe: Pipe?
        if stdin != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = DataBuffer()
        let stderrBuffer = DataBuffer()
        let group = DispatchGroup()

        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed(command: ([command] + arguments).joined(separator: " "), underlying: error)
        }

        drain(stdoutPipe.fileHandleForReading, into: stdoutBuffer, group: group)
        drain(stderrPipe.fileHandleForReading, into: stderrBuffer, group: group)

        // stdin write runs in parallel with the output drains: a child that
        // fills its stdout pipe before reading stdin, combined with a large
        // prompt, would otherwise deadlock both sides.
        if let stdinPipe, let stdin {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? stdinPipe.fileHandleForWriting.close()
            }
        }

        process.waitUntilExit()
        group.wait()

        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: stdoutBuffer.contents,
            stderr: stderrBuffer.contents
        )
    }

    private static func drain(_ handle: FileHandle, into buffer: DataBuffer, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
            }
        }
    }
}

/// Lock-guarded byte accumulator shared between the reader queues and the
/// caller. `@unchecked` because the lock, not the type system, serializes it.
private final class DataBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var contents: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
