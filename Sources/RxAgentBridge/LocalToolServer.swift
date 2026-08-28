#if os(macOS)
import Foundation
import RxAgentContext
import RxAgentCore

/// Exposes the SDK's Swift tools to an external CLI agent as an MCP server.
///
/// This is what makes `Agent(tools: [.tool(MyTool())])` mean anything for a
/// CLI-backed client: the agent is a separate process, so a local closure can
/// only reach it over a protocol it already speaks. MCP is that protocol.
///
/// Transport is **HTTP** by default. RxCode bridged the agent's stdio to a TCP
/// socket with a `perl` one-liner (chosen over `nc`, which closes the write side
/// on stdin EOF in some builds) — but perl has been on macOS's deprecation list
/// for years, and every agent here understands HTTP MCP. The stdio bridge
/// remains available via ``bridgeCommandOverride`` for agents that need it.
public actor LocalToolServer {
    public static let shared = LocalToolServer()

    /// Server name the agent sees; tools appear as `mcp__<name>__<tool>`.
    public static let serverName = "rxagent-tools"

    /// Substitute a stdio bridge command for agents that don't support HTTP MCP.
    /// Receives the bound port.
    public var bridgeCommandOverride: (@Sendable (UInt16) -> LocalToolServerHandle.BridgeCommand)?

    private let server = LoopbackHTTPServer()
    private let secret = UUID().uuidString
    private var toolsByThread: [AgentThreadID: [String: AnyAgentTool]] = [:]
    private var contextsByThread: [AgentThreadID: AgentToolContext] = [:]

    public init() {}

    // MARK: - Lifecycle

    /// Publish `tools` for a thread and return the handle a client puts in its
    /// MCP config. Returns `nil` when there are no tools to serve.
    public func publish(
        tools: [AnyAgentTool],
        for threadID: AgentThreadID,
        context: AgentToolContext
    ) async throws -> LocalToolServerHandle? {
        guard !tools.isEmpty else { return nil }

        let port = try await start()
        toolsByThread[threadID] = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        contextsByThread[threadID] = context

        let url = URL(string: "http://127.0.0.1:\(port)/mcp/\(secret)/\(threadID.rawValue.uuidString)")!
        return LocalToolServerHandle(
            name: Self.serverName,
            httpURL: url,
            stdioBridge: bridgeCommandOverride?(port)
        )
    }

    public func withdraw(threadID: AgentThreadID) {
        toolsByThread.removeValue(forKey: threadID)
        contextsByThread.removeValue(forKey: threadID)
    }

    @discardableResult
    private func start() async throws -> UInt16 {
        if let port = await server.port { return port }
        try await server.start(portRange: 19847...19946) { [weak self] request in
            guard let self else { return .notFound }
            return await self.handle(request)
        }
        guard let port = await server.port else {
            throw AgentError.protocolViolation("tool server failed to bind")
        }
        return port
    }

    public func stop() async {
        await server.stop()
    }

    // MARK: - MCP dispatch

    private func handle(_ request: LoopbackHTTPServer.Request) async -> LoopbackHTTPServer.Response {
        let components = request.path.split(separator: "/").map(String.init)
        guard components.count == 3,
              components[0] == "mcp",
              components[1] == secret,
              let uuid = UUID(uuidString: components[2])
        else { return .notFound }

        let threadID = AgentThreadID(uuid)
        guard let message = JSONValue(jsonString: request.bodyString) else {
            return .json(string: Self.errorResponse(id: .null, code: -32700, message: "Parse error"))
        }

        let id = message["id"] ?? .null
        let method = message["method"]?.stringValue ?? ""
        let params = message["params"] ?? .object([:])

        // Notifications carry no id and expect no body.
        if message["id"] == nil || id.isNull {
            return .noContent
        }

        switch method {
        case "initialize":
            return .json(string: Self.result(id: id, value: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object([
                    "name": .string(Self.serverName),
                    "version": .string("1.0.0"),
                ]),
            ])))

        case "tools/list":
            let tools = (toolsByThread[threadID] ?? [:]).values
                .sorted { $0.name < $1.name }
                .map(Self.descriptor)
            return .json(string: Self.result(id: id, value: .object(["tools": .array(tools)])))

        case "tools/call":
            return await callTool(params: params, threadID: threadID, id: id)

        case "ping":
            return .json(string: Self.result(id: id, value: .object([:])))

        default:
            return .json(string: Self.errorResponse(
                id: id, code: -32601, message: "Method not found: \(method)"
            ))
        }
    }

    private func callTool(
        params: JSONValue,
        threadID: AgentThreadID,
        id: JSONValue
    ) async -> LoopbackHTTPServer.Response {
        guard let name = params["name"]?.stringValue else {
            return .json(string: Self.errorResponse(id: id, code: -32602, message: "Missing tool name"))
        }
        guard let tool = toolsByThread[threadID]?[name] else {
            return .json(string: Self.errorResponse(
                id: id, code: -32602, message: "Unknown tool: \(name)"
            ))
        }

        let context = contextsByThread[threadID] ?? AgentToolContext(
            threadID: threadID,
            workingDirectory: URL(filePath: FileManager.default.currentDirectoryPath)
        )
        let result = await tool.call(params["arguments"] ?? .object([:]), context: context)

        // MCP reports tool-level failures inside a successful response, via
        // `isError` — a JSON-RPC error would mean the *call* was malformed.
        return .json(string: Self.result(id: id, value: .object([
            "content": .array([.object([
                "type": .string("text"),
                "text": .string(result.content),
            ])]),
            "isError": .bool(result.isError),
        ])))
    }

    // MARK: - Encoding

    static func descriptor(for tool: AnyAgentTool) -> JSONValue {
        var descriptor: [String: JSONValue] = [
            "name": .string(tool.name),
            "description": .string(tool.description),
            "inputSchema": tool.inputSchema,
        ]

        var annotations: [String: JSONValue] = [:]
        if let title = tool.annotations.title { annotations["title"] = .string(title) }
        if let hint = tool.annotations.readOnlyHint { annotations["readOnlyHint"] = .bool(hint) }
        if let hint = tool.annotations.destructiveHint { annotations["destructiveHint"] = .bool(hint) }
        if let hint = tool.annotations.idempotentHint { annotations["idempotentHint"] = .bool(hint) }
        if !annotations.isEmpty { descriptor["annotations"] = .object(annotations) }

        return .object(descriptor)
    }

    static func result(id: JSONValue, value: JSONValue) -> String {
        JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": value]).jsonString
    }

    static func errorResponse(id: JSONValue, code: Int, message: String) -> String {
        JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .number(Double(code)), "message": .string(message)]),
        ]).jsonString
    }
}
#endif
