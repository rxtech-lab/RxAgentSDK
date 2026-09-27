import RxAgentCore
import RxAgentLLM

#if os(macOS)
import RxAgentClients
#endif

/// Built-in factories for hosts migrating from fixed Provider switches.
///
/// This is additive: existing apps can continue constructing clients directly
/// and RxCode's current SDK backend remains unchanged. A host can register its
/// own factories after creating this registry.
public enum DefaultAgentClientRegistry {
    public static func make() throws -> AgentClientRegistry {
        var factories: [any AgentClientFactory] = [
            OpenAICompatibleFactory(),
            QwenModelFactory(),
        ]

        #if os(macOS)
        factories += [ClaudeCodeFactory(), CodexFactory(), QwenCodeFactory()]
        #endif

        return try AgentClientRegistry(factories: factories)
    }
}
