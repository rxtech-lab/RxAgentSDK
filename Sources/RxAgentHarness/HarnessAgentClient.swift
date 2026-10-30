import Foundation
import RxAgentCore
import RxAgentLLM

/// Runs the harness behind the SDK's ``AgentClient`` contract, so a host that
/// already drives Claude Code, Codex and ACP through `AgentClient` gets an
/// in-process agent with no new plumbing.
///
/// The mapping is lossy in one direction only: ``HarnessEvent`` carries tool
/// progress, permission traffic and compaction that ``AgentEvent`` has no case
/// for. Those surface as diagnostics; a host that wants them should consume
/// ``HarnessAgent/run(_:)`` directly.
public struct HarnessAgentClient: AgentClient {
    /// The model a turn should run on.
    public struct ResolvedModel: Sendable {
        public let model: any HarnessModel
        /// The name sent in the request body.
        public let name: String
        public init(model: any HarnessModel, name: String) {
            self.model = model
            self.name = name
        }
    }

    public typealias ModelResolver = @Sendable (_ requestedModel: String?) async throws -> ResolvedModel

    public let id: AgentClientID
    public let displayName: String
    public var provider: AgentProvider { .openAICompatible }
    public let capabilities: AgentCapabilities

    public let agent: HarnessAgent
    private let resolveModel: ModelResolver
    private let listModels: @Sendable () async -> [AgentModelOption]
    private let mode: HarnessGenerationMode

    public init(
        id: AgentClientID = "rx-harness",
        displayName: String = "RxCode Agent",
        agent: HarnessAgent,
        mode: HarnessGenerationMode = .streaming,
        capabilities: AgentCapabilities = [.todos, .fileEdit, .usageReporting, .attachments, .mcpServers, .modelSelection, .thinking, .askUserQuestion, .planMode],
        models: @escaping @Sendable () async -> [AgentModelOption] = { [] },
        resolveModel: @escaping ModelResolver
    ) {
        self.id = id
        self.displayName = displayName
        self.agent = agent
        self.mode = mode
        self.capabilities = capabilities
        self.listModels = models
        self.resolveModel = resolveModel
    }

    public func availableModels() async -> [AgentModelOption] { await listModels() }

    /// The session a request continues: the native id the thread recorded on
    /// an earlier turn, otherwise one derived from the thread itself.
    public static func sessionID(for request: AgentSendRequest) -> String {
        request.resumeSessionID ?? request.threadID.rawValue.uuidString
    }

    public func send(_ request: AgentSendRequest) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task {
                await run(request, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func cancel(turn: UUID) async {
        await TurnRegistry.shared.cancel(turn)
    }

    public func endSession(thread: AgentThreadID) async {
        await agent.release(sessionID: thread.rawValue.uuidString)
    }

    // MARK: - Turn

    private func run(_ request: AgentSendRequest, continuation: AsyncStream<AgentEvent>.Continuation) async {
        continuation.yield(.turnStarted(turnID: request.turnID))
        let sessionID = Self.sessionID(for: request)
        await TurnRegistry.shared.register(request.turnID, agent: agent, sessionID: sessionID)
        defer { Task { await TurnRegistry.shared.remove(request.turnID) } }

        let resolved: ResolvedModel
        do {
            resolved = try await resolveModel(request.model)
        } catch {
            continuation.yield(.failed(.agentReported(String(describing: error))))
            return
        }

        await seedIfNeeded(sessionID: sessionID, request: request)
        let (extraTools, diagnostics) = await hostTools(for: request)
        for diagnostic in diagnostics { continuation.yield(.diagnostic(diagnostic)) }

        let permissionMode: PermissionMode = request.planMode ? .plan : request.permissionMode
        let input = HarnessTurnInput(
            sessionID: sessionID,
            prompt: request.prompt,
            images: request.attachments.compactMap(\.harnessImage),
            workingDirectory: request.workingDirectory,
            model: resolved.model,
            modelName: resolved.name,
            mode: mode,
            permissionMode: permissionMode,
            permissionHandler: ResolverHarnessPermissionHandler(
                resolver: request.permissions, mode: permissionMode,
                threadID: request.threadID, clientID: id
            ),
            questionHandler: ResolverQuestionHandler(resolver: request.permissions, mode: permissionMode, threadID: request.threadID),
            instructions: Self.instructions(for: request),
            extraTools: extraTools,
            allowedTools: request.allowedTools.map { Set($0.map(MCPToolName.bare)) },
            disallowedTools: Set(request.disallowedTools.map(MCPToolName.bare))
        )

        var mapper = HarnessEventMapper(clientID: id)
        do {
            for try await event in await agent.run(input) {
                for mapped in mapper.map(event) { continuation.yield(mapped) }
            }
            for mapped in mapper.finish() { continuation.yield(mapped) }
        } catch HarnessError.cancelled {
            for mapped in mapper.finish() { continuation.yield(mapped) }
            continuation.yield(.failed(.cancelled))
        } catch is CancellationError {
            continuation.yield(.failed(.cancelled))
        } catch {
            for mapped in mapper.finish() { continuation.yield(mapped) }
            continuation.yield(.failed(.agentReported(String(describing: error))))
        }
    }

    /// File attachments become paths in the prompt — the model reads them with
    /// its own tools — and text attachments are inlined.
    static func instructions(for request: AgentSendRequest) -> String {
        var parts = [request.contextText]
        let files = request.attachments.compactMap { attachment -> String? in
            if case .file(let url) = attachment.kind { return url.path }
            return nil
        }
        if !files.isEmpty {
            parts.append("The user attached these files to their message; read them if relevant:\n" + files.map { "- \($0)" }.joined(separator: "\n"))
        }
        for attachment in request.attachments {
            if case .text(let text) = attachment.kind {
                parts.append("Attached text\(attachment.label.map { " (\($0))" } ?? ""):\n\(text)")
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// A thread that ran on another client first arrives with its transcript in
    /// `history`; replaying its prose gives the harness the conversation.
    private func seedIfNeeded(sessionID: String, request: AgentSendRequest) async {
        guard !request.history.isEmpty else { return }
        let store = await agent.configuration.store
        guard (try? await store.load(id: sessionID)) == nil else { return }
        let messages: [HarnessMessage] = request.history.compactMap { message in
            let text = message.plainText
            guard !text.isEmpty else { return nil }
            switch message.role {
            case .user: return .user(text)
            case .assistant: return .assistant(text)
            case .system: return nil
            }
        }
        try? await store.save(HarnessSession(id: sessionID, workingDirectory: request.workingDirectory.path, messages: messages))
    }

    /// Swift tools plus every tool advertised by the turn's HTTP MCP servers.
    private func hostTools(for request: AgentSendRequest) async -> ([any HarnessTool], [AgentDiagnostic]) {
        var tools: [any HarnessTool] = request.localTools.map { AgentToolAdapter($0, threadID: request.threadID) }
        guard !request.mcpServers.isEmpty else { return (tools, []) }
        let remoteOnly = AgentSendRequest(
            turnID: request.turnID, threadID: request.threadID, prompt: request.prompt,
            workingDirectory: request.workingDirectory, mcpServers: request.mcpServers,
            allowedTools: request.allowedTools, disallowedTools: request.disallowedTools
        )
        let surface = AgentToolSurface(request: remoteOnly)
        let diagnostics = await surface.discover()
        for entry in await surface.entries() {
            tools.append(MCPSurfaceTool(entry: entry, surface: surface))
        }
        return (tools, diagnostics)
    }
}

/// A tool from a remote MCP server, dispatched through ``AgentToolSurface``.
struct MCPSurfaceTool: HarnessTool {
    let entry: AgentToolSurface.Entry
    let surface: AgentToolSurface

    var name: String { entry.name }
    var description: String { entry.description }
    var parameters: JSONValue { entry.inputSchema }

    func execute(_ input: JSONValue, context: HarnessToolContext) async throws -> HarnessToolOutput {
        try await context.authorize(
            HarnessPermissionKey.mcp, resources: [entry.name], toolName: entry.name,
            input: input, title: "Run \(entry.name)"
        )
        let outcome = await surface.call(name: entry.name, arguments: input)
        let images = outcome.images.compactMap(HarnessImage.init(dataURL:))
        return HarnessToolOutput(text: outcome.text, isError: outcome.isError, images: images)
    }
}

// MARK: - Event mapping

/// ``HarnessEvent`` → ``AgentEvent``. Tracks open blocks so the SDK's
/// structural events stay balanced.
struct HarnessEventMapper {
    let clientID: AgentClientID
    private var messageOpen = false
    private var textOpen = false
    private var thinkingOpen = false
    private var sessionID: String?
    private var latestUsage: UsageInfo?

    init(clientID: AgentClientID) {
        self.clientID = clientID
    }

    mutating func map(_ event: HarnessEvent) -> [AgentEvent] {
        switch event {
        case .sessionLoaded(let info):
            sessionID = info.id
            return [.sessionStarted(SessionStarted(nativeSessionID: info.id, model: info.model))]
        case .stepStarted:
            var events = closeMessage()
            events.append(.messageStarted(role: .assistant, id: nil))
            messageOpen = true
            return events
        case .textDelta(let text):
            var events: [AgentEvent] = []
            if thinkingOpen { events.append(.blockEnded(.thinking)); thinkingOpen = false }
            if !textOpen { events.append(.blockStarted(.text)); textOpen = true }
            events.append(.textDelta(text))
            return events
        case .reasoningDelta(let text):
            var events: [AgentEvent] = []
            if !thinkingOpen { events.append(.blockStarted(.thinking)); thinkingOpen = true }
            events.append(.thinkingDelta(text))
            return events
        case .messageCompleted:
            return closeBlocks()
        case .toolCallStarted(let id, let name):
            return [.blockStarted(.toolUse(id: id, name: name)), .toolCallStarted(id: id, name: name)]
        case .toolCallInput(let id, let input):
            return [.toolCallInput(id: id, input: input.objectValue ?? [:])]
        case .toolCallCompleted(let id, let name, let output):
            return [.toolCallResult(id: id, content: output.text, isError: output.isError), .blockEnded(.toolUse(id: id, name: name))]
        case .toolProgress:
            return []
        case .permissionAsked, .permissionReplied:
            return []
        case .todos(let todos):
            return [.todos(todos)]
        case .usage(let usage):
            // Estimates are for live counters; `AgentEvent.usage` is metered,
            // so only the server's numbers go through.
            guard !usage.isEstimate else { return [] }
            latestUsage = usage.turn
            return [.usage(usage.turn)]
        case .contextWindow(let window):
            return [.contextWindow(window)]
        case .compactionStarted(let reason):
            return [.diagnostic(AgentDiagnostic(level: .info, client: clientID, message: "Compacting context (\(reason.rawValue))…"))]
        case .compactionFinished(let reason, let pruned, let summarized):
            return [.diagnostic(AgentDiagnostic(
                level: .info, client: clientID,
                message: "Compacted context (\(reason.rawValue)): pruned \(pruned) tool outputs\(summarized ? ", summarized earlier turns" : "")."
            ))]
        case .turnFinished(let result):
            var events = closeMessage()
            events.append(.turnEnded(TurnResult(
                isError: false, durationMS: result.durationMS, usage: result.usage, nativeSessionID: result.sessionID
            )))
            return events
        case .failed(let message):
            return closeMessage() + [.failed(.agentReported(message))]
        }
    }

    mutating func finish() -> [AgentEvent] { closeMessage() }

    private mutating func closeBlocks() -> [AgentEvent] {
        var events: [AgentEvent] = []
        if thinkingOpen { events.append(.blockEnded(.thinking)); thinkingOpen = false }
        if textOpen { events.append(.blockEnded(.text)); textOpen = false }
        return events
    }

    private mutating func closeMessage() -> [AgentEvent] {
        var events = closeBlocks()
        if messageOpen {
            events.append(.messageEnded(id: nil, usage: nil))
            messageOpen = false
        }
        return events
    }
}

// MARK: - Cancellation registry

/// Maps turn ids to the session they run, so `cancel(turn:)` — which only
/// gets a turn id — can reach the right agent.
actor TurnRegistry {
    static let shared = TurnRegistry()
    private var turns: [UUID: (agent: HarnessAgent, sessionID: String)] = [:]

    func register(_ turn: UUID, agent: HarnessAgent, sessionID: String) {
        turns[turn] = (agent, sessionID)
    }

    func remove(_ turn: UUID) { turns.removeValue(forKey: turn) }

    func cancel(_ turn: UUID) async {
        guard let entry = turns[turn] else { return }
        await entry.agent.cancel(sessionID: entry.sessionID)
    }
}

// MARK: - Helpers

extension AgentAttachment {
    var harnessImage: HarnessImage? {
        if case .image(let data, let mimeType) = kind { return HarnessImage(mimeType: mimeType, data: data) }
        return nil
    }
}

extension HarnessImage {
    init?(dataURL: String) {
        guard dataURL.hasPrefix("data:"), let comma = dataURL.firstIndex(of: ",") else { return nil }
        let header = dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma]
        guard let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        self.init(mimeType: String(header.split(separator: ";").first ?? "image/png"), data: data)
    }
}
