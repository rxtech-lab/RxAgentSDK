import Foundation
import RxAgentCore

/// opencode's `shell` tool, under the name models are trained on: `bash`.
public struct ShellTool: HarnessTool {
    public static let defaultTimeout: TimeInterval = 120

    public init() {}

    public let name = "bash"

    public var description: String {
        [
            "Execute a shell command and return its output.",
            "Commands run on macOS using zsh.",
            "Quote file paths containing spaces or special characters.",
            "Prefer dedicated tools (read, edit, glob, grep) over shell commands when possible.",
            "When output is large, the full result is saved to a file and a truncated preview is returned.",
            "Commands accept an optional timeout; background commands have no timeout.",
            "Set background to true for dev servers, watchers and long builds: the command returns immediately",
            "with a shell ID, and you will be notified when it finishes. Use bash_output to read its output",
            "and bash_kill to stop it. Do not poll for completion.",
        ].joined(separator: " ")
    }

    public var parameters: JSONValue {
        Schema.object([
            "command": Schema.string("Shell command string to execute"),
            "description": Schema.string("Clear, concise description of what this command does in 5-10 words"),
            "workdir": Schema.string(
                "Working directory to execute the command in. Defaults to the current working directory. "
                    + "Avoid `cd` in the command and set this instead."
            ),
            "timeout": Schema.integer("Timeout in milliseconds. 0 disables it. Defaults to 120000."),
            "background": Schema.boolean("Run in the background and return immediately."),
        ], required: ["command"])
    }

    public func execute(_ input: JSONValue, context: HarnessToolContext) async throws -> HarnessToolOutput {
        guard let command = input["command"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            throw HarnessToolError("`command` is required.")
        }
        let workdir = input["workdir"]?.stringValue.map(context.resolve) ?? context.workingDirectory
        let background = input["background"]?.boolValue ?? false
        let timeoutMS = input["timeout"]?.intValue
        let timeout: TimeInterval? = background
            ? nil
            : timeoutMS.map { $0 == 0 ? nil : TimeInterval($0) / 1000 } ?? Self.defaultTimeout

        if !HarnessPaths.isInside(workdir, root: context.workingDirectory) {
            try await context.authorize(
                HarnessPermissionKey.externalDirectory,
                resources: [workdir.path],
                always: [workdir.path + "/*"],
                toolName: name, input: input,
                title: "Run a command outside the project in \(workdir.path)"
            )
        }
        let parts = ShellCommandParser.commands(in: command)
        try await context.authorize(
            HarnessPermissionKey.bash,
            resources: parts.isEmpty ? [command] : parts,
            always: (parts.isEmpty ? [command] : parts).map(ShellCommandParser.alwaysPattern),
            toolName: name, input: input,
            title: input["description"]?.stringValue ?? command
        )

        let title = input["description"]?.stringValue ?? command
        if background {
            let shell = try await context.terminals.startBackground(command, workingDirectory: workdir)
            await context.emit(.backgroundShell(id: shell.id, command: command, started: true, exitCode: nil))
            return HarnessToolOutput(
                text: "Command moved to the background (shell ID: \(shell.id)).\nOutput is streaming to: \(shell.logPath)\n"
                    + "You will be notified when it finishes. Do not poll for completion.",
                title: title,
                metadata: ["shellID": .string(shell.id), "status": "running"]
            )
        }

        let result = try await context.terminals.run(command, workingDirectory: workdir, timeout: timeout) { text, stream in
            await context.emit(.output(text, stream: stream))
        }

        var text = result.output.isEmpty ? "(no output)" : result.output
        if let path = result.fullOutputPath {
            text += "\n\nThe output was truncated. The full output is saved at \(path); read or grep it if you need more."
        }
        if result.timedOut {
            text += "\n\nThe command timed out after \(Int(timeout ?? 0)) seconds and was terminated. "
                + "Run long commands with background: true."
        } else if result.cancelled {
            text += "\n\nThe command was cancelled."
        } else if let code = result.exitCode, code != 0 {
            text += "\n\nExit code: \(code)"
        }
        return HarnessToolOutput(
            text: text,
            isError: result.timedOut || result.cancelled,
            title: title,
            metadata: [
                "exit": result.exitCode.map { .number(Double($0)) } ?? .null,
                "truncated": .bool(result.fullOutputPath != nil),
            ]
        )
    }
}

/// Reads what a background shell has written since the last read.
public struct ShellOutputTool: HarnessTool {
    public init() {}
    public let name = "bash_output"
    public let description = "Read new output from a background shell started with bash(background: true). Returns only output written since the previous read, plus whether the command is still running."
    public var isReadOnly: Bool { true }
    public var parameters: JSONValue {
        Schema.object(["shell_id": Schema.string("The shell ID returned by bash")], required: ["shell_id"])
    }

    public func execute(_ input: JSONValue, context: HarnessToolContext) async throws -> HarnessToolOutput {
        guard let id = input["shell_id"]?.stringValue,
              let (shell, output) = await context.terminals.output(of: id) else {
            throw HarnessToolError("No background shell with that ID.")
        }
        let status = shell.exitCode.map { "finished with exit code \($0)" } ?? "still running"
        return HarnessToolOutput(
            text: "Shell \(id) is \(status).\n\n" + (output.isEmpty ? "(no new output)" : output),
            title: shell.command
        )
    }
}

/// Stops a background shell.
public struct ShellKillTool: HarnessTool {
    public init() {}
    public let name = "bash_kill"
    public let description = "Terminate a background shell started with bash(background: true)."
    public var parameters: JSONValue {
        Schema.object(["shell_id": Schema.string("The shell ID returned by bash")], required: ["shell_id"])
    }

    public func execute(_ input: JSONValue, context: HarnessToolContext) async throws -> HarnessToolOutput {
        guard let id = input["shell_id"]?.stringValue else { throw HarnessToolError("`shell_id` is required.") }
        return await context.terminals.kill(id)
            ? HarnessToolOutput(text: "Sent terminate to shell \(id).")
            : .error("Shell \(id) is not running.")
    }
}

// MARK: - Command parsing

/// Splits a shell command into the simple commands permission rules match.
///
/// Not a shell parser — it only has to find the boundaries a rule like
/// `rm *` must not be fooled by: `git status && rm -rf build` is two commands,
/// and `echo "a && b"` is one.
public enum ShellCommandParser {
    public static func commands(in command: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        let characters = Array(command)
        var index = 0
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(trimmed) }
            current = ""
        }
        while index < characters.count {
            let character = characters[index]
            defer { index += 1 }
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" && quote != "'" { escaped = true; current.append(character); continue }
            if let open = quote {
                if character == open { quote = nil }
                current.append(character)
                continue
            }
            if character == "'" || character == "\"" { quote = character; current.append(character); continue }
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if (character == "&" && next == "&") || (character == "|" && next == "|") {
                flush(); index += 1; continue
            }
            if character == ";" || character == "|" || character == "\n" || character == "&" {
                flush(); continue
            }
            current.append(character)
        }
        flush()
        return parts.map(stripEnvironmentAssignments)
    }

    /// `FOO=1 npm test` is governed by the rule for `npm`.
    static func stripEnvironmentAssignments(_ command: String) -> String {
        var tokens = command.split(separator: " ", omittingEmptySubsequences: true)
        while let first = tokens.first, first.contains("="), !first.hasPrefix("-"),
              first.first?.isLetter == true || first.first == "_" {
            tokens.removeFirst()
        }
        return tokens.isEmpty ? command : tokens.joined(separator: " ")
    }

    /// The pattern an "always allow" answer remembers: the program and, when
    /// it looks like a subcommand, its first argument — `git status *`,
    /// `npm run *`, `ls *`.
    public static func alwaysPattern(for command: String) -> String {
        let tokens = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let program = tokens.first else { return command }
        if tokens.count > 1, let second = tokens.dropFirst().first,
           !second.hasPrefix("-"), !second.contains("/"), !second.contains("."),
           second.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "_" }) {
            return "\(program) \(second) *"
        }
        return "\(program) *"
    }
}
