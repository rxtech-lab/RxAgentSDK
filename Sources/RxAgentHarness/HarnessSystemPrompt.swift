import Foundation

/// Builds the system prompt the harness sends with every model call.
///
/// The base text is adapted from opencode's `system.txt`/`gpt.txt` prompts
/// (MIT licensed, https://github.com/anomalyco/opencode) with the harness name
/// substituted, followed by tool guidance written for smaller local models,
/// an environment block, and any project instruction files (`AGENTS.md`,
/// `CLAUDE.md`) found from the working directory upward — the same files
/// opencode loads.
public struct HarnessSystemPrompt: Sendable {
    /// Shown to the model as the harness it is running in.
    public var agentName: String
    /// Replaces the opencode-derived base prompt entirely when set.
    public var baseOverride: String?
    /// Host instructions appended after the base prompt (RxCode's context
    /// text, memories, IDE tool notes).
    public var additionalInstructions: String
    public var loadProjectInstructions: Bool
    public static let instructionFileNames = ["AGENTS.md", "CLAUDE.md", "CONTEXT.md"]

    public init(
        agentName: String = "RxCode",
        baseOverride: String? = nil,
        additionalInstructions: String = "",
        loadProjectInstructions: Bool = true
    ) {
        self.agentName = agentName
        self.baseOverride = baseOverride
        self.additionalInstructions = additionalInstructions
        self.loadProjectInstructions = loadProjectInstructions
    }

    public func render(
        workingDirectory: URL,
        toolNames: [String],
        model: String,
        planMode: Bool = false,
        summary: String? = nil,
        date: Date = Date()
    ) -> String {
        var sections: [String] = [baseOverride ?? Self.base(agentName: agentName)]
        sections.append(Self.toolGuidance(toolNames))
        if planMode {
            sections.append("""
            # Plan mode
            Plan mode is active. You may read, search and run read-only commands, but you must not edit files or run commands that change anything. Investigate, then present a concise, concrete plan and wait for the user to approve it.
            """)
        }
        sections.append(Self.environment(workingDirectory: workingDirectory, model: model, date: date))
        if loadProjectInstructions {
            let files = Self.projectInstructions(from: workingDirectory)
            if !files.isEmpty {
                sections.append("# Project instructions\n\n" + files.map { "Instructions from: \($0.path)\n\($0.text)" }.joined(separator: "\n\n"))
            }
        }
        let extra = additionalInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { sections.append(extra) }
        if let summary, !summary.isEmpty {
            sections.append("""
            # Conversation checkpoint
            Earlier parts of this conversation were summarized to save context. Continue the work from this checkpoint; the messages that follow happened after it.

            <conversation-checkpoint>
            \(summary)
            </conversation-checkpoint>
            """)
        }
        return sections.joined(separator: "\n\n")
    }

    static func base(agentName: String) -> String {
        """
        You are an AI agent running in \(agentName), a coding agent harness. Help the user accomplish their goals using the tools you have available.

        # Harness
        - Responses are rendered as GitHub-flavored Markdown.
        - `<system-reminder>` blocks are harness instructions, not user-authored content. Read and follow them.
        - Prefer parallelizing independent tool calls.

        # Communication
        - Use clear file paths when referring to files.
        - Keep responses clear and concise, and avoid unnecessary technical jargon.
        - In the final answer, lead with the outcome, not the steps you took to reach it.

        # Working in codebases
        - Keep changes consistent with the structure, naming, style, and patterns of the surrounding code.
        - Treat unfamiliar files or changes as potential user work and investigate before deleting or overwriting them.

        # Code comments
        By default, match the surrounding comment density: where the code has none, add none. Use comments sparingly, only where they are appropriate, such as for behavior that is not obvious from the code itself. Instructions from the user or the project take precedence over this guidance.

        # Destructive actions
        Do not revert, reset, or discard changes you did not make. Never run destructive commands such as `git reset --hard`, `git checkout --`, or recursive deletes on broad paths unless the user clearly asked for that operation; if the target or scope is unclear, ask first. Prefer non-interactive git commands.

        # Autonomy
        Do not infer authorization for work beyond the user's request. Assumptions that help you make progress are fine as long as they stay within the user's intent and the scope of the task.
        """
    }

    static func toolGuidance(_ names: [String]) -> String {
        let available = Set(names)
        var lines = ["# Tools", "- Call tools with valid JSON arguments that match each tool's schema exactly."]
        if available.contains("read") { lines.append("- Use `read` to view files and directories, and read a file before you edit it.") }
        if available.contains("glob") || available.contains("grep") {
            lines.append("- Use `glob` to find files by name and `grep` to search contents instead of shell `find`/`grep`.")
        }
        if available.contains("edit") { lines.append("- Use `edit` for targeted changes; `oldString` must match the file exactly, without read's line-number prefixes.") }
        if available.contains("patch") { lines.append("- Use `patch` to change several files at once.") }
        if available.contains("write") { lines.append("- Use `write` only to create new files or fully rewrite one.") }
        if available.contains("bash") {
            lines.append("- Use `bash` for builds, tests, git and other commands. Set `workdir` instead of using `cd`. Start servers and watchers with `background: true`.")
        }
        if available.contains("todowrite") { lines.append("- Track multi-step work with `todowrite`.") }
        if available.contains("question") { lines.append("- When a decision really needs the user, ask with `question` instead of guessing.") }
        lines.append("- When the task is done, stop calling tools and reply with a short summary.")
        return lines.joined(separator: "\n")
    }

    static func environment(workingDirectory: URL, model: String, date: Date) -> String {
        let isGit = FileManager.default.fileExists(atPath: workingDirectory.appending(path: ".git").path)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        #if os(macOS)
        let platform = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #else
        let platform = "iOS"
        #endif
        return """
        # Environment
        <env>
        Working directory: \(workingDirectory.path)
        Is directory a git repo: \(isGit ? "yes" : "no")
        Platform: \(platform)
        Model: \(model)
        Today's date: \(formatter.string(from: date))
        </env>
        """
    }

    /// Instruction files from `directory` up to the filesystem root (or the
    /// first git root), nearest last so it takes precedence when read.
    static func projectInstructions(from directory: URL) -> [(path: String, text: String)] {
        var found: [(path: String, text: String)] = []
        var current = directory.standardizedFileURL
        for _ in 0..<12 {
            for name in instructionFileNames {
                let url = current.appending(path: name)
                if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                    found.insert((url.path, String(text.prefix(20_000))), at: 0)
                    break
                }
            }
            if FileManager.default.fileExists(atPath: current.appending(path: ".git").path) { break }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return found
    }
}
