import Foundation
import RxAgentCore
import Testing

@testable import RxAgentLLM

@Suite("Qwen model configuration")
struct QwenModelConfigurationTests {

    @Test("Uses the public China endpoint by default")
    func defaultEndpoint() {
        let configuration = QwenModelConfiguration(
            apiKey: "test-key",
            model: "qwen3-coder-plus"
        )

        #expect(configuration.endpoint.absoluteString == "https://dashscope.aliyuncs.com/compatible-mode/v1")
    }

    @Test("Builds a workspace-specific regional endpoint")
    func workspaceEndpoint() {
        let endpoint = QwenModelConfiguration.endpoint(
            for: .chinaBeijing,
            workspaceID: "ws-123"
        )

        #expect(endpoint.absoluteString == "https://ws-123.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")
    }

    @Test("Keeps Qwen thinking fields at the configuration boundary")
    func qwenBodyFields() {
        let configuration = QwenModelConfiguration(
            apiKey: "test-key",
            model: "qwen3-coder-plus",
            enableThinking: true,
            thinkingBudget: 2048,
            extraBody: ["custom_option": .string("value")]
        )
        let client = configuration.makeClient()
        let request = AgentSendRequest(
            threadID: AgentThreadID(),
            prompt: "hello",
            workingDirectory: URL(filePath: "/tmp")
        )

        let body = client.requestBody(for: request)
        #expect(body["enable_thinking"]?.boolValue == true)
        #expect(body["thinking_budget"]?.intValue == 2048)
        #expect(body["custom_option"]?.stringValue == "value")
    }

    @Test("Allows an explicit endpoint override")
    func endpointOverride() {
        let endpoint = URL(string: "https://private.example/v1")!
        let configuration = QwenModelConfiguration(
            apiKey: "test-key",
            model: "deployed-qwen",
            endpoint: endpoint
        )

        #expect(configuration.endpoint == endpoint)
        #expect(configuration.makeClient().configuration.endpoint == endpoint)
    }

    @Test("Creates Qwen clients through the SDK registry factory")
    func registryFactory() async throws {
        let factory = QwenModelFactory(modelOptions: [
            AgentModelOption(id: "qwen3-coder-plus", displayName: "Qwen3 Coder Plus"),
            AgentModelOption(id: "qwen-plus", displayName: "Qwen Plus"),
        ])
        let client = try factory.makeClient(configuration: AgentClientConfiguration(
            clientID: .qwen,
            model: "qwen3-coder-plus",
            secret: "test-key"
        ))

        #expect(client.id == .qwen)
        #expect(client.provider == .openAICompatible)
        #expect(client.capabilities.contains(.modelSelection))
        #expect(await client.availableModels().map(\.id) == ["qwen3-coder-plus", "qwen-plus"])
    }

    @Test("Rejects a Qwen registry configuration without a secret")
    func registryFactoryRequiresSecret() {
        #expect(throws: QwenModelFactoryError.missingAPIKey) {
            try QwenModelFactory().makeClient(configuration: AgentClientConfiguration(clientID: .qwen))
        }
    }
}
