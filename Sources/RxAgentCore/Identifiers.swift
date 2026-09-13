import Foundation

// MARK: - Client Identity

/// Stable identity for a configured client instance.
///
/// Deliberately *not* the provider: two different ACP agents are two different
/// clients and must not share a resume-id bucket.
public struct AgentClientID: Hashable, Sendable, Codable, ExpressibleByStringLiteral,
                             CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }

    public static let claudeCode: AgentClientID = "claude-code"
    public static let codex: AgentClientID = "codex"
    public static let openAICompatible: AgentClientID = "openai-compatible"
    public static let foundationModels: AgentClientID = "foundation-models"

    /// Namespaced id for an ACP agent, e.g. `acp:gemini`.
    public static func acp(_ name: String) -> AgentClientID { AgentClientID("acp:\(name)") }
}

// MARK: - Thread Identity

/// SDK-owned conversation identity. Minted once and never reassigned — in
/// particular it is never a provider's native session id, which is what lets a
/// single thread span multiple clients.
public struct AgentThreadID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }

    public var description: String { rawValue.uuidString }
}

// MARK: - Provider

/// The wire protocol a client speaks. Used for coarse behavior switches and for
/// grouping in UI; client *identity* is `AgentClientID`.
public enum AgentProvider: String, Codable, CaseIterable, Sendable, Hashable {
    case claudeCode
    case codex
    case acp
    /// An OpenAI-compatible `/chat/completions` endpoint, driven in-process.
    case openAICompatible
    /// Apple's on-device model, driven in-process.
    case foundationModels

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .acp: "ACP"
        case .openAICompatible: "OpenAI-compatible"
        case .foundationModels: "Apple Intelligence"
        }
    }

    /// Whether the provider runs an agent binary in a child process.
    ///
    /// The line that matters for platform support: everything on the far side of
    /// it is macOS-only, everything on this side works on iOS too.
    public var spawnsProcess: Bool {
        switch self {
        case .claudeCode, .codex, .acp: true
        case .openAICompatible, .foundationModels: false
        }
    }
}

// MARK: - Capabilities

/// What a client supports natively. The *complement* drives which SDK-side
/// polyfill tools get exposed over the local MCP server for a given session.
public enum AgentCapability: String, Sendable, Hashable, CaseIterable, Codable {
    case askUserQuestion
    case todos
    case planMode
    case fileEdit
    case usageReporting
    case attachments
    case hooks
    case mcpServers
    case skills
    case modelSelection
    case thinking
}

public typealias AgentCapabilities = Set<AgentCapability>

public extension AgentCapabilities {
    static let claudeCodeDefaults: AgentCapabilities = [
        .askUserQuestion, .todos, .planMode, .fileEdit, .usageReporting,
        .attachments, .hooks, .mcpServers, .skills, .modelSelection, .thinking,
    ]

    static let codexDefaults: AgentCapabilities = [
        .todos, .planMode, .fileEdit, .usageReporting, .attachments,
        .mcpServers, .modelSelection, .thinking,
    ]

    static let acpDefaults: AgentCapabilities = [
        .todos, .fileEdit, .mcpServers, .thinking,
    ]

    /// No `.hooks` or `.skills`: both are agent-binary mechanisms, and an
    /// in-process loop has neither to honour. No `.planMode` either — there is
    /// no agent to hold a plan for us.
    static let openAICompatibleDefaults: AgentCapabilities = [
        .fileEdit, .usageReporting, .attachments, .mcpServers, .modelSelection,
    ]

    /// Deliberately small. The on-device model has a context window measured in
    /// low thousands of tokens, no tool calling worth the name, and no usage
    /// reporting.
    static let foundationModelsDefaults: AgentCapabilities = []
}

// MARK: - Model Options

public struct AgentModelOption: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let displayName: String
    public let modelDescription: String?

    public init(id: String, displayName: String, modelDescription: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.modelDescription = modelDescription
    }
}
