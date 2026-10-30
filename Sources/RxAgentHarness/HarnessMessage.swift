import Foundation
import RxAgentCore

// MARK: - Tool call

/// A tool call the model asked for, with its arguments still as the raw JSON
/// text the model wrote.
///
/// Kept raw because a small local model regularly emits arguments that are
/// *almost* JSON. Parsing happens at dispatch, where a failure can be reported
/// back to the model as a tool error it can correct, rather than here, where it
/// would have nowhere to go.
public struct HarnessToolCall: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }

    /// Parsed arguments, or `nil` when the model wrote something unparseable.
    public var arguments: JSONValue? {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .object([:]) }
        return JSONValue(jsonString: trimmed)
    }
}

// MARK: - Image

public struct HarnessImage: Sendable, Hashable, Codable {
    public let mimeType: String
    public let data: Data

    public init(mimeType: String, data: Data) {
        self.mimeType = mimeType
        self.data = data
    }

    public var dataURL: String { "data:\(mimeType);base64,\(data.base64EncodedString())" }
}

// MARK: - Message

/// One entry of a harness session's history.
///
/// Unlike ``AgentMessage`` — a *display* model whose assistant turns interleave
/// text and tool calls as blocks — this is the *wire* model: it keeps every tool
/// call paired with its `tool` result so the conversation can be replayed to the
/// model exactly as it happened. An in-process agent has no server-side session
/// to resume, so this history is the session.
public struct HarnessMessage: Sendable, Hashable, Codable, Identifiable {
    public enum Role: String, Sendable, Codable, Hashable {
        case system
        case user
        case assistant
        case tool
    }

    public let id: UUID
    public var role: Role
    public var text: String
    /// Reasoning the model emitted before answering. Stored for display and
    /// never replayed: no OpenAI-compatible server accepts it back.
    public var reasoning: String?
    public var toolCalls: [HarnessToolCall]
    /// For `.tool` messages: the call this result answers.
    public var toolCallID: String?
    public var toolName: String?
    public var isError: Bool
    public var images: [HarnessImage]
    public var createdAt: Date
    /// Set once compaction has pruned this tool result's output. The original
    /// text is gone from what the model sees, but the flag lets a UI say why.
    public var isPruned: Bool
    /// True for the synthetic message carrying a compaction summary.
    public var isSummary: Bool

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String = "",
        reasoning: String? = nil,
        toolCalls: [HarnessToolCall] = [],
        toolCallID: String? = nil,
        toolName: String? = nil,
        isError: Bool = false,
        images: [HarnessImage] = [],
        createdAt: Date = Date(),
        isPruned: Bool = false,
        isSummary: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.isError = isError
        self.images = images
        self.createdAt = createdAt
        self.isPruned = isPruned
        self.isSummary = isSummary
    }

    public static func user(_ text: String, images: [HarnessImage] = []) -> HarnessMessage {
        HarnessMessage(role: .user, text: text, images: images)
    }

    public static func assistant(_ text: String, toolCalls: [HarnessToolCall] = []) -> HarnessMessage {
        HarnessMessage(role: .assistant, text: text, toolCalls: toolCalls)
    }

    public static func toolResult(
        callID: String, name: String, text: String, isError: Bool = false
    ) -> HarnessMessage {
        HarnessMessage(role: .tool, text: text, toolCallID: callID, toolName: name, isError: isError)
    }

    // Tolerant decoding: sessions written by an older build may lack newer keys.
    enum CodingKeys: String, CodingKey {
        case id, role, text, reasoning, toolCalls, toolCallID, toolName, isError
        case images, createdAt, isPruned, isSummary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        toolCalls = try container.decodeIfPresent([HarnessToolCall].self, forKey: .toolCalls) ?? []
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        images = try container.decodeIfPresent([HarnessImage].self, forKey: .images) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        isPruned = try container.decodeIfPresent(Bool.self, forKey: .isPruned) ?? false
        isSummary = try container.decodeIfPresent(Bool.self, forKey: .isSummary) ?? false
    }
}
