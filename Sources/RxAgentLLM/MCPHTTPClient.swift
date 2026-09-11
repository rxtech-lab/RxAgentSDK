import Foundation
import RxAgentCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A JSON-RPC client for a remote MCP server reachable over HTTP.
///
/// The mirror image of `RxAgentBridge.LocalToolServer`: that one *publishes* the
/// host's Swift tools so an external CLI can call them, this one *consumes* an
/// external server's tools so an in-process model can call them. A CLI client
/// never needs this — it is handed a config file and does its own MCP — but an
/// in-process client has no agent process to delegate to, so speaking MCP is on
/// the SDK.
///
/// Implements the parts of Streamable HTTP the SDK actually uses: `initialize`,
/// the `notifications/initialized` follow-up, `tools/list` and `tools/call`.
/// Responses are accepted as either `application/json` or `text/event-stream`,
/// because servers differ on which they send for a unary call and the spec
/// permits both.
public actor MCPHTTPClient {
    public struct RemoteTool: Sendable, Hashable {
        public let name: String
        public let description: String
        public let inputSchema: JSONValue
    }

    public enum Failure: Error, CustomStringConvertible {
        case transport(String)
        case httpStatus(Int, body: String)
        case rpc(code: Int, message: String)
        case malformedResponse(String)

        public var description: String {
            switch self {
            case .transport(let detail): "MCP transport error: \(detail)"
            case .httpStatus(let code, let body):
                "MCP server returned HTTP \(code)" + (body.isEmpty ? "" : ": \(body)")
            case .rpc(let code, let message): "MCP error \(code): \(message)"
            case .malformedResponse(let detail): "Malformed MCP response: \(detail)"
            }
        }
    }

    private let endpoint: URL
    private let headers: [String: String]
    private let session: URLSession

    /// Server-assigned id echoed back on every later request, when the server
    /// issues one. Absent for servers that keep no session.
    private var mcpSessionID: String?
    private var didInitialize = false
    private var nextID = 1

    public init(endpoint: URL, headers: [String: String] = [:], timeout: TimeInterval = 120) {
        self.endpoint = endpoint
        self.headers = headers
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Handshake

    /// Performs `initialize` once per client. Subsequent calls are no-ops.
    public func initializeIfNeeded() async throws {
        guard !didInitialize else { return }

        _ = try await call(method: "initialize", params: .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object(["tools": .object([:])]),
            "clientInfo": .object([
                "name": .string("RxAgentSDK"),
                "version": .string("1.0.0"),
            ]),
        ]))

        // A notification, so there is no reply to wait for and a server that
        // ignores it is still conformant. Failing the turn over it would be
        // wrong — the handshake already succeeded.
        try? await notify(method: "notifications/initialized", params: .object([:]))
        didInitialize = true
    }

    // MARK: - Tools

    public func listTools() async throws -> [RemoteTool] {
        try await initializeIfNeeded()

        var tools: [RemoteTool] = []
        var cursor: String?

        repeat {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await call(method: "tools/list", params: .object(params))

            guard case .array(let entries)? = result["tools"] else {
                throw Failure.malformedResponse("tools/list had no `tools` array")
            }
            for entry in entries {
                guard let name = entry["name"]?.stringValue else { continue }
                tools.append(RemoteTool(
                    name: name,
                    description: entry["description"]?.stringValue ?? "",
                    inputSchema: entry["inputSchema"] ?? .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                    ])
                ))
            }
            cursor = result["nextCursor"]?.stringValue
        } while cursor != nil

        return tools
    }

    /// Calls a tool and returns its content blocks verbatim.
    ///
    /// Returns the raw `result` object rather than flattened text because an MCP
    /// tool result can carry images, and the caller needs them intact — this is
    /// the path by which a model actually sees a rendered frame.
    public func callTool(name: String, arguments: JSONValue) async throws -> JSONValue {
        try await initializeIfNeeded()
        return try await call(method: "tools/call", params: .object([
            "name": .string(name),
            "arguments": arguments,
        ]))
    }

    // MARK: - Transport

    private func call(method: String, params: JSONValue) async throws -> JSONValue {
        let id = nextID
        nextID += 1

        let body = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ])

        let data = try await post(body)
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw Failure.malformedResponse("empty body for \(method)")
        }
        guard let message = Self.decodeMessage(text) else {
            throw Failure.malformedResponse("could not parse response to \(method)")
        }
        if let error = message["error"] {
            throw Failure.rpc(
                code: error["code"]?.intValue ?? -1,
                message: error["message"]?.stringValue ?? "unknown error"
            )
        }
        return message["result"] ?? .object([:])
    }

    private func notify(method: String, params: JSONValue) async throws {
        _ = try await post(.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ]))
    }

    private func post(_ body: JSONValue) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Declaring both is what tells a Streamable HTTP server it may answer
        // either way; servers reject a POST that accepts only one of them.
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let mcpSessionID {
            request.setValue(mcpSessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = Data(body.jsonString.utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else { return data }

        if let issued = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !issued.isEmpty {
            mcpSessionID = issued
        }
        guard (200...299).contains(http.statusCode) else {
            throw Failure.httpStatus(
                http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return data
    }

    /// Reads a JSON-RPC message out of either a bare JSON body or an SSE stream.
    ///
    /// For a unary call the SSE form carries the reply in the last `data:` line,
    /// so scanning for the final parseable one is both correct and tolerant of
    /// the keep-alive comments servers interleave.
    static func decodeMessage(_ text: String) -> JSONValue? {
        if let direct = JSONValue(jsonString: text), direct["jsonrpc"] != nil || direct["result"] != nil {
            return direct
        }

        var latest: JSONValue?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]" else { continue }
            if let value = JSONValue(jsonString: payload) { latest = value }
        }
        return latest ?? JSONValue(jsonString: text)
    }
}
