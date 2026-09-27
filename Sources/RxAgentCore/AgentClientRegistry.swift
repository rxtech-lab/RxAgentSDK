import Foundation

/// The metadata a host needs before constructing a client.
///
/// `secret` is intentionally not encoded. Hosts may carry this value from a
/// Keychain for the duration of `makeClient`, but it must never be included in
/// synced or persisted configuration.
public struct AgentClientConfiguration: Sendable, Codable, Hashable {
    public let clientID: AgentClientID
    public var endpoint: URL?
    public var model: String?
    public var workspaceID: String?
    public var secret: String?
    public var extraBody: [String: JSONValue]

    private enum CodingKeys: String, CodingKey {
        case clientID, endpoint, model, workspaceID, extraBody
    }

    public init(
        clientID: AgentClientID,
        endpoint: URL? = nil,
        model: String? = nil,
        workspaceID: String? = nil,
        secret: String? = nil,
        extraBody: [String: JSONValue] = [:]
    ) {
        self.clientID = clientID
        self.endpoint = endpoint
        self.model = model
        self.workspaceID = workspaceID
        self.secret = secret
        self.extraBody = extraBody
    }
}

/// Stable UI and capability metadata for a registered client factory.
public struct AgentClientDescriptor: Sendable, Codable, Hashable, Identifiable {
    public let id: AgentClientID
    public let displayName: String
    public let provider: AgentProvider
    public let capabilities: AgentCapabilities

    public init(
        id: AgentClientID,
        displayName: String,
        provider: AgentProvider,
        capabilities: AgentCapabilities
    ) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.capabilities = capabilities
    }
}

/// Creates one configured client. The factory owns provider-specific decoding
/// and validation; the host only supplies generic configuration plus a secret.
public protocol AgentClientFactory: Sendable {
    var descriptor: AgentClientDescriptor { get }
    func makeClient(configuration: AgentClientConfiguration) throws -> any AgentClient
}

public enum AgentClientRegistryError: Error, LocalizedError, Sendable, Equatable {
    case duplicateClient(AgentClientID)
    case clientNotRegistered(AgentClientID)
    case configurationMismatch(expected: AgentClientID, actual: AgentClientID)

    public var errorDescription: String? {
        switch self {
        case .duplicateClient(let id): "Client \(id) is already registered."
        case .clientNotRegistered(let id): "Client \(id) is not registered."
        case .configurationMismatch(let expected, let actual):
            "Configuration is for \(actual), but the factory creates \(expected)."
        }
    }
}

/// The host-facing extension point for agent clients.
///
/// Registration is actor-isolated so an app can discover and install clients
/// from settings without racing an active session. Existing clients remain
/// value types; the registry only owns factories and creates a fresh client on
/// demand.
public actor AgentClientRegistry {
    private var factories: [AgentClientID: any AgentClientFactory] = [:]

    public init() {}

    public init(factories: [any AgentClientFactory]) throws {
        for factory in factories {
            let id = factory.descriptor.id
            guard self.factories[id] == nil else {
                throw AgentClientRegistryError.duplicateClient(id)
            }
            self.factories[id] = factory
        }
    }

    public func register(_ factory: any AgentClientFactory) throws {
        let id = factory.descriptor.id
        guard factories[id] == nil else {
            throw AgentClientRegistryError.duplicateClient(id)
        }
        factories[id] = factory
    }

    public func replace(_ factory: any AgentClientFactory) {
        factories[factory.descriptor.id] = factory
    }

    @discardableResult
    public func remove(_ id: AgentClientID) -> Bool {
        factories.removeValue(forKey: id) != nil
    }

    public func descriptors() -> [AgentClientDescriptor] {
        factories.values
            .map(\.descriptor)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func descriptor(for id: AgentClientID) -> AgentClientDescriptor? {
        factories[id]?.descriptor
    }

    public func makeClient(
        id: AgentClientID,
        configuration: AgentClientConfiguration
    ) throws -> any AgentClient {
        guard let factory = factories[id] else {
            throw AgentClientRegistryError.clientNotRegistered(id)
        }
        guard configuration.clientID == id else {
            throw AgentClientRegistryError.configurationMismatch(
                expected: id,
                actual: configuration.clientID
            )
        }
        return try factory.makeClient(configuration: configuration)
    }
}
