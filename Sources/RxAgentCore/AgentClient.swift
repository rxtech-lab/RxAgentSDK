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
    public let effort: String?
    public let permissionMode: PermissionMode
    public let planMode: Bool
    /// Rendered once by `Agent`. Claude consumes it via `--append-system-prompt`;
    /// Codex and ACP prepend it to the prompt.
    public let contextText: String
    public let toolServer: LocalToolServerHandle?
    public let mcpServers: [MCPServerSpec]
    public let permissions: any PermissionResolving

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
        permissions: any PermissionResolving = DenyAllPermissions()
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

    func send(_ request: AgentSendRequest) -> AsyncStream<AgentEvent>

    /// User-initiated stop. Should cause the stream to end with `.turnEnded`
    /// or `.failed(.cancelled)`.
    func cancel(turn: UUID) async

    /// Release any long-lived resources held for this thread (ACP keeps a child
    /// process alive across turns; the others are no-ops).
    func endSession(thread: AgentThreadID) async
}

public extension AgentClient {
    func isAvailable() async -> Bool { true }
    func availableModels() async -> [AgentModelOption] { [] }
    func endSession(thread: AgentThreadID) async {}
}
