import Foundation
import RxAgentCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Conversation

/// One message in an OpenAI-shaped conversation.
///
/// Modelled as a struct with optional fields rather than an enum per role
/// because the wire format is exactly that: a `tool` message carries
/// `tool_call_id`, an `assistant` message may carry `tool_calls`, and a `user`
/// message may carry either a string or an array of parts. An enum would have to
/// be flattened back into this shape on every encode.
public struct OpenAIMessage: Sendable, Equatable {
    public enum Part: Sendable, Equatable {
        case text(String)
        /// A `data:` URL or an http(s) URL.
        case imageURL(String)
    }

    public var role: String
    public var text: String?
    public var parts: [Part]?
    public var toolCalls: [OpenAIToolCall]
    public var toolCallID: String?
    public var name: String?
    /// Marks a prompt-cache breakpoint for gateways that honour one.
    public var cacheControl: Bool

    public init(
        role: String,
        text: String? = nil,
        parts: [Part]? = nil,
        toolCalls: [OpenAIToolCall] = [],
        toolCallID: String? = nil,
        name: String? = nil,
        cacheControl: Bool = false
    ) {
        self.role = role
        self.text = text
        self.parts = parts
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
        self.cacheControl = cacheControl
    }

    func encoded() -> JSONValue {
        var fields: [String: JSONValue] = ["role": .string(role)]

        if let parts {
            fields["content"] = .array(parts.map { part in
                switch part {
                case .text(let value):
                    .object(["type": .string("text"), "text": .string(value)])
                case .imageURL(let url):
                    .object([
                        "type": .string("image_url"),
                        "image_url": .object(["url": .string(url)]),
                    ])
                }
            })
        } else if cacheControl, let text {
            // Anthropic-style cache breakpoints only exist on the parts form, so
            // a cached message has to be encoded as a one-part array even though
            // it is plain text.
            fields["content"] = .array([.object([
                "type": .string("text"),
                "text": .string(text),
                "cache_control": .object(["type": .string("ephemeral")]),
            ])])
        } else {
            fields["content"] = text.map(JSONValue.string) ?? .null
        }

        if !toolCalls.isEmpty {
            fields["tool_calls"] = .array(toolCalls.map { call in
                .object([
                    "id": .string(call.id),
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(call.name),
                        "arguments": .string(call.argumentsJSON),
                    ]),
                ])
            })
        }
        if let toolCallID { fields["tool_call_id"] = .string(toolCallID) }
        if let name { fields["name"] = .string(name) }

        return .object(fields)
    }
}

public struct OpenAIToolCall: Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }

    public var arguments: JSONValue {
        JSONValue(jsonString: argumentsJSON) ?? .object([:])
    }
}

/// What one round of the loop got back.
public struct OpenAITurn: Sendable {
    public var text: String
    public var toolCalls: [OpenAIToolCall]
    public var usage: UsageInfo?
    public var finishReason: String?
}

// MARK: - Errors

public enum OpenAIChatError: Error, CustomStringConvertible {
    case missingEndpoint
    case missingModel
    case http(status: Int, body: String)
    case transport(String)
    case malformed(String)
    case maxIterationsExceeded(Int)

    public var description: String {
        switch self {
        case .missingEndpoint:
            "No endpoint is configured for this model."
        case .missingModel:
            "No model is selected."
        case .http(let status, let body):
            "The model endpoint returned HTTP \(status)."
                + (body.isEmpty ? "" : "\n\(String(body.prefix(600)))")
        case .transport(let detail):
            "Could not reach the model endpoint: \(detail)"
        case .malformed(let detail):
            "The model's reply couldn't be read: \(detail)"
        case .maxIterationsExceeded(let limit):
            "The agent stopped after \(limit) rounds of tool calls without finishing."
        }
    }

    /// Whether asking again with a smaller prompt could plausibly work.
    ///
    /// The distinction that matters to a long batch job: a request that overran
    /// the window is worth splitting, an endpoint with the wrong API key is not.
    public var isWorthRetryingSmaller: Bool {
        switch self {
        case .http(let status, let body):
            status == 413 || status == 429 || (500...599).contains(status)
                || Self.mentionsContextLimit(body)
        case .malformed, .transport:
            true
        case .missingEndpoint, .missingModel, .maxIterationsExceeded:
            false
        }
    }

    /// Matched on wording because there is no interoperable code for it: OpenAI
    /// says `context_length_exceeded`, Anthropic "prompt is too long", and the
    /// gateways in between paraphrase both.
    public static func mentionsContextLimit(_ message: String) -> Bool {
        let text = message.lowercased()
        return [
            "context length", "context_length", "context window", "maximum context",
            "too many tokens", "prompt is too long", "request too large",
            "input is too long", "reduce the length",
        ]
        .contains { text.contains($0) }
    }
}

// MARK: - Transport

/// One round-trip against an OpenAI-compatible `/chat/completions` endpoint.
///
/// Streaming and non-streaming are both here because the two differ only in how
/// the same turn is assembled: streaming emits text as it arrives and stitches
/// tool-call argument fragments by index, non-streaming reads one JSON body.
/// Callers pick with `stream`.
enum OpenAIChatTransport {

    static func send(
        messages: [OpenAIMessage],
        tools: [AgentToolSurface.Entry],
        endpoint: URL,
        headers: [String: String],
        model: String,
        extraBody: [String: JSONValue],
        stream: Bool,
        session: URLSession,
        unaryTransport: (@Sendable (Data) async throws -> Data)? = nil,
        onTextDelta: @Sendable (String) -> Void
    ) async throws -> OpenAITurn {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(messages.map { $0.encoded() }),
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { tool in
                .object([
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": tool.inputSchema,
                    ]),
                ])
            })
            body["tool_choice"] = .string("auto")
        }
        if stream {
            body["stream"] = .bool(true)
            body["stream_options"] = .object(["include_usage": .bool(true)])
        }
        for (key, value) in extraBody { body[key] = value }

        let encoded = Data(JSONValue.object(body).jsonString.utf8)

        // The host's own stack answers, if it offered to. Nothing below this
        // point runs in that case — not the URL, not the headers.
        if let unaryTransport {
            let data: Data
            do {
                data = try await unaryTransport(encoded)
            } catch {
                throw OpenAIChatError.transport(String(describing: error))
            }
            return try decodeUnary(data, onTextDelta: onTextDelta)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(stream ? "text/event-stream" : "application/json",
                         forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = encoded

        return stream
            ? try await streamed(request, session: session, onTextDelta: onTextDelta)
            : try await unary(request, session: session, onTextDelta: onTextDelta)
    }

    // MARK: Non-streaming

    private static func unary(
        _ request: URLRequest,
        session: URLSession,
        onTextDelta: @Sendable (String) -> Void
    ) async throws -> OpenAITurn {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OpenAIChatError.transport(String(describing: error))
        }
        try check(response, data: data)
        return try decodeUnary(data, onTextDelta: onTextDelta)
    }

    /// Decodes a complete (non-streamed) chat completion.
    ///
    /// Shared by the built-in transport and a host-supplied one, so a hosted
    /// gateway gets exactly the same parsing — including the single synthetic
    /// text "delta" that makes the UI path identical either way.
    static func decodeUnary(
        _ data: Data,
        onTextDelta: @Sendable (String) -> Void
    ) throws -> OpenAITurn {
        guard let value = JSONValue(jsonString: String(decoding: data, as: UTF8.self)) else {
            throw OpenAIChatError.malformed("response was not JSON")
        }
        if let message = value["error"]?["message"]?.stringValue {
            throw OpenAIChatError.malformed(message)
        }

        let message = value["choices"]?[0]?["message"] ?? .object([:])
        let text = message["content"]?.stringValue ?? ""
        if !text.isEmpty { onTextDelta(text) }

        var calls: [OpenAIToolCall] = []
        if case .array(let raw)? = message["tool_calls"] {
            for (index, entry) in raw.enumerated() {
                let function = entry["function"] ?? .object([:])
                calls.append(OpenAIToolCall(
                    id: entry["id"]?.stringValue ?? "call_\(index)",
                    name: function["name"]?.stringValue ?? "",
                    argumentsJSON: function["arguments"]?.stringValue ?? "{}"
                ))
            }
        }

        return OpenAITurn(
            text: text,
            toolCalls: calls,
            usage: usage(from: value["usage"]),
            finishReason: value["choices"]?[0]?["finish_reason"]?.stringValue
        )
    }

    // MARK: Streaming

    private static func streamed(
        _ request: URLRequest,
        session: URLSession,
        onTextDelta: @Sendable (String) -> Void
    ) async throws -> OpenAITurn {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw OpenAIChatError.transport(String(describing: error))
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // The body is the useful half of an error and it is still on the
            // wire, so drain it before reporting the status.
            var body = ""
            for try await line in bytes.lines { body += line }
            throw OpenAIChatError.http(status: http.statusCode, body: body)
        }

        var text = ""
        var usageInfo: UsageInfo?
        var finishReason: String?
        /// Tool calls arrive as fragments keyed by `index`, so they have to be
        /// stitched positionally — `id` and `name` land on the first fragment
        /// only, and `arguments` dribbles in across all of them.
        var partials: [Int: (id: String, name: String, arguments: String)] = [:]

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty else { continue }
            guard payload != "[DONE]" else { break }
            guard let chunk = JSONValue(jsonString: payload) else { continue }

            if let message = chunk["error"]?["message"]?.stringValue {
                throw OpenAIChatError.malformed(message)
            }
            if let reported = usage(from: chunk["usage"]) { usageInfo = reported }

            let choice = chunk["choices"]?[0]
            if let reason = choice?["finish_reason"]?.stringValue { finishReason = reason }

            guard let delta = choice?["delta"] else { continue }

            if let fragment = delta["content"]?.stringValue, !fragment.isEmpty {
                text += fragment
                onTextDelta(fragment)
            }

            if case .array(let calls)? = delta["tool_calls"] {
                for call in calls {
                    let index = call["index"]?.intValue ?? 0
                    var partial = partials[index] ?? (id: "", name: "", arguments: "")
                    if let id = call["id"]?.stringValue, !id.isEmpty { partial.id = id }
                    if let function = call["function"] {
                        if let name = function["name"]?.stringValue, !name.isEmpty {
                            partial.name = name
                        }
                        if let arguments = function["arguments"]?.stringValue {
                            partial.arguments += arguments
                        }
                    }
                    partials[index] = partial
                }
            }
        }

        let toolCalls = partials
            .sorted { $0.key < $1.key }
            .map { index, partial in
                OpenAIToolCall(
                    id: partial.id.isEmpty ? "call_\(index)" : partial.id,
                    name: partial.name,
                    argumentsJSON: partial.arguments.isEmpty ? "{}" : partial.arguments
                )
            }

        return OpenAITurn(
            text: text,
            toolCalls: toolCalls,
            usage: usageInfo,
            finishReason: finishReason
        )
    }

    // MARK: Helpers

    private static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw OpenAIChatError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
    }

    static func usage(from value: JSONValue?) -> UsageInfo? {
        guard let value, !value.isNull else { return nil }
        let cached = value["prompt_tokens_details"]?["cached_tokens"]?.intValue ?? 0
        return UsageInfo(
            inputTokens: value["prompt_tokens"]?.intValue ?? 0,
            outputTokens: value["completion_tokens"]?.intValue ?? 0,
            cacheReadTokens: cached,
            cacheCreationTokens: value["cache_creation_input_tokens"]?.intValue ?? 0,
            totalCostUSD: value["cost"]?.numberValue
        )
    }
}
