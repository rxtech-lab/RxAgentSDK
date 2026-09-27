#if os(macOS)
import RxAgentCore
import Testing
@testable import RxAgentClients

@Suite("Qwen Code ACP factory")
struct QwenCodeFactoryTests {
    @Test("Builds a native Qwen Code ACP client")
    func buildsClient() throws {
        let factory = QwenCodeFactory()
        let client = try factory.makeClient(
            configuration: AgentClientConfiguration(clientID: .qwenCode)
        )

        #expect(client.id == .qwenCode)
        #expect(client.displayName == "Qwen Code")
        #expect(client.provider == .acp)
        #expect(client.capabilities.contains(.modelSelection))
    }

    @Test("Rejects a configuration for another client")
    func rejectsMismatchedConfiguration() {
        #expect(throws: AgentClientRegistryError.configurationMismatch(
            expected: .qwenCode,
            actual: .qwen
        )) {
            try QwenCodeFactory().makeClient(
                configuration: AgentClientConfiguration(clientID: .qwen)
            )
        }
    }
}
#endif
