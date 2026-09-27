import Foundation
import RxAgentCore
import Testing

@testable import RxAgentLLM

@Suite("OpenAI-compatible factory")
struct OpenAICompatibleFactoryTests {
    @Test("Builds a configured client")
    func buildsClient() throws {
        let factory = OpenAICompatibleFactory()
        let client = try factory.makeClient(configuration: AgentClientConfiguration(
            clientID: .openAICompatible,
            endpoint: URL(string: "https://gateway.example/v1"),
            model: "model-a",
            secret: "test-key",
            extraBody: ["provider_option": .string("value")]
        ))

        #expect(client.id == .openAICompatible)
        #expect(client.provider == .openAICompatible)
        #expect(client.capabilities.contains(.modelSelection))
    }

    @Test("Rejects missing endpoint and secret")
    func validatesRequiredConfiguration() {
        let factory = OpenAICompatibleFactory()

        #expect(throws: OpenAICompatibleFactoryError.missingEndpoint) {
            try factory.makeClient(configuration: AgentClientConfiguration(
                clientID: .openAICompatible,
                secret: "test-key"
            ))
        }

        #expect(throws: OpenAICompatibleFactoryError.missingAPIKey) {
            try factory.makeClient(configuration: AgentClientConfiguration(
                clientID: .openAICompatible,
                endpoint: URL(string: "https://gateway.example/v1")
            ))
        }
    }

    @Test("Rejects a configuration for another registered client")
    func validatesClientID() {
        #expect(throws: AgentClientRegistryError.configurationMismatch(
            expected: .openAICompatible,
            actual: .qwen
        )) {
            try OpenAICompatibleFactory().makeClient(
                configuration: AgentClientConfiguration(clientID: .qwen)
            )
        }
    }
}
