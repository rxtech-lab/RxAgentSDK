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

    /// Codex config overrides, one `-c` pair per server.
    ///
    /// Two rules learned the hard way:
    ///
    /// 1. The value must be a **complete inline table**. A partial override
    ///    fails validation unless the server already exists in
    ///    `~/.codex/config.toml`, which we can't assume.
    /// 2. A bare `enabled=false` fails with "invalid transport" — a disabled
    ///    server must still declare its transport, so we simply omit it instead.
    public static func codexOverrides(
        servers: [MCPServerSpec],
        toolServer: LocalToolServerHandle?
    ) -> [String] {
        var overrides: [String] = []

        for server in servers where server.enabled {
            guard let table = codexInlineTable(for: server.transport) else { continue }
            overrides += ["-c", "mcp_servers.\(tomlKey(server.name))=\(table)"]
        }

        if let toolServer {
            let table = "{ url = \(tomlString(toolServer.httpURL.absoluteString)) }"
            overrides += ["-c", "mcp_servers.\(tomlKey(toolServer.name))=\(table)"]
        }

        return overrides
    }

    private static func codexInlineTable(for transport: MCPServerSpec.Transport) -> String? {
        switch transport {
        case .stdio(let command, let args, let env):
            var fields = ["command = \(tomlString(command))"]
            fields.append("args = \(tomlArray(args))")
            if !env.isEmpty {
                let pairs = env.map { "\(tomlKey($0.key)) = \(tomlString($0.value))" }
                fields.append("env = { \(pairs.sorted().joined(separator: ", ")) }")
            }
            return "{ \(fields.joined(separator: ", ")) }"

        case .http(let url, _), .sse(let url, _):
            return "{ url = \(tomlString(url.absoluteString)) }"
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
