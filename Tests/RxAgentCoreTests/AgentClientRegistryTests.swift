import Foundation
import RxAgentCore
import Testing

private struct TestFactory: AgentClientFactory {
    let descriptor: AgentClientDescriptor

    func makeClient(configuration: AgentClientConfiguration) throws -> any AgentClient {
        PreviewAgentClient(
            id: descriptor.id,
            displayName: descriptor.displayName,
            provider: descriptor.provider,
            capabilities: descriptor.capabilities
        )
    }
}

@Suite("Agent client registry")
struct AgentClientRegistryTests {
    private let previewFactory = TestFactory(descriptor: AgentClientDescriptor(
        id: "preview",
        displayName: "Preview",
        provider: .claudeCode,
        capabilities: .claudeCodeDefaults
    ))

    @Test("Registers, discovers, and creates a client")
    func registerDiscoverCreate() async throws {
        let registry = AgentClientRegistry()
        try await registry.register(previewFactory)

        let descriptors = await registry.descriptors()
        #expect(descriptors.map(\.id) == [AgentClientID("preview")])

        let client = try await registry.makeClient(
            id: "preview",
            configuration: AgentClientConfiguration(clientID: "preview")
        )
        #expect(client.id == "preview")
        #expect(client.capabilities.contains(.fileEdit))
    }

    @Test("Rejects duplicate registration and mismatched configuration")
    func rejectsInvalidRegistration() async throws {
        let registry = AgentClientRegistry()
        try await registry.register(previewFactory)

        do {
            try await registry.register(previewFactory)
            Issue.record("Duplicate registration unexpectedly succeeded")
        } catch let error as AgentClientRegistryError {
            #expect(error == .duplicateClient("preview"))
        }

        do {
            _ = try await registry.makeClient(
                id: "preview",
                configuration: AgentClientConfiguration(clientID: "other")
            )
            Issue.record("Mismatched configuration unexpectedly succeeded")
        } catch let error as AgentClientRegistryError {
            #expect(error == .configurationMismatch(expected: "preview", actual: "other"))
        }
    }

    @Test("Replaces and removes factories")
    func replaceAndRemove() async throws {
        let registry = AgentClientRegistry()
        try await registry.register(previewFactory)
        await registry.replace(TestFactory(descriptor: AgentClientDescriptor(
            id: "preview",
            displayName: "Preview Replaced",
            provider: .acp,
            capabilities: .acpDefaults
        )))
        #expect(await registry.descriptor(for: "preview")?.displayName == "Preview Replaced")
        #expect(await registry.remove("preview"))
        #expect(await registry.descriptors().isEmpty)
    }

    @Test("Initializes from factories and sorts descriptors for UI")
    func initializesAndSorts() async throws {
        let zulu = TestFactory(descriptor: AgentClientDescriptor(
            id: "zulu", displayName: "Zulu", provider: .acp, capabilities: []
        ))
        let alpha = TestFactory(descriptor: AgentClientDescriptor(
            id: "alpha", displayName: "Alpha", provider: .acp, capabilities: []
        ))
        let registry = try AgentClientRegistry(factories: [zulu, alpha])

        #expect(await registry.descriptors().map(\.displayName) == ["Alpha", "Zulu"])
    }

    @Test("Reports missing clients and missing removals")
    func missingClientAndRemoval() async throws {
        let registry = AgentClientRegistry()
        #expect(await registry.remove("missing") == false)

        do {
            _ = try await registry.makeClient(
                id: "missing",
                configuration: AgentClientConfiguration(clientID: "missing")
            )
            Issue.record("An unregistered client unexpectedly succeeded")
        } catch let error as AgentClientRegistryError {
            #expect(error == .clientNotRegistered("missing"))
        }
    }

    @Test("Does not encode secrets into persisted configuration")
    func secretIsNotPersisted() throws {
        let configuration = AgentClientConfiguration(
            clientID: .qwen,
            endpoint: URL(string: "https://example.test/v1"),
            model: "qwen3-coder-plus",
            workspaceID: "workspace",
            secret: "never-write-this",
            extraBody: ["enable_thinking": .bool(true)]
        )
        let data = try JSONEncoder().encode(configuration)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("never-write-this"))

        let decoded = try JSONDecoder().decode(AgentClientConfiguration.self, from: data)
        #expect(decoded.secret == nil)
        #expect(decoded.clientID == .qwen)
        #expect(decoded.extraBody["enable_thinking"]?.boolValue == true)
    }
}
