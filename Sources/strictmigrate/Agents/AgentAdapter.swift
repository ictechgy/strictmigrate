import Foundation

/// One dispatch of a task prompt to an agent.
struct AgentInvocation: Sendable {
    var prompt: String
    /// Absolute path of a file containing the prompt (long prompts survive
    /// shell quoting better; adapters choose which form to use).
    var promptFilePath: String
    var workingDirectory: String
    var taskID: String
}

/// What came back from an agent run — exit code plus everything it printed.
struct AgentRunOutcome: Sendable {
    var exitCode: Int32
    var transcript: String

    var succeeded: Bool { exitCode == 0 }
}

/// The vendor seam. strictmigrate's loop (prompt → measure → verdict →
/// journal → commit/revert) is shared code; adapters only decide how to spawn
/// a process that edits files. Anything that can run non-interactively and
/// edit files fits — claude-code today, codex/ACP in v0.4, one-liner shell
/// scripts in tests.
protocol AgentAdapter: Sendable {
    var name: String { get }
    func run(_ invocation: AgentInvocation) throws -> AgentRunOutcome
}

/// claude-code, non-interactive: `claude --print` with the prompt on stdin
/// (`--permission-mode acceptEdits --max-turns <n>`). The prompt stays off
/// argv — argv is world-readable via `ps` on shared machines and caps at
/// ARG_MAX. The adapter never grants broader permissions than file edits —
/// running builds is the executor's job, not the agent's.
struct ClaudeCodeAdapter: AgentAdapter {
    var name: String { "claude-code" }
    var maxTurns: Int = 24
    /// Extra arguments appended verbatim (repeatable `--claude-arg`).
    var extraArguments: [String] = []

    func run(_ invocation: AgentInvocation) throws -> AgentRunOutcome {
        let arguments = [
            "--print",
            "--permission-mode", "acceptEdits",
            "--max-turns", String(maxTurns),
        ] + extraArguments

        let result = try Shell.run(
            "claude",
            arguments: arguments,
            currentDirectory: invocation.workingDirectory,
            stdin: Data(invocation.prompt.utf8)
        )
        return AgentRunOutcome(exitCode: result.exitCode, transcript: result.combinedText)
    }
}

/// Generic escape hatch: run any command via `/bin/sh -c` with the package
/// root as cwd, `STRICTMIGRATE_PROMPT_FILE` in the environment, and
/// `cat "$STRICTMIGRATE_PROMPT_FILE"`-style composition up to the caller.
/// This keeps v0.3 usable with any vendor CLI without waiting for a
/// dedicated adapter.
struct CommandAdapter: AgentAdapter {
    var name: String { "command" }
    var commandLine: String

    func run(_ invocation: AgentInvocation) throws -> AgentRunOutcome {
        let result = try Shell.run(
            "/bin/sh",
            arguments: ["-c", commandLine],
            currentDirectory: invocation.workingDirectory,
            environment: ["STRICTMIGRATE_PROMPT_FILE": invocation.promptFilePath]
        )
        return AgentRunOutcome(exitCode: result.exitCode, transcript: result.combinedText)
    }
}

/// OpenAI Codex CLI, non-interactive: `codex exec -s workspace-write -`
/// (workspace-write sandbox; `exec` never prompts; `-` reads the prompt from
/// stdin, keeping it off argv). As with claude-code, the agent edits;
/// building and judging stay with the executor.
struct CodexAdapter: AgentAdapter {
    var name: String { "codex" }
    /// Extra arguments appended verbatim (repeatable `--codex-arg`).
    var extraArguments: [String] = []

    func run(_ invocation: AgentInvocation) throws -> AgentRunOutcome {
        let result = try Shell.run(
            "codex",
            arguments: Self.arguments(extraArguments: extraArguments),
            currentDirectory: invocation.workingDirectory,
            stdin: Data(invocation.prompt.utf8)
        )
        return AgentRunOutcome(exitCode: result.exitCode, transcript: result.combinedText)
    }

    static func arguments(extraArguments: [String]) -> [String] {
        ["exec", "-s", "workspace-write", "--color", "never", "-"] + extraArguments
    }
}

enum AgentAdapterFactory {
    enum FactoryError: Error, CustomStringConvertible {
        case unknownAdapter(String)
        case missingCommand

        var description: String {
            switch self {
            case .unknownAdapter(let name):
                return "unknown adapter `\(name)` — expected `claude`, `codex`, `acp`, or `command`"
            case .missingCommand:
                return "this adapter requires a --adapter-command '<shell command>' (or --acp-command)"
            }
        }
    }

    static func make(
        kind: String,
        commandLine: String?,
        claudeArguments: [String] = [],
        codexArguments: [String] = [],
        acpCommand: String? = nil
    ) throws -> AgentAdapter {
        switch kind {
        case "claude":
            return ClaudeCodeAdapter(extraArguments: claudeArguments)
        case "codex":
            return CodexAdapter(extraArguments: codexArguments)
        case "acp":
            guard let acpCommand, !acpCommand.isEmpty else { throw FactoryError.missingCommand }
            return ACPAdapter(commandLine: acpCommand)
        case "command":
            guard let commandLine, !commandLine.isEmpty else { throw FactoryError.missingCommand }
            return CommandAdapter(commandLine: commandLine)
        default:
            throw FactoryError.unknownAdapter(kind)
        }
    }
}
