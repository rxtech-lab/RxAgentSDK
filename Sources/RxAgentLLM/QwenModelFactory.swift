import Foundation
import RxAgentCore

/// Registry adapter for the DashScope OpenAI-compatible Qwen model client.
public struct QwenModelFactory: AgentClientFactory {
    public let descriptor = AgentClientDescriptor(
        id: .qwen,
        displayName: "Qwen",
        provider: .openAICompatible,
        capabilities: .openAICompatibleDefaults
    )

    public let region: QwenModelConfiguration.Region
    public let defaultModel: String
    public let enableThinking: Bool?
    public let thinkingBudget: Int?
    public let modelOptions: [AgentModelOption]

    public init(
        region: QwenModelConfiguration.Region = .chinaBeijing,
        defaultModel: String = "qwen3-coder-plus",
        enableThinking: Bool? = nil,
        thinkingBudget: Int? = nil,
        modelOptions: [AgentModelOption] = []
    ) {
        self.region = region
        self.defaultModel = defaultModel
        self.enableThinking = enableThinking
        self.thinkingBudget = thinkingBudget
        self.modelOptions = modelOptions
    }

    public func makeClient(configuration: AgentClientConfiguration) throws -> any AgentClient {
        guard let secret = configuration.secret, !secret.isEmpty else {
            throw QwenModelFactoryError.missingAPIKey
        }
        let model = configuration.model ?? defaultModel
        let qwen = QwenModelConfiguration(
            apiKey: secret,
            model: model,
            region: region,
            workspaceID: configuration.workspaceID,
            endpoint: configuration.endpoint,
            enableThinking: enableThinking,
            thinkingBudget: thinkingBudget,
            extraBody: configuration.extraBody,
            modelOptions: modelOptions
        )
        return qwen.makeClient()
    }
}

public enum QwenModelFactoryError: Error, LocalizedError, Sendable, Equatable {
    case missingAPIKey

    public var errorDescription: String? {
        "A DashScope API key is required to create the Qwen client."
    }
}
