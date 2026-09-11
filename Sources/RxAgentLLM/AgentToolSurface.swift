import Foundation
import RxAgentCore

/// Everything an in-process client may call this turn, from wherever it comes.
///
/// A CLI client never needs this type: it hands the agent process a config file
/// and the agent does its own discovery. An in-process client *is* the agent, so
/// something has to unify the host's Swift closures with the tools of every
/// declared MCP server, apply the turn's allow/deny lists, and dispatch by name.
/// That is this.
///
/// Local tools win a name collision. A host that declared a tool in Swift meant
/// that one, and a remote server renaming itself into a local tool's name must
/// not silently take over the call.
public actor AgentToolSurface {

    public struct Entry: Sendable {
        public let name: String
        public let description: String
        public let inputSchema: JSONValue
    }

    /// A tool result, still carrying any images the tool produced.
    public struct Outcome: Sendable {
        public var text: String
        /// `data:` URLs, ready to be attached to a follow-up user message.
        public var images: [String]
        public var isError: Bool

        public init(text: String, images: [String] = [], isError: Bool = false) {
            self.text = text
            self.images = images
            self.isError = isError
        }
    }

    private let localTools: [String: AnyAgentTool]
    private let toolContext: AgentToolContext
    private let permits: @Sendable (String) -> Bool

    /// Remote servers, in declaration order, with the tool names each advertised.
    private var remotes: [(client: MCPHTTPClient, names: Set<String>)] = []
    private var remoteEntries: [Entry] = []
    private var didDiscover = false

    private let servers: [MCPServerSpec]
    private let toolServer: LocalToolServerHandle?

    public init(request: AgentSendRequest) {
        self.localTools = Dictionary(
            request.localTools.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.toolContext = request.toolContext
        self.permits = { request.permitsTool(named: $0) }
        self.servers = request.mcpServers
        // An in-process client reaches the host's Swift tools through
        // `localTools` directly, so the loopback MCP server it also published is
        // redundant here — connecting to it would expose every tool twice under
        // two names. It is only carried so a caller can inspect it.
        self.toolServer = request.toolServer
        _ = self.toolServer
    }

    // MARK: - Discovery

    /// Connects to every declared HTTP/SSE MCP server and caches its tool list.
    ///
    /// A server that fails to answer is skipped with a diagnostic rather than
    /// failing the turn: one unreachable server should cost its own tools, not
    /// the user's request.
    @discardableResult
    public func discover() async -> [AgentDiagnostic] {
        guard !didDiscover else { return [] }
        didDiscover = true

        var diagnostics: [AgentDiagnostic] = []

        for server in servers where server.enabled {
            let endpoint: URL
            let headers: [String: String]

            switch server.transport {
            case .http(let url, let serverHeaders), .sse(let url, let serverHeaders):
                endpoint = url
                headers = serverHeaders
            case .stdio:
                // Spawning is the CLI layer's job and is macOS-only; an
                // in-process client that is meant to run on iOS cannot reach a
                // stdio server. Say so rather than failing mysteriously.
                diagnostics.append(AgentDiagnostic(
                    level: .warning,
                    client: "in-process",
                    message: "MCP server `\(server.name)` uses stdio, which in-process "
                        + "clients cannot reach. Expose it over HTTP to use it here."
                ))
                continue
            }

            let client = MCPHTTPClient(endpoint: endpoint, headers: headers)
            do {
                let tools = try await client.listTools()
                var names: Set<String> = []
                for tool in tools where permits(tool.name) && localTools[tool.name] == nil {
                    names.insert(tool.name)
                    remoteEntries.append(Entry(
                        name: tool.name,
                        description: tool.description,
                        inputSchema: tool.inputSchema
                    ))
                }
                remotes.append((client, names))
            } catch {
                diagnostics.append(AgentDiagnostic(
                    level: .warning,
                    client: "in-process",
                    message: "MCP server `\(server.name)` is unreachable: \(error)"
                ))
            }
        }

        return diagnostics
    }

    /// Every callable tool, local first, ready to be advertised to a model.
    public func entries() async -> [Entry] {
        await discover()
        let local = localTools.values
            .filter { permits($0.name) }
            .sorted { $0.name < $1.name }
            .map { Entry(name: $0.name, description: $0.description, inputSchema: $0.inputSchema) }
        return local + remoteEntries
    }

    // MARK: - Dispatch

    /// Runs a tool by name.
    ///
    /// A name the turn does not permit is reported back to the model as a tool
    /// *error* rather than thrown. The model chose it — possibly hallucinated it
    /// — and telling it so in-band lets it correct itself, whereas throwing ends
    /// a turn the user asked for.
    public func call(name: String, arguments: JSONValue) async -> Outcome {
        guard permits(name) else {
            return Outcome(
                text: "`\(name)` is not available in this conversation.",
                isError: true
            )
        }

        if let tool = localTools[name] {
            let result = await tool.call(arguments, context: toolContext)
            return Outcome(text: result.content, isError: result.isError)
        }

        await discover()
        guard let remote = remotes.first(where: { $0.names.contains(name) }) else {
            return Outcome(text: "Unknown tool `\(name)`.", isError: true)
        }

        do {
            let result = try await remote.client.callTool(name: name, arguments: arguments)
            return Self.outcome(from: result)
        } catch {
            return Outcome(text: "\(name) failed: \(error)", isError: true)
        }
    }

    // MARK: - Result decoding

    /// Splits an MCP `tools/call` result into text, images, and an error flag.
    ///
    /// `structuredContent` wins over the text blocks when both are present: the
    /// structured form is what the tool *means*, the text blocks are its
    /// rendering for a human, and a model reads the former more reliably.
    static func outcome(from result: JSONValue) -> Outcome {
        var texts: [String] = []
        var images: [String] = []

        if case .array(let blocks)? = result["content"] {
            for block in blocks {
                switch block["type"]?.stringValue {
                case "text":
                    if let text = block["text"]?.stringValue { texts.append(text) }
                case "image":
                    guard let data = block["data"]?.stringValue, !data.isEmpty else { continue }
                    let mime = block["mimeType"]?.stringValue ?? "image/png"
                    images.append("data:\(mime);base64,\(data)")
                default:
                    continue
                }
            }
        }

        var text = texts.joined(separator: "\n")
        if let structured = result["structuredContent"] {
            text = structured.jsonString
        }

        let isError = result["isError"]?.boolValue ?? false
        if text.isEmpty {
            text = isError ? #"{"ok":false}"# : #"{"ok":true}"#
        }

        return Outcome(text: text, images: images, isError: isError)
    }
}
