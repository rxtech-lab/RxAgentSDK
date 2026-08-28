import Foundation
import FoundationModels
import Observation
import RxAgentSDK

// MARK: - A demo tool

@Generable
struct WordCountArgs {
    @Guide(description: "Absolute path of the file to count words in")
    var path: String
}

/// A plain FoundationModels tool. The SDK erases it, publishes its schema over
/// a local MCP server, and the CLI agent calls it like any other tool.
struct WordCountTool: FoundationModels.Tool {
    let name = "word_count"
    let description = "Count the words and lines in a file on disk."

    func call(arguments: WordCountArgs) async throws -> String {
        let contents = try String(contentsOfFile: arguments.path, encoding: .utf8)
        let words = contents.split(whereSeparator: \.isWhitespace).count
        let lines = contents.components(separatedBy: .newlines).count
        return "\(arguments.path): \(words) words, \(lines) lines"
    }
}

@Generable
struct NoteArgs {
    @Guide(description: "The note to record")
    var text: String
}

/// Shows a tool reaching back into app state.
struct RecordNoteTool: FoundationModels.Tool {
    let name = "record_note"
    let description = "Record a note in the host app's sidebar."

    let sink: NoteSink

    func call(arguments: NoteArgs) async throws -> String {
        await sink.append(arguments.text)
        return "Recorded."
    }
}

actor NoteSink {
    private(set) var notes: [String] = []
    private var onChange: (@Sendable ([String]) -> Void)?

    func setOnChange(_ handler: @escaping @Sendable ([String]) -> Void) {
        onChange = handler
    }

    func append(_ note: String) {
        notes.append(note)
        onChange?(notes)
    }
}

// MARK: - Testbed state

@MainActor @Observable
final class AgentTestbedModel {
    let agent: Agent
    let permissions = InteractivePermissionCoordinator()
    let noteSink = NoteSink()

    /// Every event the active client emitted this session — invaluable when
    /// working on a decoder.
    private(set) var eventLog: [String] = []
    private(set) var pastSessions: [CLISessionSummary] = []

    /// Runs against scripted events instead of a real CLI. Enabled by launching
    /// with `-RXAgentPreviewClient YES`, which is how the UI tests drive the app
    /// deterministically — and how you can try the SDK with nothing installed.
    static var usesPreviewClient: Bool {
        UserDefaults.standard.bool(forKey: "RXAgentPreviewClient")
    }

    init() {
        let workingDirectory = URL(filePath: FileManager.default.currentDirectoryPath)
        let sink = noteSink

        let clients: [any AgentClient] = Self.usesPreviewClient
            ? [
                PreviewAgentClient(
                    id: "preview-answer", displayName: "Preview", script: .simpleAnswer
                ),
                PreviewAgentClient(
                    id: "preview-tools", displayName: "Preview (tools)", script: .toolUse
                ),
            ]
            : [ClaudeCodeClient(), CodexClient()]

        agent = Agent(
            clients: clients,
            tools: [
                .tool(WordCountTool()),
                .tool(RecordNoteTool(sink: sink)),
            ],
            skills: [
                Skill(
                    name: "Careful edits",
                    description: "Use whenever modifying files in this workspace."
                ) {
                    "Prefer the smallest possible diff. Explain each change in one sentence."
                }
            ],
            mcpServers: [],
            context: AgentContext {
                "You are running inside the RxAgentSDK example app."
                "The `word_count` and `record_note` tools are provided by the host app."
            },
            workingDirectory: workingDirectory,
            permissions: ReadOnlyAutoApprovePermissions(fallback: permissions)
        )

        agent.onEvent = { [weak self] event in
            self?.log(event)
        }

        Task { await startToolServer() }
        Task { await refreshSessions() }
    }

    // MARK: Working directory

    func setWorkingDirectory(_ url: URL) {
        agent.workingDirectory = url
        agent.newThread()
        Task {
            await startToolServer()
            await refreshSessions()
        }
    }

    // MARK: Tool server

    /// Publish the agent's Swift tools so the CLI can reach them over MCP.
    private func startToolServer() async {
        let tools = agent.effectiveTools
        let handle = try? await LocalToolServer.shared.publish(
            tools: tools,
            for: agent.thread.id,
            context: AgentToolContext(
                threadID: agent.thread.id,
                workingDirectory: agent.workingDirectory
            )
        )
        agent.toolServer = handle
    }

    // MARK: History

    func refreshSessions() async {
        pastSessions = await CLISessionStore.shared.summaries(for: agent.workingDirectory)
    }

    func resume(_ summary: CLISessionSummary) async {
        let messages = await CLISessionStore.shared.load(file: summary.fileURL)
        let thread = AgentThread()
        thread.load(messages: messages, nativeSessionIDs: [.claudeCode: summary.id])
        agent.resume(thread)
        await startToolServer()
    }

    // MARK: Event log

    func log(_ event: AgentEvent) {
        eventLog.append(Self.describe(event))
        if eventLog.count > 500 { eventLog.removeFirst(eventLog.count - 500) }
    }

    func clearLog() { eventLog.removeAll() }

    /// One compact line per event, so the log stays scannable while streaming.
    static func describe(_ event: AgentEvent) -> String {
        switch event {
        case .sessionStarted(let started): "sessionStarted \(started.nativeSessionID)"
        case .turnStarted: "turnStarted"
        case .messageStarted(let role, _): "messageStarted \(role.rawValue)"
        case .blockStarted(let ref): "blockStarted \(ref)"
        case .textDelta(let text): "textDelta \(text.count)ch"
        case .thinkingDelta(let text): "thinkingDelta \(text.count)ch"
        case .toolCallStarted(_, let name): "toolCallStarted \(name)"
        case .toolCallInput(_, let input): "toolCallInput \(input.keys.sorted().joined(separator: ","))"
        case .toolCallResult(_, let content, let isError):
            "toolCallResult \(isError ? "error " : "")\(content.count)ch"
        case .blockEnded(let ref): "blockEnded \(ref)"
        case .messageEnded: "messageEnded"
        case .todos(let items): "todos \(items.count)"
        case .usage(let usage): "usage in=\(usage.inputTokens) out=\(usage.outputTokens)"
        case .contextWindow(let window): "contextWindow \(Int(window.fractionUsed * 100))%"
        case .rateLimit(let info): "rateLimit \(info.message)"
        case .modelsDiscovered(let models): "modelsDiscovered \(models.count)"
        case .permissionRequested(let request): "permissionRequested \(request.toolName)"
        case .backgroundTask(let task): "backgroundTask \(task.taskID) \(task.status.rawValue)"
        case .turnEnded(let result): "turnEnded\(result.isError ? " (error)" : "")"
        case .failed(let error): "failed \(error.description)"
        case .diagnostic(let diagnostic): "diagnostic \(diagnostic.message)"
        }
    }
}
