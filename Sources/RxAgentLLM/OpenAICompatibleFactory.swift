import Foundation
import RxAgentCore

/// Generic factory for an OpenAI-compatible model endpoint.
///
/// Provider-specific factories such as ``QwenModelFactory`` can add defaults
/// and provider fields; hosts should use this one when a gateway needs only a
/// URL, model, bearer key, and optional extra body.
public struct OpenAICompatibleFactory: AgentClientFactory {
    public let descriptor: AgentClientDescriptor

    public init(
        id: AgentClientID = .openAICompatible,
        displayName: String = "OpenAI-compatible",
        capabilities: AgentCapabilities = .openAICompatibleDefaults
    ) {
        descriptor = AgentClientDescriptor(
            id: id,
            displayName: displayName,
            provider: .openAICompatible,
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
        guard let endpoint = configuration.endpoint else {
            throw OpenAICompatibleFactoryError.missingEndpoint
        }
        guard let secret = configuration.secret, !secret.isEmpty else {
            throw OpenAICompatibleFactoryError.missingAPIKey
        }
        return OpenAIChatClient(
            id: descriptor.id,
            displayName: descriptor.displayName,
            configuration: .apiKey(
                secret,
                endpoint: endpoint,
                model: configuration.model,
                extraBody: configuration.extraBody
            ),
            capabilities: descriptor.capabilities
        )
    }
}

public enum OpenAICompatibleFactoryError: Error, LocalizedError, Sendable, Equatable {
    case missingEndpoint
    case missingAPIKey

    public var errorDescription: String? {
        switch self {
        case .missingEndpoint: "An OpenAI-compatible endpoint is required."
        case .missingAPIKey: "An API key is required to create this client."
        }
    }
}
