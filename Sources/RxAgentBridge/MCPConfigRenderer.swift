#if os(macOS)
import Foundation
import RxAgentCore

/// Renders MCP server declarations into each provider's config dialect.
///
/// The three CLIs accept the same information in three incompatible formats,
/// and each has at least one non-obvious rule that took real debugging to find.
/// Those rules are documented at their call sites — do not "simplify" them.
public enum MCPConfigRenderer {

    // MARK: - Claude: `--mcp-config` JSON

    /// A `mcpServers` map, passed via `--strict-mcp-config --mcp-config <path>`.
    public static func claudeConfigJSON(
        servers: [MCPServerSpec],
        toolServer: LocalToolServerHandle?
    ) -> String {
        var entries: [String: JSONValue] = [:]

        for server in servers where server.enabled {
            entries[server.name] = claudeEntry(for: server.transport)
        }

        if let toolServer {
            entries[toolServer.name] = .object([
                "type": .string("http"),
                "url": .string(toolServer.httpURL.absoluteString),
            ])
        }

        return JSONValue.object(["mcpServers": .object(entries)]).jsonString
    }

    private static func claudeEntry(for transport: MCPServerSpec.Transport) -> JSONValue {
        switch transport {
        case .stdio(let command, let args, let env):
            var entry: [String: JSONValue] = [
                "type": .string("stdio"),
                "command": .string(command),
                "args": .array(args.map(JSONValue.string)),
            ]
            if !env.isEmpty { entry["env"] = .object(env.mapValues(JSONValue.string)) }
            return .object(entry)

        case .http(let url, let headers):
            var entry: [String: JSONValue] = [
                "type": .string("http"),
                "url": .string(url.absoluteString),
            ]
            if !headers.isEmpty { entry["headers"] = .object(headers.mapValues(JSONValue.string)) }
            return .object(entry)

        case .sse(let url, let headers):
            var entry: [String: JSONValue] = [
                "type": .string("sse"),
                "url": .string(url.absoluteString),
            ]
            if !headers.isEmpty { entry["headers"] = .object(headers.mapValues(JSONValue.string)) }
            return .object(entry)
        }
    }

    // MARK: - Codex: `-c mcp_servers.<name>={…}` TOML

    /// A Codex invocation's MCP wiring: the `-c` overrides, and the environment
    /// those overrides refer to.
    ///
    /// The environment exists because of `bearer_token_env_var`. Codex reads an
    /// HTTP server's credential from a *named environment variable* rather than
    /// from the config value, so a rendered override alone is not enough — the
    /// caller has to put the token in the child's environment under the name the
    /// override cites. Returning both together is what keeps the two in step.
    public struct CodexMCPConfiguration: Sendable, Equatable {
        public let overrides: [String]
        public let environment: [String: String]

        public init(overrides: [String], environment: [String: String]) {
            self.overrides = overrides
            self.environment = environment
        }
    }

    /// Codex config overrides, one `-c` pair per server.
    ///
    /// Rules learned the hard way:
    ///
    /// 1. The value must be a **complete inline table**. A partial override
    ///    fails validation unless the server already exists in
    ///    `~/.codex/config.toml`, which we can't assume.
    /// 2. A bare `enabled=false` fails with "invalid transport" — a disabled
    ///    server must still declare its transport, so we simply omit it instead.
    /// 3. `Authorization` is **not** a plain header here. Codex owns that header
    ///    for HTTP MCP servers and expects the token via `bearer_token_env_var`;
    ///    passing it through `http_headers` gets it overwritten or duplicated.
    ///    Routing it through the environment also keeps the token out of `ps`,
    ///    which every `-c` value is visible in.
    public static func codexConfiguration(
        servers: [MCPServerSpec],
        toolServer: LocalToolServerHandle?
    ) -> CodexMCPConfiguration {
        var overrides: [String] = []
        var environment: [String: String] = [:]

        for server in servers where server.enabled {
            guard let rendered = codexInlineTable(for: server.transport, name: server.name)
            else { continue }
            overrides += ["-c", "mcp_servers.\(tomlKey(server.name))=\(rendered.table)"]
            environment.merge(rendered.environment) { _, new in new }
        }

        if let toolServer {
            let table = "{ url = \(tomlString(toolServer.httpURL.absoluteString)) }"
            overrides += ["-c", "mcp_servers.\(tomlKey(toolServer.name))=\(table)"]
        }

        return CodexMCPConfiguration(overrides: overrides, environment: environment)
    }

    /// Back-compatible shape for callers that only want the `-c` pairs.
    ///
    /// Prefer ``codexConfiguration(servers:toolServer:)`` — a server with an
    /// `Authorization` header will not authenticate through this one, because
    /// the environment half of the pair is dropped.
    public static func codexOverrides(
        servers: [MCPServerSpec],
        toolServer: LocalToolServerHandle?
    ) -> [String] {
        codexConfiguration(servers: servers, toolServer: toolServer).overrides
    }

    private struct RenderedCodexServer {
        var table: String
        var environment: [String: String]
    }

    /// Environment variable name carrying `server`'s bearer token.
    ///
    /// Namespaced and upper-cased so two servers cannot collide, and so the name
    /// is a legal shell identifier whatever the server was called.
    static func codexTokenEnvironmentKey(for name: String) -> String {
        let sanitized = name.map { character -> Character in
            character.isLetter || character.isNumber ? character : "_"
        }
        return "RXAGENT_MCP_TOKEN_" + String(sanitized).uppercased()
    }

    private static func codexInlineTable(
        for transport: MCPServerSpec.Transport,
        name: String
    ) -> RenderedCodexServer? {
        switch transport {
        case .stdio(let command, let args, let env):
            var fields = ["command = \(tomlString(command))"]
            fields.append("args = \(tomlArray(args))")
            if !env.isEmpty {
                let pairs = env.map { "\(tomlKey($0.key)) = \(tomlString($0.value))" }
                fields.append("env = { \(pairs.sorted().joined(separator: ", ")) }")
            }
            return RenderedCodexServer(
                table: "{ \(fields.joined(separator: ", ")) }",
                environment: [:]
            )

        case .http(let url, let headers), .sse(let url, let headers):
            var fields = ["url = \(tomlString(url.absoluteString))"]
            var environment: [String: String] = [:]

            // Authorization goes through the env var channel; see rule 3 above.
            var passthrough = headers
            if let authorization = passthrough.removeValue(forKey: "Authorization") {
                let token = authorization.hasPrefix("Bearer ")
                    ? String(authorization.dropFirst("Bearer ".count))
                    : authorization
                let key = codexTokenEnvironmentKey(for: name)
                environment[key] = token
                fields.append("bearer_token_env_var = \(tomlString(key))")
            }

            if !passthrough.isEmpty {
                let pairs = passthrough
                    .map { "\(tomlKey($0.key)) = \(tomlString($0.value))" }
                    .sorted()
                fields.append("http_headers = { \(pairs.joined(separator: ", ")) }")
            }

            return RenderedCodexServer(
                table: "{ \(fields.joined(separator: ", ")) }",
                environment: environment
            )
        }
    }

    // MARK: - ACP: `session/new` `mcpServers` array

    /// The `mcpServers` payload for ACP's `session/new`.
    ///
    /// **A stdio entry must NOT carry a `"type": "stdio"` field.** Stdio is the
    /// default member of the union in the ACP schema, and naming it explicitly
    /// makes conforming agents reject the whole request. HTTP and SSE entries do
    /// need their type, and are only sent when the agent advertised support.
    public static func acpServers(
        servers: [MCPServerSpec],
        toolServer: LocalToolServerHandle?,
        supportsHTTP: Bool,
        supportsSSE: Bool
    ) -> [JSONValue] {
        var entries: [JSONValue] = []

        for server in servers where server.enabled {
            switch server.transport {
            case .stdio(let command, let args, let env):
                entries.append(.object([
                    "name": .string(server.name),
                    "command": .string(command),
                    "args": .array(args.map(JSONValue.string)),
                    "env": .array(env.map { key, value in
                        .object(["name": .string(key), "value": .string(value)])
                    }),
                ]))

            case .http(let url, let headers):
                guard supportsHTTP else { continue }
                entries.append(.object([
                    "type": .string("http"),
                    "name": .string(server.name),
                    "url": .string(url.absoluteString),
                    "headers": .object(headers.mapValues(JSONValue.string)),
                ]))

            case .sse(let url, let headers):
                guard supportsSSE else { continue }
                entries.append(.object([
                    "type": .string("sse"),
                    "name": .string(server.name),
                    "url": .string(url.absoluteString),
                    "headers": .object(headers.mapValues(JSONValue.string)),
                ]))
            }
        }

        if let toolServer {
            if supportsHTTP {
                entries.append(.object([
                    "type": .string("http"),
                    "name": .string(toolServer.name),
                    "url": .string(toolServer.httpURL.absoluteString),
                    "headers": .object([:]),
                ]))
            } else if let bridge = toolServer.stdioBridge {
                // No explicit "type" — see the doc comment above.
                entries.append(.object([
                    "name": .string(toolServer.name),
                    "command": .string(bridge.command),
                    "args": .array(bridge.args.map(JSONValue.string)),
                    "env": .array([]),
                ]))
            }
        }

        return entries
    }

    // MARK: - TOML escaping

    static func tomlString(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    static func tomlArray(_ values: [String]) -> String {
        "[\(values.map(tomlString).joined(separator: ", "))]"
    }

    /// Bare keys are only legal for `[A-Za-z0-9_-]`; anything else must be quoted.
    static func tomlKey(_ key: String) -> String {
        let isBare = !key.isEmpty && key.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-"
        }
        return isBare ? key : tomlString(key)
    }
}
#endif
