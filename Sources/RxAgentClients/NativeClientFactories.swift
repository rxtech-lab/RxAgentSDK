#if os(macOS)
import Foundation
import RxAgentCore

public struct ClaudeCodeFactory: AgentClientFactory {
    public let descriptor = AgentClientDescriptor(
        id: .claudeCode,
        displayName: "Claude Code",
        provider: .claudeCode,
        capabilities: .claudeCodeDefaults
    )

    public init() {}

    public func makeClient(configuration: AgentClientConfiguration) throws -> any AgentClient {
        guard configuration.clientID == descriptor.id else {
            throw AgentClientRegistryError.configurationMismatch(
                expected: descriptor.id,
                actual: configuration.clientID
            )
        }
        return ClaudeCodeClient()
    }
}

public struct CodexFactory: AgentClientFactory {
    public let descriptor = AgentClientDescriptor(
        id: .codex,
        displayName: "Codex",
        provider: .codex,
        capabilities: .codexDefaults
    )

    public init() {}

    public func makeClient(configuration: AgentClientConfiguration) throws -> any AgentClient {
        guard configuration.clientID == descriptor.id else {
            throw AgentClientRegistryError.configurationMismatch(
                expected: descriptor.id,
                actual: configuration.clientID
            )
        }
        return CodexClient()
    }
}
#endif
