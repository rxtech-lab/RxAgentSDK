#if os(macOS)
import Foundation
import RxAgentCore

/// Registry adapter for the native Qwen Code coding-agent runtime.
///
/// Qwen Code owns the model loop, tools, permissions, MCP and session state.
/// RxAgentSDK only starts `qwen --acp` and translates ACP events through the
/// existing ``ACPClient`` implementation.
public struct QwenCodeFactory: AgentClientFactory {
    public let descriptor: AgentClientDescriptor

    private let command: String
    private let arguments: [String]
    private let environment: [String: String]
    private let capabilities: AgentCapabilities

    public init(
        command: String = "qwen",
        arguments: [String] = ["--acp"],
        environment: [String: String] = [:],
        capabilities: AgentCapabilities = AgentCapabilities.acpDefaults
            .union([.modelSelection])
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.capabilities = capabilities
        self.descriptor = AgentClientDescriptor(
            id: .qwenCode,
            displayName: "Qwen Code",
            provider: .acp,
            capabilities: capabilities
        )
    }

    public func makeClient(configuration: AgentClientConfiguration) throws -> any AgentClient {
        guard configuration.clientID == descriptor.id else {
            throw AgentClientRegistryError.configurationMismatch(
                expected: descriptor.id,
                actual: configuration.clientID
            )
        }

        return ACPClient(
            command: command,
            args: arguments,
            env: environment,
            displayName: descriptor.displayName,
            id: descriptor.id,
            modelEnvVar: "QWEN_MODEL",
            capabilities: capabilities
        )
    }
}
#endif
