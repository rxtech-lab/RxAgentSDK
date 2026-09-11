import Foundation
import FoundationModels
import RxAgentCore

// MARK: - FoundationModels bridge

/// The FoundationModels half of ``AnyAgentTool``.
///
/// The type itself lives in `RxAgentCore` so that the in-process clients — which
/// must not depend on FoundationModels — can invoke a tool directly. What stays
/// here is the part that genuinely needs the framework: turning a
/// `FoundationModels.Tool` into an erased one, which requires the concrete
/// `Arguments` and `Output` types to still be statically known.
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
