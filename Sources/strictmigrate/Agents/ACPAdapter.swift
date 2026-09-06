import Foundation

/// Agent Client Protocol adapter (the protocol Xcode 27 speaks to agents).
///
/// Spawns an ACP agent behind a shell command and drives one turn over
/// newline-delimited JSON-RPC 2.0 on stdio:
/// `initialize` → `notifications/initialized` → `session/new` →
/// `session/prompt`, collecting `session/update` agent-message chunks as the
/// transcript until the prompt result arrives.
///
/// The connection is strictly sequential (one outstanding request at a time),
/// which keeps the client small — dispatching migration tasks never needs
/// concurrent prompts.
final class ACPConnection: @unchecked Sendable {
    enum ACPError: Error, CustomStringConvertible {
        case timedOut(what: String)
        case rpcError(method: String, message: String)
        case malformedResponse(String)
        case closed(what: String)

        var description: String {
            switch self {
            case .timedOut(let what): return "ACP \(what) timed out"
            case .rpcError(let method, let message): return "ACP \(method) error: \(message)"
            case .malformedResponse(let what): return "ACP malformed response: \(what)"
            case .closed(let what): return "ACP connection closed during \(what)"
            }
        }
    }

    private let process: Process
    private let stdinHandle: FileHandle
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var nextRequestID = 0
    private var response: [String: Any]?
    private var sawEOF = false
    private(set) var messageChunks: [String] = []
    private(set) var stderrText = ""

    init(commandLine: String, workingDirectory: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", commandLine]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed(command: commandLine, underlying: error)
        }
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting

        // Line-oriented stdout reader: complete JSON-RPC frames only.
        let assembler = LineAssembler()
        let connection = self
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let chunk = stdoutPipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                for line in assembler.append(chunk) {
                    connection.consume(line)
                }
            }
            connection.handleEOF()
        }
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = stderrPipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                connection.lock.lock()
                connection.stderrText += String(decoding: chunk, as: UTF8.self)
                connection.lock.unlock()
            }
        }
    }

    // MARK: - Public surface

    func initialize(timeout: TimeInterval = 30) throws {
        _ = try request(
            "initialize",
            params: [
                "protocolVersion": 1,
                "clientCapabilities": [
                    "fs": ["readTextFile": false, "writeTextFile": false],
                    "cwd": true,
                ],
            ],
            timeout: timeout
        )
        notify("notifications/initialized")
    }

    /// Returns the session id.
    func openSession(cwd: String, timeout: TimeInterval = 30) throws -> String {
        let result = try request("session/new", params: ["cwd": cwd, "mcpServers": []], timeout: timeout)
        guard let sessionID = result["sessionId"] as? String else {
            throw ACPError.malformedResponse("session/new without sessionId")
        }
        return sessionID
    }

    /// Sends one prompt and waits for the agent's stop reason. Message chunks
    /// streamed meanwhile accumulate in `messageChunks`.
    func prompt(sessionID: String, text: String, timeout: TimeInterval) throws -> String {
        let result = try request(
            "session/prompt",
            params: [
                "sessionId": sessionID,
                "prompt": [["type": "text", "text": text]],
            ],
            timeout: timeout
        )
        guard let stopReason = result["stopReason"] as? String else {
            throw ACPError.malformedResponse("session/prompt result without stopReason")
        }
        return stopReason
    }

    func shutdown() -> Int32 {
        // Closing stdin is the graceful path for most agents; force after a beat.
        try? stdinHandle.close()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - JSON-RPC plumbing

    private func request(_ method: String, params: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        lock.lock()
        nextRequestID += 1
        let id = nextRequestID
        response = nil
        lock.unlock()

        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let payload = (try! JSONSerialization.data(withJSONObject: message))
        stdinHandle.write(payload + Data("\n".utf8))

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw ACPError.timedOut(what: method) }

            switch signal.wait(timeout: .now() + remaining) {
            case .success:
                break
            case .timedOut:
                continue
            }

            lock.lock()
            let response = self.response
            let sawEOF = self.sawEOF
            self.response = nil
            lock.unlock()

            if let response {
                if let error = response["error"] as? [String: Any] {
                    throw ACPError.rpcError(
                        method: method, message: (error["message"] as? String) ?? "\(error)"
                    )
                }
                guard let result = response["result"] as? [String: Any] else {
                    throw ACPError.malformedResponse("\(method) result is not an object")
                }
                return result
            }
            if sawEOF {
                throw ACPError.closed(what: method)
            }
            // A notification woke us; keep waiting for the real response.
        }
    }

    private func notify(_ method: String) {
        let message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        let payload = (try! JSONSerialization.data(withJSONObject: message))
        stdinHandle.write(payload + Data("\n".utf8))
    }

    private func consume(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }

        lock.lock()
        // Only responses (they carry an id and no method); everything else we
        // care about is a session/update notification.
        if object["method"] == nil, object["id"] != nil {
            response = object
        } else if object["method"] as? String == "session/update",
                  let params = object["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any],
                  update["sessionUpdate"] as? String == "agent_message_chunk",
                  let content = update["content"] as? [String: Any],
                  let text = content["text"] as? String
        {
            messageChunks.append(text)
        }
        lock.unlock()
        signal.signal()
    }

    private func handleEOF() {
        lock.lock()
        sawEOF = true
        lock.unlock()
        signal.signal()
    }
}

/// Accumulates byte chunks and yields complete newline-terminated lines.
/// Single-reader by construction; the lock keeps the Sendable checker honest.
private final class LineAssembler: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) -> [String] {
        lock.lock()
        buffer.append(chunk)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        lock.unlock()
        return lines
    }
}

/// The ACP agent as an `AgentAdapter`: one dispatch = one ACP session turn.
struct ACPAdapter: AgentAdapter {
    var name: String { "acp" }
    var commandLine: String
    /// Wall-clock budget for one prompt (the agent edits files in between).
    var promptTimeout: TimeInterval = 15 * 60

    func run(_ invocation: AgentInvocation) throws -> AgentRunOutcome {
        let connection: ACPConnection
        do {
            connection = try ACPConnection(
                commandLine: commandLine, workingDirectory: invocation.workingDirectory
            )
        } catch {
            return AgentRunOutcome(exitCode: 1, transcript: "failed to launch: \(error)")
        }

        do {
            try connection.initialize()
            let sessionID = try connection.openSession(cwd: invocation.workingDirectory)
            let stopReason = try connection.prompt(sessionID: sessionID, text: invocation.prompt, timeout: promptTimeout)
            let exitCode = connection.shutdown()

            var transcript = connection.messageChunks.joined(separator: "")
            if transcript.isEmpty { transcript = connection.stderrText }
            transcript += "\n[acp stopReason=\(stopReason)]"
            return AgentRunOutcome(exitCode: exitCode, transcript: transcript)
        } catch {
            let exitCode = connection.shutdown()
            var transcript = connection.messageChunks.joined(separator: "")
            if !connection.stderrText.isEmpty { transcript += "\n" + connection.stderrText }
            transcript += "\n[acp error: \(error)]"
            return AgentRunOutcome(exitCode: exitCode == 0 ? 1 : exitCode, transcript: transcript)
        }
    }
}
