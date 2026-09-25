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

    /// Unsent attachments belong to this conversation, including when its view
    /// is closed or another conversation becomes visible.
    public var draftAttachments: [AgentAttachment] = []

    public var tools: [AnyAgentTool]
    public var skills: [Skill]
    public var mcpServers: [MCPServerSpec]
    public var context: AgentContext
    public var workingDirectory: URL
    public var permissions: any PermissionResolving
    public var permissionMode: PermissionMode
    public var planMode: Bool
    public var model: String?
    /// Reasoning effort for the next turn, as the active client's own spelling —
    /// the `id` of one of ``availableReasoningLevels``. `nil` leaves the agent
    /// on its own default.
    ///
    /// Reset when the active client changes: the levels are per-provider, and
    /// handing Codex an `xhigh` it has never heard of fails the turn.
    public var effort: String?

    /// When non-nil, the only tool names any client may call this thread.
    /// See ``AgentSendRequest/allowedTools``.
    public var allowedTools: [String]?
    /// Tool names withheld unconditionally.
    public var disallowedTools: [String] = []
    /// Tool-call rounds an in-process client may run in one turn.
    public var maxToolIterations: Int = 20

    /// Thread-scoped values every tool invocation can read.
    @ObservationIgnored public var state = AgentStateValues()

    /// Share the transcript when a client joins or returns after another client.
    /// A resumed native session does not contain the intervening clients' turns.
    public var sendsHandoffSummary: Bool = true

    /// When to fold older turns into the thread's rolling summary.
    ///
    /// Only in-process clients replay history, so only they feel this — a CLI
    /// client resuming its own native session keeps a transcript we do not own,
    /// and compacting ours would simply desync the two. ``compactIfNeeded()``
    /// therefore skips a thread the active client is resuming.
    public var autoCompact: AutoCompact?

    public struct AutoCompact: Sendable, Equatable {
        /// Compact once the replayable transcript exceeds this many messages.
        public var afterMessages: Int
        /// Messages left verbatim after a compaction.
        public var keepingLast: Int

        public init(afterMessages: Int = 20, keepingLast: Int = 6) {
            self.afterMessages = afterMessages
            self.keepingLast = keepingLast
        }
    }

    /// Produces the rolling summary. Given the existing summary and the
    /// transcript being folded in, returns the replacement.
    ///
    /// Injected because summarizing is a model call and `Agent` should not
    /// assume which model — a thread running on a CLI still wants its history
    /// compressed by something cheaper than spawning a subprocess. Returning
    /// `nil` (or leaving this unset) falls back to truncation.
    @ObservationIgnored
    public var summarizer: (@Sendable (_ existing: String, _ transcript: String) async -> String?)?

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
    /// What the active client will accept for ``effort``, ascending. Empty when
    /// it has no reasoning dial — UI should offer no picker at all then.
    public private(set) var availableReasoningLevels: [AgentReasoningOption] = []

    @ObservationIgnored private var currentTurn: Task<Void, Never>?
    @ObservationIgnored private var currentTurnID: UUID?
    /// The previous turn's client-side teardown, still in flight after a stop.
    ///
    /// ``stop()`` flips the phase to idle at once so the UI answers, but the
    /// child process it interrupted can take seconds to die. The next turn
    /// waits on this before it starts, so two turns never run against the same
    /// session — and never edit the same files — at once.
    @ObservationIgnored private var teardown: Task<Void, Never>?
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
        effort = nil
        Task { await refreshClientOptions() }
    }

    public func refreshAvailableModels() async {
        availableModels = await activeClient.availableModels()
    }

    public func refreshAvailableReasoningLevels() async {
        availableReasoningLevels = await activeClient.availableReasoningLevels()
        // A level the new client does not offer would be rejected on send.
        if let effort, !availableReasoningLevels.contains(where: { $0.id == effort }) {
            self.effort = nil
        }
    }

    /// Both per-client option lists, for a view that has just appeared.
    public func refreshClientOptions() async {
        await refreshAvailableModels()
        await refreshAvailableReasoningLevels()
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

    /// Turns typed while one was streaming, sent in order once it finishes.
    ///
    /// Dropping a message the user has already typed and sent is never the right
    /// answer, and blocking the field while the agent works makes the wait feel
    /// longer than it is. So a send during a turn queues.
    public private(set) var queuedTurns: [QueuedTurn] = []

    public struct QueuedTurn: Sendable, Identifiable, Equatable {
        public let id: UUID
        public var text: String
        public var attachments: [AgentAttachment]

        public init(id: UUID = UUID(), text: String, attachments: [AgentAttachment] = []) {
            self.id = id
            self.text = text
            self.attachments = attachments
        }
    }

    public func removeQueuedTurn(id: UUID) {
        queuedTurns.removeAll { $0.id == id }
    }

    /// Collapses every queued turn into one. Useful when a user typed three
    /// clarifications in a row and wants them answered together rather than
    /// as three separate turns.
    public func mergeQueuedTurns() {
        guard queuedTurns.count > 1 else { return }
        let merged = QueuedTurn(
            text: queuedTurns.map(\.text).joined(separator: "\n\n"),
            attachments: queuedTurns.flatMap(\.attachments)
        )
        queuedTurns = [merged]
    }

    public func clearQueuedTurns() {
        queuedTurns.removeAll()
    }

    /// Delivers a queued turn now instead of after the running turn finishes.
    ///
    /// Clients that can steer (Claude Code, Codex) get it as extra input to the
    /// turn in progress, so the agent keeps its work and simply reads the new
    /// message. Clients that can't are interrupted and the message starts as a
    /// fresh turn; the rest of the queue survives either way.
    public func sendQueuedTurnNow(id: UUID) {
        guard let index = queuedTurns.firstIndex(where: { $0.id == id }) else { return }
        let turn = queuedTurns.remove(at: index)
        guard phase.isBusy, let turnID = currentTurnID else {
            send(turn.text, attachments: turn.attachments)
            return
        }
        let client = activeClient
        Task { [weak self] in
            let steered = await client.steer(
                turn: turnID,
                prompt: turn.text,
                attachments: turn.attachments
            )
            guard let self else { return }
            if steered {
                self.thread.appendUserMessage(turn.text, attachments: turn.attachments)
                return
            }
            if self.currentTurnID == turnID { self.interruptCurrentTurn() }
            if self.phase.isBusy {
                // A drained turn started while we were asking; this one is
                // still the most urgent, so it goes first in line.
                self.queuedTurns.insert(turn, at: 0)
            } else {
                self.send(turn.text, attachments: turn.attachments)
            }
        }
    }

    /// Starts the next queued turn, if the thread is free and one is waiting.
    private func drainQueue() {
        guard !phase.isBusy, lastError == nil, !queuedTurns.isEmpty else { return }
        let next = queuedTurns.removeFirst()
        send(next.text, attachments: next.attachments)
    }

    public func send(_ text: String, attachments: [AgentAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        guard !phase.isBusy else {
            queuedTurns.append(QueuedTurn(text: trimmed, attachments: attachments))
            return
        }

        let client = activeClient
        let turnID = UUID()
        currentTurnID = turnID
        lastError = nil
        phase = .streaming(turnID: turnID)

        // History is captured *before* the new turn joins the transcript: an
        // in-process client replays `history` and then sends `prompt`, so a
        // prompt that appears in both would reach the model twice.
        let history = thread.replayableHistory()
        let request = buildRequest(
            turnID: turnID,
            prompt: trimmed,
            attachments: attachments,
            client: client,
            history: history
        )
        // Build handoff context before appending, so the new prompt appears once.
        thread.appendUserMessage(trimmed, attachments: attachments)

        let previousTeardown = teardown
        currentTurn = Task { [weak self] in
            await previousTeardown?.value
            if !Task.isCancelled {
                for await event in client.send(request) {
                    guard let self, !Task.isCancelled else { break }
                    self.handle(event, from: client.id)
                }
            }
            // A stopped turn has already been handed off: by the time it gets
            // here a newer turn may own the phase and the handles, and clearing
            // them would leave that turn running with nothing left to stop it.
            guard let self, !Task.isCancelled, self.currentTurnID == turnID else { return }
            if case .streaming(let active) = self.phase, active == turnID {
                self.phase = .idle
            }
            self.currentTurn = nil
            self.currentTurnID = nil
            await self.compactIfNeeded()
            self.drainQueue()
        }
    }

    // MARK: Compaction

    /// Folds older turns into ``AgentThread/summary`` if ``autoCompact`` says so.
    public func compactIfNeeded() async {
        guard let policy = autoCompact else { return }
        // The active client holds its own history server-side; ours is not what
        // it replays, so shrinking ours buys nothing and desyncs the two.
        guard !thread.hasRun(client: activeClientID) else { return }
        guard thread.replayableHistory().count > policy.afterMessages else { return }
        await compact(keepingLast: policy.keepingLast)
    }

    /// Compacts now, using ``summarizer`` when one is set.
    public func compact(keepingLast keep: Int = 6) async {
        let summarize = summarizer
        await thread.compact(keepingLast: keep) { existing, transcript in
            await summarize?(existing, transcript)
        }
    }

    public func stop() {
        // Stop means stop: a queue drained after a cancel would restart the very
        // work the user just interrupted.
        queuedTurns.removeAll()
        interruptCurrentTurn()
    }

    /// Cancels the running turn without touching the queue.
    private func interruptCurrentTurn() {
        guard let turnID = currentTurnID else { return }
        let client = activeClient
        currentTurn?.cancel()
        currentTurn = nil
        currentTurnID = nil
        phase = .idle
        let previous = teardown
        teardown = Task {
            await previous?.value
            await client.cancel(turn: turnID)
        }
    }

    /// Release long-lived child processes. `deinit` can't be async, so an
    /// explicit call is required — ACP agents keep a process alive per thread.
    public func shutdown() async {
        stop()
        await teardown?.value
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
        client: any AgentClient,
        history: [AgentMessage]
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
            permissions: permissions,
            localTools: effectiveTools,
            toolContext: AgentToolContext(
                threadID: thread.id,
                workingDirectory: workingDirectory,
                state: state
            ),
            history: history,
            allowedTools: allowedTools,
            disallowedTools: disallowedTools,
            maxToolIterations: maxToolIterations
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

        // Compacted turns are gone from `history`, so without this the model
        // simply loses everything that happened before the compaction point.
        if !thread.summary.isEmpty {
            parts.append("""
            ## Earlier in this conversation
            \(thread.summary)
            """)
        }

        if sendsHandoffSummary, needsHandoffSummary(for: client) {
            let summary = thread.handoffSummary()
            if !summary.isEmpty {
                parts.append("""
                ## Conversation so far
                This thread may include work by other agents. Use this recent conversation to catch up before continuing.

                \(summary)
                """)
            }
        }

        return parts.joined(separator: "\n\n")
    }

    /// Also catch returning clients up. After a reload, an unknown last client
    /// conservatively gets the transcript once; native session ids stay intact.
    private func needsHandoffSummary(for client: any AgentClient) -> Bool {
        !thread.messages.isEmpty
            && (!thread.hasRun(client: client.id) || thread.lastClientID != client.id)
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
