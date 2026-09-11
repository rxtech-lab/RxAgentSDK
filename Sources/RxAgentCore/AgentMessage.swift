import Foundation

// MARK: - Tool Call

public struct AgentToolCall: Sendable, Identifiable, Hashable {
    public let id: String
    public var name: String
    public var input: [String: JSONValue]
    public var result: String?
    public var isError: Bool
    /// False until `toolCallInput` lands. The UI renders a spinner until then.
    public var hasCompleteInput: Bool

    public init(
        id: String,
        name: String,
        input: [String: JSONValue] = [:],
        result: String? = nil,
        isError: Bool = false,
        hasCompleteInput: Bool = false
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.result = result
        self.isError = isError
        self.hasCompleteInput = hasCompleteInput
    }

    public var category: ToolCategory { ToolCategory(toolName: name) }
    public var isComplete: Bool { result != nil }
}

// MARK: - Content Block

public enum AgentBlock: Sendable, Hashable, Identifiable {
    case text(id: UUID, String)
    case thinking(id: UUID, String)
    case toolCall(AgentToolCall)

    public var id: String {
        switch self {
        case .text(let id, _): "text-\(id)"
        case .thinking(let id, _): "thinking-\(id)"
        case .toolCall(let call): "tool-\(call.id)"
        }
    }

    public var text: String? {
        if case .text(_, let value) = self { return value }
        return nil
    }

    public var thinking: String? {
        if case .thinking(_, let value) = self { return value }
        return nil
    }

    public var toolCall: AgentToolCall? {
        if case .toolCall(let call) = self { return call }
        return nil
    }
}

// MARK: - Message

public struct AgentMessage: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var role: AgentRole
    public var blocks: [AgentBlock]
    public var timestamp: Date
    /// True while this message is still receiving deltas.
    public var isStreaming: Bool
    /// Set when the turn failed and this message carries the error text.
    public var error: String?
    /// Files/images the user attached to this prompt. Empty for assistant messages.
    public var attachments: [AgentAttachment]

    public init(
        id: UUID = UUID(),
        role: AgentRole,
        blocks: [AgentBlock] = [],
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        error: String? = nil,
        attachments: [AgentAttachment] = []
    ) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.error = error
        self.attachments = attachments
    }

    /// Convenience for a plain-text message.
    public static func text(_ text: String, role: AgentRole) -> AgentMessage {
        AgentMessage(role: role, blocks: [.text(id: UUID(), text)])
    }

    /// All text blocks joined — what you'd copy to the clipboard.
    public var plainText: String {
        blocks.compactMap(\.text).joined(separator: "\n\n")
    }

    public var toolCalls: [AgentToolCall] {
        blocks.compactMap(\.toolCall)
    }
}

// MARK: - Attachments

public struct AgentAttachment: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case file(URL)
        case image(Data, mimeType: String)
        case text(String)
    }

    public let id: UUID
    public let kind: Kind
    public let label: String?

    public init(id: UUID = UUID(), kind: Kind, label: String? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
    }

    public static func file(_ url: URL) -> AgentAttachment {
        AgentAttachment(kind: .file(url), label: url.lastPathComponent)
    }
}
