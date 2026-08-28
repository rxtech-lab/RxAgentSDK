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

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .acp: "ACP"
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
        .todos, .planMode, .fileEdit, .usageReporting,
        .mcpServers, .modelSelection, .thinking,
    ]

    static let acpDefaults: AgentCapabilities = [
        .todos, .fileEdit, .mcpServers, .thinking,
    ]
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
