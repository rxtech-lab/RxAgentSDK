import Foundation

// MARK: - Tool result

public enum AgentToolResult: Sendable, Equatable {
    case text(String)
    case error(String)

    public var isError: Bool {
        if case .error = self { return true }
        return false
    }

    public var content: String {
        switch self {
        case .text(let value), .error(let value): value
        }
    }
}

// MARK: - Annotations

/// MCP tool annotations. Purely advisory hints for the calling agent.
public struct AgentToolAnnotations: Sendable, Hashable {
    public var title: String?
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?
    public var idempotentHint: Bool?

    public init(
        title: String? = nil,
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil
    ) {
        self.title = title
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
    }

    public static let readOnly = AgentToolAnnotations(readOnlyHint: true)
    public static let destructive = AgentToolAnnotations(destructiveHint: true)
}

// MARK: - Session state

/// Key for a value shared across a thread's tools and context.
///
/// This is the stand-in for FoundationModels 27's `@SessionProperty` /
/// `SessionPropertyValues`, which don't exist on 26.
public protocol AgentStateKey: Sendable {
    associatedtype Value: Sendable
    static var defaultValue: Value { get }
}

/// Thread-scoped shared state, readable and writable from tools.
public struct AgentStateValues: Sendable {
    private var storage: [ObjectIdentifier: any Sendable] = [:]

    public init() {}

    public subscript<K: AgentStateKey>(key: K.Type) -> K.Value {
        get { storage[ObjectIdentifier(key)] as? K.Value ?? K.defaultValue }
        set { storage[ObjectIdentifier(key)] = newValue }
    }
}

// MARK: - Invocation context

/// Handed to a tool when the agent calls it.
public struct AgentToolContext: Sendable {
    public let threadID: AgentThreadID
    public let workingDirectory: URL
    public let state: AgentStateValues

    public init(threadID: AgentThreadID, workingDirectory: URL, state: AgentStateValues = .init()) {
        self.threadID = threadID
        self.workingDirectory = workingDirectory
        self.state = state
    }
}

// MARK: - Erased tool

/// A tool the SDK can advertise over MCP and invoke by name.
///
/// Erasure is unavoidable rather than stylistic. `FoundationModels.Tool`
/// constrains `Output` only to `PromptRepresentable`, and `Prompt` — like
/// `Instructions` — exposes no way to read its text back. So a value of type
/// `any Tool` cannot be invoked usefully: there is nowhere to get bytes from.
/// The conversion has to happen where the concrete `Output` type is still
/// statically known, which is what `AnyAgentTool.tool(_:annotations:)` in
/// `RxAgentContext` does.
///
/// The type itself lives here, in the FoundationModels-free layer, because both
/// consumers need it and only one of them can import FoundationModels: the MCP
/// tool server publishes these to an external CLI, and the **in-process clients
/// call `invoke` directly**. Routing an in-process model's tool call out to a
/// loopback socket and back into the same process would be absurd, so the
/// closure has to be reachable without the bridge.
public struct AnyAgentTool: Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String
    /// JSON Schema, ready for an MCP `tools/list` `inputSchema` field.
    public let inputSchema: JSONValue
    public let annotations: AgentToolAnnotations

    let invoke: @Sendable (JSONValue, AgentToolContext) async throws -> AgentToolResult

    public init(
        name: String,
        description: String,
        inputSchema: JSONValue,
        annotations: AgentToolAnnotations = .init(),
        invoke: @escaping @Sendable (JSONValue, AgentToolContext) async throws -> AgentToolResult
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.invoke = invoke
    }

    /// Run the tool. Thrown errors become `.error` results so a misbehaving tool
    /// reports back to the agent instead of tearing down the turn.
    public func call(_ arguments: JSONValue, context: AgentToolContext) async -> AgentToolResult {
        do {
            return try await invoke(arguments, context)
        } catch {
            return .error(String(describing: error))
        }
    }
}

public extension AnyAgentTool {
    /// A tool defined inline, without going through FoundationModels. Useful
    /// when the schema is only known at runtime.
    static func dynamic(
        name: String,
        description: String,
        inputSchema: JSONValue,
        annotations: AgentToolAnnotations = .init(),
        handler: @escaping @Sendable (JSONValue, AgentToolContext) async throws -> AgentToolResult
    ) -> AnyAgentTool {
        AnyAgentTool(
            name: name,
            description: description,
            inputSchema: inputSchema,
            annotations: annotations,
            invoke: handler
        )
    }
}
