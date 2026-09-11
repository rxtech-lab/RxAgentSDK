import Foundation
import FoundationModels
import RxAgentCore

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
/// statically known, which is exactly what ``tool(_:annotations:)`` does.
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

// MARK: - FoundationModels bridge

public extension AnyAgentTool {
    /// Erase a FoundationModels tool.
    ///
    /// ```swift
    /// @Generable struct GrepArgs {
    ///     @Guide(description: "Regex to search for") var pattern: String
    /// }
    /// struct GrepTool: Tool {
    ///     let name = "grep_workspace"
    ///     let description = "Search the open workspace for a regex."
    ///     func call(arguments: GrepArgs) async throws -> String { … }
    /// }
    ///
    /// Agent(clients: [...], tools: [.tool(GrepTool())])
    /// ```
    static func tool<T: FoundationModels.Tool>(
        _ tool: T,
        annotations: AgentToolAnnotations = .init()
    ) -> AnyAgentTool where T.Output: ConvertibleToGeneratedContent {
        AnyAgentTool(
            name: tool.name,
            description: tool.description,
            inputSchema: JSONSchemaExporter.export(tool.parameters),
            annotations: annotations
        ) { arguments, _ in
            let content = try GeneratedContent(json: arguments.jsonString)
            let typed = try content.value(T.Arguments.self)
            let output = try await tool.call(arguments: typed)
            return .text(stringify(output))
        }
    }

    /// For tools whose `Output` is only `PromptRepresentable` and so can't be
    /// stringified automatically. Supply the encoding yourself.
    static func tool<T: FoundationModels.Tool>(
        _ tool: T,
        annotations: AgentToolAnnotations = .init(),
        encodeOutput: @escaping @Sendable (T.Output) -> AgentToolResult
    ) -> AnyAgentTool {
        AnyAgentTool(
            name: tool.name,
            description: tool.description,
            inputSchema: JSONSchemaExporter.export(tool.parameters),
            annotations: annotations
        ) { arguments, _ in
            let content = try GeneratedContent(json: arguments.jsonString)
            let typed = try content.value(T.Arguments.self)
            return encodeOutput(try await tool.call(arguments: typed))
        }
    }

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

    /// Render a tool's output as the text the agent will read.
    ///
    /// `generatedContent.jsonString` on a `String` output yields a *quoted*
    /// JSON string (`"sunny"`), which would leak quotes into every result — so
    /// unwrap the string case first and only fall back to JSON for structured
    /// outputs.
    internal static func stringify(_ output: some ConvertibleToGeneratedContent) -> String {
        let content = output.generatedContent
        if let string = try? content.value(String.self) { return string }
        return content.jsonString
    }
}
