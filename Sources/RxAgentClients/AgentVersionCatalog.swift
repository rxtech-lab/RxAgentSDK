#if os(macOS)
import Foundation


/// Published versions for agent packages. The registry's current release is
/// still supplied by the caller when package metadata is unavailable.
public actor AgentVersionCatalog {
    public enum Source: Hashable, Sendable {
        case npm(String)
        case pypi(String)
    }

    public enum CatalogError: LocalizedError {
        case unsupportedDistribution
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .unsupportedDistribution:
                "This client does not publish selectable package versions."
            case .invalidResponse:
                "Could not load published versions."
            }
        }
    }

    public static let shared = AgentVersionCatalog()

    private var cache: [Source: (date: Date, versions: [String])] = [:]
    private var latestCache: [String: (date: Date, version: String)] = [:]
    private let cacheLifetime: TimeInterval = 3600

    /// Use npm's release tag rather than the highest published version, which
    /// may belong to a preview channel.
    public func latestVersion(for runtime: AgentRuntimeInstaller.Runtime, forceRefresh: Bool = false) async throws -> String {
        let package = runtime.package
        if !forceRefresh, let cached = latestCache[package],
           Date().timeIntervalSince(cached.date) < cacheLifetime {
            return cached.version
        }
        let url = try packageURL(base: "https://registry.npmjs.org", name: package, suffix: "latest")
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if forceRefresh { request.cachePolicy = .reloadIgnoringLocalCacheData }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String,
              Self.isValid(version), !version.contains("-")
        else { throw CatalogError.invalidResponse }
        latestCache[package] = (Date(), version)
        return version
    }

    public func versions(for runtime: AgentRuntimeInstaller.Runtime) async throws -> [String] {
        try await versions(from: .npm(runtime.package))
    }

    public func versions(from source: Source) async throws -> [String] {
        if let cached = cache[source], Date().timeIntervalSince(cached.date) < cacheLifetime {
            return cached.versions
        }

        let url: URL
        switch source {
        case .npm(let name):
            url = try packageURL(base: "https://registry.npmjs.org", name: name)
        case .pypi(let name):
            url = try packageURL(base: "https://pypi.org/pypi", name: name, suffix: "json")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if case .npm = source {
            request.setValue("application/vnd.npm.install-v1+json", forHTTPHeaderField: "Accept")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CatalogError.invalidResponse }

        let published: [String]
        switch source {
        case .npm:
            published = Array((object["versions"] as? [String: Any] ?? [:]).keys)
        case .pypi:
            published = Array((object["releases"] as? [String: Any] ?? [:]).keys)
        }
        let result = published
            .filter { Self.isValid($0) && !$0.contains("-") && !$0.contains("+") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        guard !result.isEmpty else { throw CatalogError.invalidResponse }
        cache[source] = (Date(), result)
        return result
    }

    private func packageURL(base: String, name: String, suffix: String? = nil) throws -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw CatalogError.invalidResponse
        }
        let path = suffix.map { "\(base)/\(encoded)/\($0)" } ?? "\(base)/\(encoded)"
        guard let url = URL(string: path) else { throw CatalogError.invalidResponse }
        return url
    }
    public static func isValid(_ version: String) -> Bool {
        version.range(
            of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?(?:\+[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$"#,
            options: .regularExpression
        ) != nil
    }

}

#endif
