#if os(macOS)
import Foundation
import Testing
import RxAgentContext
import RxAgentCore
@testable import RxAgentBridge

// MARK: - Helpers

private func post(_ url: URL, body: String) async throws -> (Int, String) {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = Data(body.utf8)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 30
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    return (status, String(decoding: data, as: UTF8.self))
}

private struct RecordingResolver: PermissionResolving {
    let decision: PermissionDecision
    let seen: SeenBox

    final class SeenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [PermissionRequest] = []
        var requests: [PermissionRequest] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        func append(_ request: PermissionRequest) {
            lock.lock(); defer { lock.unlock() }
            storage.append(request)
        }
    }

    func resolve(_ request: PermissionRequest) async -> PermissionDecision {
        seen.append(request)
        return decision
    }
}

// MARK: - HTTP server

@Suite("LoopbackHTTPServer", .serialized)
struct LoopbackHTTPServerTests {

    @Test("Serves a request and returns the handler's response")
    func roundTrip() async throws {
        let server = LoopbackHTTPServer()
        try await server.start(portRange: 46100...46120) { request in
            .json(["echo": request.bodyString, "path": request.path])
        }
        defer { Task { await server.stop() } }

        let port = try #require(await server.port)
        let url = URL(string: "http://127.0.0.1:\(port)/hello")!
        let (status, body) = try await post(url, body: #"{"a":1}"#)

        #expect(status == 200)
        #expect(body.contains("/hello"))
        #expect(body.contains(#"{\"a\":1}"#))
    }

    /// The approval flow depends on this: the socket must stay open while a
    /// human decides.
    @Test("A slow handler holds the connection open")
    func slowHandler() async throws {
        let server = LoopbackHTTPServer()
        try await server.start(portRange: 46121...46140) { _ in
            try? await Task.sleep(for: .milliseconds(600))
            return .json(["decided": true])
        }
        defer { Task { await server.stop() } }

        let port = try #require(await server.port)
        let start = ContinuousClock.now
        let (status, body) = try await post(
            URL(string: "http://127.0.0.1:\(port)/slow")!, body: "{}"
        )

        #expect(status == 200)
        #expect(body.contains("decided"))
        #expect(ContinuousClock.now - start > .milliseconds(500))
    }

    @Test("Concurrent requests are served independently")
    func concurrentRequests() async throws {
        let server = LoopbackHTTPServer()
        try await server.start(portRange: 46141...46160) { request in
            try? await Task.sleep(for: .milliseconds(200))
            return .json(["path": request.path])
        }
        defer { Task { await server.stop() } }

        let port = try #require(await server.port)
        let bodies = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<4 {
                group.addTask {
                    try await post(URL(string: "http://127.0.0.1:\(port)/r\(index)")!, body: "{}").1
                }
            }
            var collected: [String] = []
            for try await body in group { collected.append(body) }
            return collected
        }

        #expect(bodies.count == 4)
        for index in 0..<4 {
            #expect(bodies.contains { $0.contains("/r\(index)") })
        }
    }
}

// MARK: - Approval server

@Suite("ApprovalServer", .serialized)
struct ApprovalServerTests {

    private func hookPayload(tool: String, input: String) -> String {
        #"{"tool_name":"\#(tool)","tool_use_id":"toolu_x","tool_input":\#(input)}"#
    }

    @Test("Hook settings JSON has the shape the CLI expects")
    func hookSettingsShape() async {
        let server = ApprovalServer()
        let json = await server.hookSettingsJSON(port: 19836, runToken: "tok")
        let value = try! #require(JSONValue(jsonString: json))

        let entry = try! #require(value["hooks"]?["PreToolUse"]?[0])
        #expect(entry["matcher"]?.stringValue == ApprovalServer.defaultMatcher)

        let hook = try! #require(entry["hooks"]?[0])
        #expect(hook["type"]?.stringValue == "http")
        #expect(hook["timeout"]?.intValue == 300)
        let url = try! #require(hook["url"]?.stringValue)
        #expect(url.hasPrefix("http://127.0.0.1:19836/hook/pre-tool-use/"))
        #expect(url.hasSuffix("/tok"))
    }

    @Test("An allow decision reaches the CLI as permissionDecision allow")
    func allowDecision() async throws {
        let server = ApprovalServer()
        let seen = RecordingResolver.SeenBox()
        let settings = try await server.register(
            runToken: "tok-allow",
            resolver: RecordingResolver(decision: .allow, seen: seen),
            mode: .default
        )
        defer { Task { await server.stop() } }

        let url = try #require(hookURL(from: settings))
        let (status, body) = try await post(
            url, body: hookPayload(tool: "Bash", input: #"{"command":"ls"}"#)
        )

        #expect(status == 200)
        let value = try #require(JSONValue(jsonString: body))
        #expect(value["hookSpecificOutput"]?["permissionDecision"]?.stringValue == "allow")

        #expect(seen.requests.count == 1)
        #expect(seen.requests.first?.toolName == "Bash")
        #expect(seen.requests.first?.command == "ls")
        #expect(seen.requests.first?.category == .execution)
    }

    @Test("A denial carries the reason back to the model")
    func denyWithReason() async throws {
        let server = ApprovalServer()
        let settings = try await server.register(
            runToken: "tok-deny",
            resolver: RecordingResolver(
                decision: .denyWithReason(reason: "Not in this directory."),
                seen: .init()
            ),
            mode: .default
        )
        defer { Task { await server.stop() } }

        let url = try #require(hookURL(from: settings))
        let (_, body) = try await post(
            url, body: hookPayload(tool: "Write", input: #"{"file_path":"/etc/hosts"}"#)
        )

        let output = try #require(JSONValue(jsonString: body)?["hookSpecificOutput"])
        #expect(output["permissionDecision"]?.stringValue == "deny")
        #expect(output["permissionDecisionReason"]?.stringValue == "Not in this directory.")
    }

    /// How an AskUserQuestion answer gets fed back into the pending call.
    @Test("allowWithInput rewrites the tool input")
    func allowWithUpdatedInput() async throws {
        let server = ApprovalServer()
        let settings = try await server.register(
            runToken: "tok-input",
            resolver: RecordingResolver(
                decision: .allowWithInput(.object(["answer": .string("Option B")])),
                seen: .init()
            ),
            mode: .default
        )
        defer { Task { await server.stop() } }

        let url = try #require(hookURL(from: settings))
        let (_, body) = try await post(
            url, body: hookPayload(tool: "AskUserQuestion", input: #"{"question":"which?"}"#)
        )

        let output = try #require(JSONValue(jsonString: body)?["hookSpecificOutput"])
        #expect(output["permissionDecision"]?.stringValue == "allow")
        #expect(output["updatedInput"]?["answer"]?.stringValue == "Option B")
    }

    /// A hook for a turn we've forgotten must not deadlock the agent.
    @Test("An unknown run token allows rather than hanging")
    func unknownRunToken() async throws {
        let server = ApprovalServer()
        let settings = try await server.register(
            runToken: "known",
            resolver: RecordingResolver(decision: .deny, seen: .init()),
            mode: .default
        )
        defer { Task { await server.stop() } }

        let known = try #require(hookURL(from: settings))
        let stale = known.deletingLastPathComponent().appending(path: "forgotten-token")
        let (_, body) = try await post(stale, body: hookPayload(tool: "Bash", input: "{}"))

        #expect(JSONValue(jsonString: body)?["hookSpecificOutput"]?["permissionDecision"]?
            .stringValue == "allow")
    }

    @Test("A wrong secret is rejected")
    func wrongSecret() async throws {
        let server = ApprovalServer()
        _ = try await server.register(
            runToken: "tok",
            resolver: RecordingResolver(decision: .allow, seen: .init()),
            mode: .default
        )
        defer { Task { await server.stop() } }

        let port = try #require(await server.port)
        let url = URL(string: "http://127.0.0.1:\(port)/hook/pre-tool-use/not-the-secret/tok")!
        let (status, _) = try await post(url, body: hookPayload(tool: "Bash", input: "{}"))
        #expect(status == 404)
    }

    private func hookURL(from settings: String) -> URL? {
        guard let value = JSONValue(jsonString: settings),
              let string = value["hooks"]?["PreToolUse"]?[0]?["hooks"]?[0]?["url"]?.stringValue
        else { return nil }
        return URL(string: string)
    }
}

// MARK: - Local tool server

@Suite("LocalToolServer", .serialized)
struct LocalToolServerTests {

    private func echoTool() -> AnyAgentTool {
        .dynamic(
            name: "echo",
            description: "Echo the input back.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["text": .object(["type": .string("string")])]),
                "required": .array([.string("text")]),
            ]),
            annotations: .readOnly
        ) { arguments, context in
            .text("\(arguments["text"]?.stringValue ?? "") @ \(context.workingDirectory.lastPathComponent)")
        }
    }

    private func failingTool() -> AnyAgentTool {
        .dynamic(name: "boom", description: "Always fails.", inputSchema: .object([:])) { _, _ in
            .error("kaboom")
        }
    }

    private func publish(_ tools: [AnyAgentTool]) async throws -> (LocalToolServer, URL, AgentThreadID) {
        let server = LocalToolServer()
        let threadID = AgentThreadID()
        let handle = try await server.publish(
            tools: tools,
            for: threadID,
            context: AgentToolContext(
                threadID: threadID,
                workingDirectory: URL(filePath: "/tmp/workspace")
            )
        )
        return (server, try #require(handle).httpURL, threadID)
    }

    @Test("initialize advertises tool capability")
    func initialize() async throws {
        let (server, url, _) = try await publish([echoTool()])
        defer { Task { await server.stop() } }

        let (_, body) = try await post(
            url, body: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        )
        let value = try #require(JSONValue(jsonString: body))
        #expect(value["result"]?["serverInfo"]?["name"]?.stringValue == LocalToolServer.serverName)
        #expect(value["result"]?["capabilities"]?["tools"] != nil)
    }

    @Test("tools/list returns name, description and JSON Schema")
    func toolsList() async throws {
        let (server, url, _) = try await publish([echoTool()])
        defer { Task { await server.stop() } }

        let (_, body) = try await post(
            url, body: #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#
        )
        let tools = try #require(JSONValue(jsonString: body)?["result"]?["tools"]?.arrayValue)

        #expect(tools.count == 1)
        #expect(tools[0]["name"]?.stringValue == "echo")
        #expect(tools[0]["description"]?.stringValue == "Echo the input back.")
        #expect(tools[0]["inputSchema"]?["type"]?.stringValue == "object")
        #expect(tools[0]["annotations"]?["readOnlyHint"]?.boolValue == true)
    }

    /// The end-to-end proof that a Swift closure is reachable from a separate
    /// process over MCP.
    @Test("tools/call invokes the Swift tool and returns its output")
    func toolsCall() async throws {
        let (server, url, _) = try await publish([echoTool()])
        defer { Task { await server.stop() } }

        let (_, body) = try await post(url, body: """
        {"jsonrpc":"2.0","id":3,"method":"tools/call",\
        "params":{"name":"echo","arguments":{"text":"hello"}}}
        """)
        let result = try #require(JSONValue(jsonString: body)?["result"])

        #expect(result["isError"]?.boolValue == false)
        #expect(result["content"]?[0]?["text"]?.stringValue == "hello @ workspace")
    }

    /// MCP reports tool failure inside a *successful* response; a JSON-RPC error
    /// would mean the call itself was malformed.
    @Test("A failing tool reports isError, not a JSON-RPC error")
    func failingToolReportsIsError() async throws {
        let (server, url, _) = try await publish([failingTool()])
        defer { Task { await server.stop() } }

        let (_, body) = try await post(url, body: """
        {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"boom","arguments":{}}}
        """)
        let value = try #require(JSONValue(jsonString: body))

        #expect(value["error"] == nil)
        #expect(value["result"]?["isError"]?.boolValue == true)
        #expect(value["result"]?["content"]?[0]?["text"]?.stringValue == "kaboom")
    }

    @Test("An unknown tool is a JSON-RPC error")
    func unknownTool() async throws {
        let (server, url, _) = try await publish([echoTool()])
        defer { Task { await server.stop() } }

        let (_, body) = try await post(url, body: """
        {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope","arguments":{}}}
        """)
        #expect(JSONValue(jsonString: body)?["error"]?["code"]?.intValue == -32602)
    }

    @Test("Publishing no tools yields no handle")
    func emptyToolsYieldsNoHandle() async throws {
        let server = LocalToolServer()
        let handle = try await server.publish(
            tools: [],
            for: AgentThreadID(),
            context: AgentToolContext(threadID: AgentThreadID(), workingDirectory: URL(filePath: "/tmp"))
        )
        #expect(handle == nil)
    }

    @Test("A withdrawn thread exposes no tools")
    func withdraw() async throws {
        let (server, url, threadID) = try await publish([echoTool()])
        defer { Task { await server.stop() } }

        await server.withdraw(threadID: threadID)
        let (_, body) = try await post(
            url, body: #"{"jsonrpc":"2.0","id":6,"method":"tools/list","params":{}}"#
        )
        #expect(JSONValue(jsonString: body)?["result"]?["tools"]?.arrayValue?.isEmpty == true)
    }
}

// MARK: - Config rendering

@Suite("MCPConfigRenderer")
struct MCPConfigRendererTests {

    private let stdioServer = MCPServerSpec.stdio(
        name: "files",
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
        env: ["TOKEN": "abc"]
    )
    private let httpServer = MCPServerSpec.http(
        name: "remote",
        url: URL(string: "https://example.com/mcp")!
    )
    private let toolServer = LocalToolServerHandle(
        name: "rxagent-tools",
        httpURL: URL(string: "http://127.0.0.1:19850/mcp/s/t")!
    )

    @Test("Claude config nests servers under mcpServers with explicit types")
    func claudeConfig() {
        let json = MCPConfigRenderer.claudeConfigJSON(
            servers: [stdioServer, httpServer],
            toolServer: toolServer
        )
        let servers = try! #require(JSONValue(jsonString: json)?["mcpServers"])

        #expect(servers["files"]?["type"]?.stringValue == "stdio")
        #expect(servers["files"]?["command"]?.stringValue == "npx")
        #expect(servers["files"]?["env"]?["TOKEN"]?.stringValue == "abc")
        #expect(servers["remote"]?["type"]?.stringValue == "http")
        #expect(servers["rxagent-tools"]?["url"]?.stringValue?.hasPrefix("http://127.0.0.1:") == true)
    }

    @Test("A disabled server is omitted")
    func disabledServerOmitted() {
        var disabled = stdioServer
        disabled.enabled = false
        let json = MCPConfigRenderer.claudeConfigJSON(servers: [disabled], toolServer: nil)
        #expect(JSONValue(jsonString: json)?["mcpServers"]?["files"] == nil)
    }

    /// A partial override fails Codex validation unless the server is already in
    /// `~/.codex/config.toml`, so every entry must be a complete inline table.
    @Test("Codex overrides emit complete inline tables")
    func codexOverrides() {
        let overrides = MCPConfigRenderer.codexOverrides(
            servers: [stdioServer],
            toolServer: toolServer
        )

        #expect(overrides.count == 4)
        #expect(overrides[0] == "-c")
        #expect(overrides[1].hasPrefix("mcp_servers.files={ command = \"npx\""))
        #expect(overrides[1].contains("args = [\"-y\""))
        #expect(overrides[1].contains("env = { TOKEN = \"abc\" }"))
        #expect(overrides[3].hasPrefix("mcp_servers.rxagent-tools={ url = "))
    }

    /// Codex owns the `Authorization` header for HTTP MCP servers and takes its
    /// value from a named environment variable. Rendering it as a plain header
    /// silently fails to authenticate, so the renderer has to split it out — and
    /// hand back the environment that the override now depends on.
    @Test("An HTTP server's bearer token is routed through an environment variable")
    func codexBearerToken() {
        let authenticated = MCPServerSpec.http(
            name: "film_workflow",
            url: URL(string: "http://127.0.0.1:8765/mcp")!,
            headers: [
                "Authorization": "Bearer s3cret",
                "X-RxFilm-Document": "DOC-1",
            ]
        )

        let configuration = MCPConfigRenderer.codexConfiguration(
            servers: [authenticated],
            toolServer: nil
        )
        let table = configuration.overrides[1]
        let key = MCPConfigRenderer.codexTokenEnvironmentKey(for: "film_workflow")

        #expect(table.contains("bearer_token_env_var = \"\(key)\""))
        #expect(configuration.environment[key] == "s3cret")
        // The token must not also appear inline — `-c` values show up in `ps`.
        #expect(!table.contains("s3cret"))

        // Every other header still travels as a header. `X-RxFilm-Document` is
        // a legal TOML bare key, so it renders unquoted; a header name that
        // isn't gets quoted by `tomlKey`.
        #expect(table.contains("http_headers = { X-RxFilm-Document = \"DOC-1\" }"))
        #expect(!table.contains("Authorization"))
    }

    @Test("An HTTP server with no headers renders just a url")
    func codexHTTPWithoutHeaders() {
        let configuration = MCPConfigRenderer.codexConfiguration(
            servers: [httpServer],
            toolServer: nil
        )
        #expect(configuration.overrides[1] == #"mcp_servers.remote={ url = "https://example.com/mcp" }"#)
        #expect(configuration.environment.isEmpty)
    }

    @Test("Token environment keys are legal identifiers and namespaced per server")
    func codexTokenKeys() {
        #expect(MCPConfigRenderer.codexTokenEnvironmentKey(for: "film_workflow")
            == "RXAGENT_MCP_TOKEN_FILM_WORKFLOW")
        // A hyphen is legal in a server name but not in a shell variable.
        #expect(MCPConfigRenderer.codexTokenEnvironmentKey(for: "rxagent-tools")
            == "RXAGENT_MCP_TOKEN_RXAGENT_TOOLS")
    }

    @Test("TOML strings and keys are escaped")
    func tomlEscaping() {
        #expect(MCPConfigRenderer.tomlString(#"a"b\c"#) == #""a\"b\\c""#)
        #expect(MCPConfigRenderer.tomlKey("plain-key_1") == "plain-key_1")
        #expect(MCPConfigRenderer.tomlKey("has space") == "\"has space\"")
    }

    /// Stdio is the default union member in ACP's schema; naming it explicitly
    /// makes conforming agents reject the request.
    @Test("ACP stdio entries carry no explicit type field")
    func acpStdioHasNoType() {
        let entries = MCPConfigRenderer.acpServers(
            servers: [stdioServer],
            toolServer: nil,
            supportsHTTP: false,
            supportsSSE: false
        )

        #expect(entries.count == 1)
        #expect(entries[0]["type"] == nil, "an explicit stdio type breaks conforming agents")
        #expect(entries[0]["name"]?.stringValue == "files")
        #expect(entries[0]["command"]?.stringValue == "npx")
        #expect(entries[0]["env"]?[0]?["name"]?.stringValue == "TOKEN")
    }

    @Test("ACP drops HTTP servers when the agent didn't advertise support")
    func acpFiltersUnsupportedTransports() {
        let unsupported = MCPConfigRenderer.acpServers(
            servers: [httpServer], toolServer: nil, supportsHTTP: false, supportsSSE: false
        )
        #expect(unsupported.isEmpty)

        let supported = MCPConfigRenderer.acpServers(
            servers: [httpServer], toolServer: nil, supportsHTTP: true, supportsSSE: false
        )
        #expect(supported.count == 1)
        #expect(supported[0]["type"]?.stringValue == "http")
    }

    @Test("Without HTTP support the tool server falls back to its stdio bridge")
    func acpToolServerFallsBackToBridge() {
        let bridged = LocalToolServerHandle(
            name: "rxagent-tools",
            httpURL: URL(string: "http://127.0.0.1:19850/mcp")!,
            stdioBridge: .init(command: "/usr/bin/socat", args: ["-", "TCP:127.0.0.1:19850"])
        )

        let entries = MCPConfigRenderer.acpServers(
            servers: [], toolServer: bridged, supportsHTTP: false, supportsSSE: false
        )
        #expect(entries.count == 1)
        #expect(entries[0]["type"] == nil)
        #expect(entries[0]["command"]?.stringValue == "/usr/bin/socat")
    }
}
#endif
