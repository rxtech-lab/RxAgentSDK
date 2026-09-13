import Foundation
import RxAgentCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An agent that runs **in this process**, driving an OpenAI-compatible
/// `/chat/completions` endpoint through a tool-calling loop.
///
/// The CLI clients delegate the hard part — deciding what to call and when — to
/// an agent binary. There is no binary here, so this type is the agent: it
/// advertises the turn's tools, reads back `tool_calls`, dispatches them through
/// ``AgentToolSurface``, feeds the results in, and goes round again until the
/// model answers without asking for anything.
///
/// Two consequences follow from having no agent process, and both are visible in
/// the code below:
///
/// - **History is replayed, not resumed.** There is no server-side session to
///   hand a `resumeSessionID` to, so every turn re-sends the conversation from
///   ``AgentSendRequest/history``. That is also why compaction matters more here
///   than for a CLI client.
/// - **Nothing is sandboxed for us.** A CLI agent enforces its own tool
///   permissions; here the only gate is the turn's allow/deny list, which
///   ``AgentToolSurface`` applies on both discovery and dispatch.
///
/// Spawns nothing, so unlike the CLI clients it works on iOS.
public struct OpenAIChatClient: AgentClient {

    public struct Configuration: Sendable {
        /// Either a base URL (`https://api.openai.com/v1`) or a full
        /// completions URL. A base gets `/chat/completions` appended.
        public var endpoint: URL?
        /// Used when a turn does not name one.
        public var defaultModel: String?
        /// Extra top-level fields merged into the request body — where a
        /// gateway's own options go, e.g. `providerOptions`.
        public var extraBody: [String: JSONValue]
        /// The reasoning-effort levels this endpoint accepts, offered to the
        /// user by ``AgentClient/availableReasoningLevels()``. Empty — the
        /// default — means the endpoint has no such dial: plenty of
        /// OpenAI-compatible gateways front non-reasoning models, and a picker
        /// whose every option is rejected is worse than no picker.
        public var reasoningLevels: [AgentReasoningOption]
        /// Body field the chosen level is sent as. `reasoning_effort` is the
        /// OpenAI spelling; a gateway that nests it elsewhere needs its own key.
        public var reasoningEffortKey: String
        /// Resolved per request, so a bearer token can be refreshed between
        /// turns without rebuilding the client.
        public var headers: @Sendable () async -> [String: String]
        /// Server-Sent Events. On by default: it is what makes text appear as
        /// the model writes it rather than in one block at the end.
        ///
        /// Forced off when ``unaryTransport`` is set — a transport that returns
        /// `Data` has no deltas to deliver.
        public var streaming: Bool

        /// Replaces the built-in `URLSession` call with the host's own HTTP
        /// stack. Receives the encoded request body, returns the response body.
        ///
        /// This exists because "an OpenAI-compatible endpoint" is not always
        /// reachable as a plain URL plus headers. A metered gateway may sit
        /// behind the host's auth (with its own token refresh), want an
        /// idempotency key per call, and return billing information alongside
        /// the completion that only the host knows what to do with. Expressing
        /// that as configuration would mean re-implementing someone else's
        /// networking layer; handing them the bytes does not.
        public var unaryTransport: (@Sendable (Data) async throws -> Data)?
        /// Tool result text longer than this is truncated before going back to
        /// the model. Individual tools cap their own output, but a paginated
        /// list with a large limit can still crowd out the conversation.
        public var maxToolResultCharacters: Int
        public var timeout: TimeInterval

        public init(
            endpoint: URL? = nil,
            defaultModel: String? = nil,
            extraBody: [String: JSONValue] = [:],
            reasoningLevels: [AgentReasoningOption] = [],
            reasoningEffortKey: String = "reasoning_effort",
            streaming: Bool = true,
            maxToolResultCharacters: Int = 120_000,
            timeout: TimeInterval = 300,
            headers: @escaping @Sendable () async -> [String: String] = { [:] },
            unaryTransport: (@Sendable (Data) async throws -> Data)? = nil
        ) {
            self.endpoint = endpoint
            self.defaultModel = defaultModel
            self.extraBody = extraBody
            self.reasoningLevels = reasoningLevels
            self.reasoningEffortKey = reasoningEffortKey
            self.streaming = streaming && unaryTransport == nil
            self.maxToolResultCharacters = maxToolResultCharacters
            self.timeout = timeout
            self.headers = headers
            self.unaryTransport = unaryTransport
        }

        /// An endpoint reached entirely through the host's own HTTP stack.
        ///
        /// `endpoint` still has to be non-nil — it is what the client checks to
        /// decide it is configured at all — but it is never dialled.
        public static func hosted(
            model: String? = nil,
            extraBody: [String: JSONValue] = [:],
            reasoningLevels: [AgentReasoningOption] = [],
            send: @escaping @Sendable (Data) async throws -> Data
        ) -> Configuration {
            Configuration(
                endpoint: URL(string: "https://host.invalid/chat/completions"),
                defaultModel: model,
                extraBody: extraBody,
                reasoningLevels: reasoningLevels,
                streaming: false,
                unaryTransport: send
            )
        }

        /// A plain API-key endpoint.
        public static func apiKey(
            _ key: String,
            endpoint: URL,
            model: String? = nil,
            extraBody: [String: JSONValue] = [:],
            reasoningLevels: [AgentReasoningOption] = []
        ) -> Configuration {
            Configuration(
                endpoint: endpoint,
                defaultModel: model,
                extraBody: extraBody,
                reasoningLevels: reasoningLevels
            ) {
                ["Authorization": "Bearer \(key)"]
            }
        }
    }

    public let id: AgentClientID
    public let displayName: String
    public var provider: AgentProvider { .openAICompatible }
    public let capabilities: AgentCapabilities

    let configuration: Configuration
    private let runtime: InProcessTurnRuntime
    private let session: URLSession

    public init(
        id: AgentClientID = .openAICompatible,
        displayName: String = "OpenAI-compatible",
        configuration: Configuration,
        capabilities: AgentCapabilities = .openAICompatibleDefaults
    ) {
        self.id = id
        self.displayName = displayName
        self.configuration = configuration
        self.capabilities = capabilities
        self.runtime = InProcessTurnRuntime()

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeout
        sessionConfiguration.timeoutIntervalForResource = configuration.timeout
        self.session = URLSession(configuration: sessionConfiguration)
    }

    public func isAvailable() async -> Bool {
        configuration.endpoint != nil
    }

    public func availableReasoningLevels() async -> [AgentReasoningOption] {
        configuration.reasoningLevels
    }

    /// `extraBody` plus this turn's reasoning effort.
    ///
    /// An effort the endpoint was not configured to accept is dropped rather
    /// than forwarded: a stale selection left over from another client would
    /// otherwise fail the whole request on a body field this endpoint has never
    /// heard of.
    func requestBody(for request: AgentSendRequest) -> [String: JSONValue] {
        var body = configuration.extraBody
        if let effort = request.effort,
           configuration.reasoningLevels.contains(where: { $0.id == effort }) {
            body[configuration.reasoningEffortKey] = .string(effort)
        }
        return body
    }

    // MARK: - Turn

    public func send(_ request: AgentSendRequest) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task {
                await run(request, continuation: continuation)
                continuation.finish()
            }
            Task { await runtime.register(turnID: request.turnID, task: task) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: AgentSendRequest,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async {
        defer { Task { await runtime.remove(turnID: request.turnID) } }

        continuation.yield(.turnStarted(turnID: request.turnID))
        // There is no remote session, but the thread still wants a stable id for
        // this client so a later turn is recognizably the same conversation.
        continuation.yield(.sessionStarted(SessionStarted(
            nativeSessionID: request.threadID.rawValue.uuidString,
            model: request.model ?? configuration.defaultModel
        )))

        do {
            try await loop(request, continuation: continuation)
        } catch is CancellationError {
            continuation.yield(.failed(.cancelled))
        } catch let error as OpenAIChatError {
            continuation.yield(.failed(.agentReported(error.description)))
        } catch {
            continuation.yield(.failed(.agentReported(String(describing: error))))
        }
    }

    private func loop(
        _ request: AgentSendRequest,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async throws {
        guard let endpoint = configuration.endpoint else { throw OpenAIChatError.missingEndpoint }
        let model = (request.model ?? configuration.defaultModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let model, !model.isEmpty else { throw OpenAIChatError.missingModel }

        let surface = AgentToolSurface(request: request)
        for diagnostic in await surface.discover() {
            continuation.yield(.diagnostic(diagnostic))
        }
        let tools = await surface.entries()
        let url = Self.completionsURL(for: endpoint)
        let headers = await configuration.headers()
        let extraBody = requestBody(for: request)

        var messages = Self.seed(request)
        var totalUsage = UsageInfo()
        var didStartMessage = false

        for _ in 0 ..< max(1, request.maxToolIterations) {
            try Task.checkCancellation()

            if !didStartMessage {
                continuation.yield(.messageStarted(role: .assistant, id: nil))
                didStartMessage = true
            }

            // The delta callback runs on the URLSession's task, not here, so the
            // "have we opened a text block yet" flag has to be shared safely
            // rather than captured as a local `var`.
            let didOpenTextBlock = OneShotFlag()
            let turn = try await OpenAIChatTransport.send(
                messages: messages,
                tools: tools,
                endpoint: url,
                headers: headers,
                model: model,
                extraBody: extraBody,
                stream: configuration.streaming,
                session: session,
                unaryTransport: configuration.unaryTransport
            ) { fragment in
                if didOpenTextBlock.raise() {
                    continuation.yield(.blockStarted(.text))
                }
                continuation.yield(.textDelta(fragment))
            }

            if didOpenTextBlock.isRaised { continuation.yield(.blockEnded(.text)) }
            if let usage = turn.usage {
                totalUsage = Self.adding(usage, to: totalUsage)
                continuation.yield(.usage(totalUsage))
            }

            guard !turn.toolCalls.isEmpty else {
                continuation.yield(.messageEnded(id: nil, usage: turn.usage))
                continuation.yield(.turnEnded(TurnResult(
                    usage: totalUsage,
                    nativeSessionID: request.threadID.rawValue.uuidString
                )))
                return
            }

            messages.append(OpenAIMessage(
                role: "assistant",
                text: turn.text.isEmpty ? nil : turn.text,
                toolCalls: turn.toolCalls
            ))

            // Tool results for one assistant turn must form a contiguous block
            // immediately after it — Anthropic-backed gateways reject
            // interleaved roles. Image attachments are user-role, so they are
            // held back until every tool_result is in place.
            var imageFollowups: [OpenAIMessage] = []

            for call in turn.toolCalls {
                try Task.checkCancellation()

                continuation.yield(.toolCallStarted(id: call.id, name: call.name))
                let arguments = call.arguments
                if case .object(let fields) = arguments {
                    continuation.yield(.toolCallInput(id: call.id, input: fields))
                } else {
                    continuation.yield(.toolCallInput(id: call.id, input: [:]))
                }

                let outcome = await surface.call(name: call.name, arguments: arguments)
                var body = outcome.text
                if body.count > configuration.maxToolResultCharacters {
                    body = String(body.prefix(configuration.maxToolResultCharacters))
                        + "\n…(truncated)"
                }

                messages.append(OpenAIMessage(
                    role: "tool",
                    text: body,
                    toolCallID: call.id,
                    name: call.name
                ))

                // A tool_result cannot carry an image in the OpenAI shape, so an
                // image comes back as a separate user-role message. This is how
                // the model actually sees a rendered frame.
                if !outcome.images.isEmpty {
                    imageFollowups.append(OpenAIMessage(
                        role: "user",
                        parts: [.text("Result of \(call.name):")]
                            + outcome.images.map(OpenAIMessage.Part.imageURL)
                    ))
                }

                continuation.yield(.toolCallResult(
                    id: call.id,
                    content: outcome.text,
                    isError: outcome.isError
                ))
            }

            messages.append(contentsOf: imageFollowups)
        }

        throw OpenAIChatError.maxIterationsExceeded(request.maxToolIterations)
    }

    // MARK: - Conversation assembly

    /// The system prompt, the replayed transcript, and this turn's prompt.
    ///
    /// The system message is marked cacheable: it is the largest thing that does
    /// not change between iterations of the loop, so pinning a cache breakpoint
    /// there is what keeps a ten-round tool sequence from re-billing the whole
    /// prompt ten times.
    static func seed(_ request: AgentSendRequest) -> [OpenAIMessage] {
        var messages: [OpenAIMessage] = []

        if !request.contextText.isEmpty {
            messages.append(OpenAIMessage(
                role: "system",
                text: request.contextText,
                cacheControl: true
            ))
        }

        for message in request.history {
            switch message.role {
            case .user:
                let text = message.plainText
                if !text.isEmpty { messages.append(OpenAIMessage(role: "user", text: text)) }
            case .assistant:
                // Only the prose is replayed. A historical tool call would have
                // to be paired with its `tool` result message to be valid, and
                // re-sending settled tool traffic costs far more than the
                // summary of it that the text already contains.
                let text = message.plainText
                if !text.isEmpty { messages.append(OpenAIMessage(role: "assistant", text: text)) }
            case .system:
                let text = message.plainText
                if !text.isEmpty { messages.append(OpenAIMessage(role: "system", text: text)) }
            }
        }

        var parts: [OpenAIMessage.Part] = [.text(request.prompt)]
        for attachment in request.attachments {
            switch attachment.kind {
            case .image(let data, let mimeType):
                parts.append(.imageURL("data:\(mimeType);base64,\(data.base64EncodedString())"))
            case .text(let text):
                parts.append(.text(text))
            case .file(let url):
                parts.append(.text("Attached file: \(url.path)"))
            }
        }

        messages.append(
            parts.count == 1
                ? OpenAIMessage(role: "user", text: request.prompt, cacheControl: true)
                : OpenAIMessage(role: "user", parts: parts)
        )

        return messages
    }

    /// `endpoint` may be a base URL or the completions URL itself.
    static func completionsURL(for endpoint: URL) -> URL {
        let path = endpoint.path
        if path.hasSuffix("/chat/completions") || path.hasSuffix("/completions") {
            return endpoint
        }
        return endpoint.appending(path: "chat/completions")
    }

    static func adding(_ increment: UsageInfo, to total: UsageInfo) -> UsageInfo {
        UsageInfo(
            inputTokens: total.inputTokens + increment.inputTokens,
            outputTokens: total.outputTokens + increment.outputTokens,
            cacheReadTokens: total.cacheReadTokens + increment.cacheReadTokens,
            cacheCreationTokens: total.cacheCreationTokens + increment.cacheCreationTokens,
            totalCostUSD: (total.totalCostUSD ?? 0) + (increment.totalCostUSD ?? 0)
        )
    }

    // MARK: - Lifecycle

    public func cancel(turn: UUID) async {
        await runtime.cancel(turnID: turn)
    }

    public func endSession(thread: AgentThreadID) async {}
}

/// A latch that reports whether *this* call was the one that set it.
///
/// Not an actor: the streaming callback is synchronous and cannot await, which
/// is the whole reason this exists rather than a plain `var`.
final class OneShotFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    /// Sets the flag, returning true only for the first caller.
    func raise() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Per-client mutable state, kept off the `Sendable` struct.
actor InProcessTurnRuntime {
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func register(turnID: UUID, task: Task<Void, Never>) {
        tasks[turnID] = task
    }

    func remove(turnID: UUID) {
        tasks.removeValue(forKey: turnID)
    }

    func cancel(turnID: UUID) {
        tasks.removeValue(forKey: turnID)?.cancel()
    }
}
