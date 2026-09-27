import Foundation
import RxAgentCore

/// Configuration for Qwen models served through Alibaba Cloud Model Studio's
/// OpenAI-compatible Chat Completions endpoint.
///
/// This is deliberately a model configuration, not a Qwen Code harness. It
/// reuses ``OpenAIChatClient`` for the in-process tool loop and keeps Qwen-only
/// request fields at the provider boundary. A future Qwen Code client can use
/// the same credentials without changing this type.
public struct QwenModelConfiguration: Sendable {
    public enum Region: String, Sendable, Codable {
        case chinaBeijing
        case singapore
        case virginia

        fileprivate var legacyBaseURL: URL {
            switch self {
            case .chinaBeijing:
                URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!
            case .singapore:
                URL(string: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1")!
            case .virginia:
                URL(string: "https://dashscope-us.aliyuncs.com/compatible-mode/v1")!
            }
        }

        fileprivate var workspaceHostSuffix: String? {
            switch self {
            case .chinaBeijing: ".cn-beijing.maas.aliyuncs.com"
            case .singapore: ".ap-southeast-1.maas.aliyuncs.com"
            case .virginia: nil
            }
        }
    }

    public let apiKey: String
    public let model: String
    public let endpoint: URL
    public let enableThinking: Bool?
    public let thinkingBudget: Int?
    public let extraBody: [String: JSONValue]
    public let reasoningLevels: [AgentReasoningOption]
    public let modelOptions: [AgentModelOption]

    /// - Parameters:
    ///   - apiKey: DashScope API key. Keep this at the host boundary and do not
    ///     persist it in a model configuration sent over sync.
    ///   - model: DashScope model id, for example `qwen3-coder-plus`.
    ///   - region: The public Model Studio region endpoint to use.
    ///   - workspaceID: Optional workspace id for the recommended regional
    ///     endpoint. When omitted, the stable public endpoint is used.
    ///   - endpoint: Explicit endpoint override for private links, deployed
    ///     models, or a compatible gateway. It takes precedence over region.
    ///   - enableThinking: Qwen hybrid-thinking switch. Leave nil when the
    ///     selected model has its own default or does not support the field.
    ///   - thinkingBudget: Optional Qwen thinking token budget.
    ///   - extraBody: Additional OpenAI-compatible or DashScope body fields.
    ///   - reasoningLevels: Model-specific `reasoning_effort` values. Empty
    ///     means no reasoning picker is exposed by the SDK.
    public init(
        apiKey: String,
        model: String,
        region: Region = .chinaBeijing,
        workspaceID: String? = nil,
        endpoint: URL? = nil,
        enableThinking: Bool? = nil,
        thinkingBudget: Int? = nil,
        extraBody: [String: JSONValue] = [:],
        reasoningLevels: [AgentReasoningOption] = [],
        modelOptions: [AgentModelOption] = []
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint ?? Self.endpoint(for: region, workspaceID: workspaceID)
        self.enableThinking = enableThinking
        self.thinkingBudget = thinkingBudget
        self.extraBody = extraBody
        self.reasoningLevels = reasoningLevels
        self.modelOptions = modelOptions
    }

    /// Creates the generic OpenAI-compatible client used for Qwen model API
    /// access. The client provider remains `.openAICompatible` intentionally:
    /// Qwen model API compatibility is not the same thing as Qwen Code's
    /// native coding-agent harness.
    public func makeClient(
        id: AgentClientID = .qwen,
        displayName: String = "Qwen",
        capabilities: AgentCapabilities = .openAICompatibleDefaults
    ) -> OpenAIChatClient {
        var body = extraBody
        if let enableThinking {
            body["enable_thinking"] = .bool(enableThinking)
        }
        if let thinkingBudget {
            body["thinking_budget"] = .number(Double(thinkingBudget))
        }

        return OpenAIChatClient(
            id: id,
            displayName: displayName,
            configuration: .apiKey(
                apiKey,
                endpoint: endpoint,
                model: model,
                extraBody: body,
                reasoningLevels: reasoningLevels,
                modelOptions: modelOptions
            ),
            capabilities: capabilities
        )
    }

    public static func endpoint(for region: Region, workspaceID: String? = nil) -> URL {
        guard let workspaceID,
              !workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let suffix = region.workspaceHostSuffix
        else {
            return region.legacyBaseURL
        }

        return URL(string: "https://\(workspaceID)\(suffix)/compatible-mode/v1")!
    }
}
