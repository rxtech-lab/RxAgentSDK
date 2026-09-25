import Foundation

// MARK: - MCP server specification

/// A user-supplied external MCP server. Each client renders this into its own
/// config dialect (Claude: `--mcp-config` JSON; Codex: `-c mcp_servers.…` TOML;
/// ACP: the `session/new` `mcpServers` array).
public struct MCPServerSpec: Sendable, Hashable, Identifiable, Codable {
    public enum Transport: Sendable, Hashable, Codable {
        case stdio(command: String, args: [String], env: [String: String])
        case http(url: URL, headers: [String: String])
        case sse(url: URL, headers: [String: String])
    }

    public let id: String
    public var name: String
    public var transport: Transport
    public var enabled: Bool

    public init(name: String, transport: Transport, enabled: Bool = true) {
        self.id = name
        self.name = name
        self.transport = transport
        self.enabled = enabled
    }

    public static func stdio(
        name: String,
        command: String,
        args: [String] = [],
        env: [String: String] = [:]
    ) -> MCPServerSpec {
        MCPServerSpec(name: name, transport: .stdio(command: command, args: args, env: env))
    }

    public static func http(
        name: String,
        url: URL,
        headers: [String: String] = [:]
    ) -> MCPServerSpec {
        MCPServerSpec(name: name, transport: .http(url: url, headers: headers))
    }
}

/// How a client reaches the SDK's in-process tool server.
///
/// The server is transport-agnostic; the handle carries both an HTTP endpoint
/// (preferred — no external interpreter involved) and an optional stdio bridge
/// command for agents that only support stdio MCP servers.
public struct LocalToolServerHandle: Sendable, Hashable {
    public let name: String
    public let httpURL: URL
    /// Command that pipes an agent's stdio to the server's socket. Present only
    /// when a stdio bridge is configured.
    public let stdioBridge: BridgeCommand?

    public struct BridgeCommand: Sendable, Hashable {
        public let command: String
        public let args: [String]
        public init(command: String, args: [String]) {
            self.command = command
            self.args = args
        }
    }

    public init(name: String, httpURL: URL, stdioBridge: BridgeCommand? = nil) {
        self.name = name
        self.httpURL = httpURL
        self.stdioBridge = stdioBridge
    }
}

// MARK: - Send request

/// The provider-agnostic turn envelope.
///
/// Contrast RxCode's `BackendSendRequest`, which was a superset carrying six
/// provider-tagged fields (`hookSettingsPath` Claude-only, `mcpCodexOverrides`
/// Codex-only, `acpSpec` ACP-only, …) and therefore leaked provider identity
/// into every call site. Here each client derives whatever it needs from
/// `toolServer` / `mcpServers` / `permissions`.
public struct AgentSendRequest: Sendable {
    public let turnID: UUID
    public let threadID: AgentThreadID
    /// This client's own native session id, or `nil` to start fresh.
    public let resumeSessionID: String?
    public let prompt: String
    public let attachments: [AgentAttachment]
    public let workingDirectory: URL
    public let model: String?
    /// Reasoning effort, as the *active client's* own spelling — the `id` of one
    /// of its ``AgentReasoningOption``s. `nil` leaves the agent on its default.
    ///
    /// Deliberately a string rather than an enum: the levels are not a shared
    /// vocabulary (Codex has `minimal`, Claude has `xhigh` and `max`), and a
    /// host-supplied provider must be able to name its own.
    public let effort: String?
    public let permissionMode: PermissionMode
    public let planMode: Bool
    /// Rendered once by `Agent`. Claude consumes it via `--append-system-prompt`;
    /// Codex and ACP prepend it to the prompt.
    public let contextText: String
    public let toolServer: LocalToolServerHandle?
    public let mcpServers: [MCPServerSpec]
    public let permissions: any PermissionResolving

    /// The host's Swift tools, invocable without any transport.
    ///
    /// The same tools `toolServer` publishes over MCP — a CLI client reaches
    /// them through that socket because it is a different process, while an
    /// in-process client calls these closures. Both lists are present on every
    /// request and each client uses the one it can.
    public let localTools: [AnyAgentTool]

    /// Where a local tool should consider itself to be running.
    public let toolContext: AgentToolContext

    /// The transcript preceding `prompt`, excluding the prompt itself.
    ///
    /// A CLI client ignores this — the agent process keeps its own history and
    /// resumes it by `resumeSessionID`. An **in-process** client has no such
    /// server-side session, so replaying the conversation is the only way it can
    /// have one; this is where it gets the turns to replay. Already filtered by
    /// `Agent` to drop anything the thread has compacted away, so a client can
    /// send the whole array without reasoning about budgets.
    public let history: [AgentMessage]

    /// When non-nil, the *only* tool names this turn may call. `nil` means no
    /// allowlist — every tool the agent discovers is fair game.
    ///
    /// Separate from `permissions` because the two answer different questions:
    /// the resolver decides whether a call the agent *made* goes through, this
    /// decides whether the agent is told the tool exists at all. A host whose
    /// entire tool surface is its own MCP server wants the latter — there is no
    /// sensible approval UI for `Bash` in an app that never runs shells.
    public let allowedTools: [String]?

    /// Tool names withheld unconditionally, applied after `allowedTools`.
    public let disallowedTools: [String]

    /// How many rounds of tool calls an in-process client may run before giving
    /// up. Ignored by CLI clients, which manage their own loop.
    public let maxToolIterations: Int

    public init(
        turnID: UUID = UUID(),
        threadID: AgentThreadID,
        resumeSessionID: String? = nil,
        prompt: String,
        attachments: [AgentAttachment] = [],
        workingDirectory: URL,
        model: String? = nil,
        effort: String? = nil,
        permissionMode: PermissionMode = .default,
        planMode: Bool = false,
        contextText: String = "",
        toolServer: LocalToolServerHandle? = nil,
        mcpServers: [MCPServerSpec] = [],
        permissions: any PermissionResolving = DenyAllPermissions(),
        localTools: [AnyAgentTool] = [],
        toolContext: AgentToolContext? = nil,
        history: [AgentMessage] = [],
        allowedTools: [String]? = nil,
        disallowedTools: [String] = [],
        maxToolIterations: Int = 20
    ) {
        self.turnID = turnID
        self.threadID = threadID
        self.resumeSessionID = resumeSessionID
        self.prompt = prompt
        self.attachments = attachments
        self.workingDirectory = workingDirectory
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.planMode = planMode
        self.contextText = contextText
        self.toolServer = toolServer
        self.mcpServers = mcpServers
        self.permissions = permissions
        self.localTools = localTools
        self.toolContext = toolContext ?? AgentToolContext(
            threadID: threadID,
            workingDirectory: workingDirectory
        )
        self.history = history
        self.allowedTools = allowedTools
        self.disallowedTools = disallowedTools
        self.maxToolIterations = maxToolIterations
    }

    /// Whether `name` survives this turn's allowlist and denylist.
    ///
    /// Matching is namespace-insensitive: a host declares `caption_export` once
    /// and it holds whether the caller says `caption_export` (in-process) or
    /// `mcp__film_workflow__caption_export` (a CLI agent). See ``MCPToolName``.
    public func permitsTool(named name: String) -> Bool {
        let bare = MCPToolName.bare(name)
        if disallowedTools.contains(where: { MCPToolName.bare($0) == bare }) { return false }
        guard let allowedTools else { return true }
        return allowedTools.contains { MCPToolName.bare($0) == bare }
    }

    /// The names of every MCP server this turn can reach, for expanding a bare
    /// tool name into the namespaced form a CLI agent will use.
    public var mcpServerNames: [String] {
        var names = mcpServers.filter(\.enabled).map(\.name)
        if let toolServer { names.append(toolServer.name) }
        return names
    }
}

// MARK: - Client

/// A transport that can run a turn against some coding agent.
///
/// Conformers are `Sendable` value types; per-process mutable state lives in an
/// internal actor each client holds. RxCode's equivalent protocol required
/// `Actor` conformance, which forced actor isolation onto every call site for no
/// benefit.
public protocol AgentClient: Sendable {
    var id: AgentClientID { get }
    var displayName: String { get }
    var provider: AgentProvider { get }
    var capabilities: AgentCapabilities { get }

    /// Whether the underlying binary is present and runnable.
    func isAvailable() async -> Bool

    func availableModels() async -> [AgentModelOption]

    /// The reasoning-effort levels this client accepts, in ascending order of
    /// effort. Empty means the client has no such dial, and UI should offer no
    /// choice rather than an inert one.
    ///
    /// Whatever the user picks arrives back as ``AgentSendRequest/effort``, so
    /// each option's `id` is that client's own spelling — see
    /// ``AgentReasoningOption``.
    func availableReasoningLevels() async -> [AgentReasoningOption]

    func send(_ request: AgentSendRequest) -> AsyncStream<AgentEvent>

    /// User-initiated stop. Should cause the stream to end with `.turnEnded`
    /// or `.failed(.cancelled)`.
    func cancel(turn: UUID) async

    /// Delivers extra user input to a turn that is still running, without
    /// cancelling it. Returns `false` when the client can't steer, or when the
    /// turn is no longer accepting input; the caller should then fall back to
    /// sending the input as its own turn.
    func steer(turn: UUID, prompt: String, attachments: [AgentAttachment]) async -> Bool

    /// Release any long-lived resources held for this thread (ACP keeps a child
    /// process alive across turns; the others are no-ops).
    func endSession(thread: AgentThreadID) async
}

public extension AgentClient {
    func isAvailable() async -> Bool { true }
    func availableModels() async -> [AgentModelOption] { [] }
    func availableReasoningLevels() async -> [AgentReasoningOption] { [] }
    func endSession(thread: AgentThreadID) async {}
    func steer(turn: UUID, prompt: String, attachments: [AgentAttachment]) async -> Bool { false }
}
