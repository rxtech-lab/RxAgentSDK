import Foundation
import Observation
import RxAgentCore

/// What the agent is doing right now.
public enum AgentPhase: Sendable, Equatable {
    case idle
    case streaming(turnID: UUID)
    case awaitingPermission(PermissionRequest)

    public var isBusy: Bool {
        if case .idle = self { return false }
        return true
    }
}

/// The SDK's front door.
///
/// ```swift
/// let agent = Agent(
///     clients: [ClaudeCodeClient(), CodexClient(), ACPClient(binaryFile: url)],
///     tools: [.tool(GrepTool())],
///     skills: [.codeReview],
///     mcpServers: []
/// )
/// ```
///
/// Multiple clients are *selectable*, not concurrent: one is active at a time,
/// and each client's own native session id is tracked on the thread so switching
/// mid-conversation resumes that client's session rather than handing it an id
/// minted by a different provider.
@MainActor @Observable
public final class Agent {

    // MARK: Configuration

    public private(set) var clients: [any AgentClient]
    public private(set) var activeClientID: AgentClientID

    public var tools: [AnyAgentTool]
    public var skills: [Skill]
    public var mcpServers: [MCPServerSpec]
    public var context: AgentContext
    public var workingDirectory: URL
    public var permissions: any PermissionResolving
    public var permissionMode: PermissionMode
    public var planMode: Bool
    public var model: String?
    public var effort: String?

    /// Prepend a summary of the transcript when a turn runs on a client that has
    /// not seen this thread before. Without it, switching providers mid-thread
    /// gives the new agent a prompt with no history at all.
    public var sendsHandoffSummary: Bool = true

    /// Called for every event, after the thread has folded it in.
    ///
    /// The transcript is already maintained for you; this is for hosts that want
    /// to observe the raw stream too — logging, analytics, or a debug inspector.
    @ObservationIgnored public var onEvent: (@MainActor (AgentEvent) -> Void)?

    // MARK: State

    public private(set) var thread: AgentThread
    public private(set) var phase: AgentPhase = .idle
    /// Set when the last turn failed, for surfacing in UI.
    public private(set) var lastError: AgentError?
    public private(set) var availableModels: [AgentModelOption] = []

    @ObservationIgnored private var currentTurn: Task<Void, Never>?
    @ObservationIgnored private var currentTurnID: UUID?
    /// Supplied by the host once a tool server is running. Nil means local tools
    /// are declared but not reachable.
    @ObservationIgnored public var toolServer: LocalToolServerHandle?

    public var activeClient: any AgentClient {
        clients.first { $0.id == activeClientID } ?? clients[0]
    }

    // MARK: Init

    public init(
        clients: [any AgentClient],
        tools: [AnyAgentTool] = [],
        skills: [Skill] = [],
        mcpServers: [MCPServerSpec] = [],
        context: AgentContext = AgentContext(),
        workingDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath),
        permissions: any PermissionResolving = AllowAllPermissions(),
        permissionMode: PermissionMode = .default,
        model: String? = nil
    ) {
        precondition(!clients.isEmpty, "Agent requires at least one client.")
        self.clients = clients
        self.activeClientID = clients[0].id
        self.tools = tools
        self.skills = skills
        self.mcpServers = mcpServers
        self.context = context
        self.workingDirectory = workingDirectory
        self.permissions = permissions
        self.permissionMode = permissionMode
        self.planMode = false
        self.model = model
        self.thread = AgentThread()
    }

    // MARK: Client selection

    public func select(_ clientID: AgentClientID) {
        guard clients.contains(where: { $0.id == clientID }) else { return }
        activeClientID = clientID
        model = nil
        Task { await refreshAvailableModels() }
    }

    public func refreshAvailableModels() async {
        availableModels = await activeClient.availableModels()
    }

    // MARK: Threads

    public func newThread() {
        stop()
        thread = AgentThread()
        lastError = nil
    }

    public func resume(_ thread: AgentThread) {
        stop()
        self.thread = thread
        lastError = nil
    }

    // MARK: Sending

    public func send(_ text: String, attachments: [AgentAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !phase.isBusy else { return }

        let client = activeClient
        let turnID = UUID()
        currentTurnID = turnID
        lastError = nil
        phase = .streaming(turnID: turnID)
        thread.appendUserMessage(trimmed, attachments: attachments)

        let request = buildRequest(turnID: turnID, prompt: trimmed, attachments: attachments, client: client)

        currentTurn = Task { [weak self] in
            for await event in client.send(request) {
                guard let self, !Task.isCancelled else { break }
                self.handle(event, from: client.id)
            }
            guard let self else { return }
            if case .streaming(let active) = self.phase, active == turnID {
                self.phase = .idle
            }
            self.currentTurn = nil
            self.currentTurnID = nil
        }
    }

    public func stop() {
        guard let turnID = currentTurnID else { return }
        let client = activeClient
        currentTurn?.cancel()
        currentTurn = nil
        currentTurnID = nil
        phase = .idle
        Task { await client.cancel(turn: turnID) }
    }

    /// Release long-lived child processes. `deinit` can't be async, so an
    /// explicit call is required — ACP agents keep a process alive per thread.
    public func shutdown() async {
        stop()
        for client in clients {
            await client.endSession(thread: thread.id)
        }
    }

    // MARK: Internals

    private func handle(_ event: AgentEvent, from clientID: AgentClientID) {
        if case .permissionRequested(let request) = event {
            phase = .awaitingPermission(request)
        }
        if case .failed(let error) = event {
            lastError = error
        }
        if case .turnEnded = event, case .awaitingPermission = phase {
            phase = .idle
        }
        thread.apply(event, from: clientID)
        onEvent?(event)
    }

    private func buildRequest(
        turnID: UUID,
        prompt: String,
        attachments: [AgentAttachment],
        client: any AgentClient
    ) -> AgentSendRequest {
        AgentSendRequest(
            turnID: turnID,
            threadID: thread.id,
            resumeSessionID: thread.resumeID(for: client.id),
            prompt: prompt,
            attachments: attachments,
            workingDirectory: workingDirectory,
            model: model,
            effort: effort,
            permissionMode: permissionMode,
            planMode: planMode,
            contextText: renderContextText(for: client),
            toolServer: toolServer,
            mcpServers: mcpServers,
            permissions: permissions
        )
    }

    /// Everything the agent should know before this turn: declared context,
    /// skills, and — on a provider handoff — a digest of what already happened.
    func renderContextText(for client: any AgentClient) -> String {
        var combined = context
        for skill in skills {
            combined.append(AgentContext(segments: [.skill(skill)]))
        }

        var parts: [String] = []
        let declared = combined.renderText()
        if !declared.isEmpty { parts.append(declared) }

        if sendsHandoffSummary, needsHandoffSummary(for: client) {
            let summary = thread.handoffSummary()
            if !summary.isEmpty {
                parts.append("""
                ## Conversation so far
                This conversation began with a different agent. Here is what happened before you joined.

                \(summary)
                """)
            }
        }

        return parts.joined(separator: "\n\n")
    }

    /// True when this client has never run in this thread but someone else has.
    private func needsHandoffSummary(for client: any AgentClient) -> Bool {
        !thread.hasRun(client: client.id) && !thread.messages.isEmpty
            && thread.nativeSessionIDs.isEmpty == false
    }

    /// Every tool that should be exposed on the local tool server this turn:
    /// directly declared tools, plus everything reachable through context and skills.
    public var effectiveTools: [AnyAgentTool] {
        var seen: Set<String> = []
        var result: [AnyAgentTool] = []
        for tool in tools + context.tools + skills.flatMap(\.tools)
        where seen.insert(tool.name).inserted {
            result.append(tool)
        }
        return result
    }
}
