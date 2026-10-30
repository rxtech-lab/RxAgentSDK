import Foundation
import RxAgentCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Mode

/// How a model call delivers its answer.
///
/// - `streaming`: deltas arrive as the model writes them. What a chat UI wants.
/// - `generation`: one request, one complete response. Cheaper on servers that
///   buffer anyway, and the only option some local runtimes support reliably
///   together with tool calling.
public enum HarnessGenerationMode: String, Sendable, Codable, CaseIterable {
    case streaming
    case generation
}

// MARK: - Request / response

/// A tool as the model is told about it.
public struct HarnessToolSpec: Sendable, Hashable {
    public let name: String
    public let description: String
    public let parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct HarnessModelRequest: Sendable {
    public var model: String
    public var system: String
    public var messages: [HarnessMessage]
    public var tools: [HarnessToolSpec]
    public var mode: HarnessGenerationMode
    public var maxOutputTokens: Int?
    public var temperature: Double?

    public init(
        model: String,
        system: String,
        messages: [HarnessMessage],
        tools: [HarnessToolSpec] = [],
        mode: HarnessGenerationMode = .streaming,
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil
    ) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.mode = mode
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
    }
}

/// Pieces of a model response, in arrival order.
///
/// In `.generation` mode a conformer may yield the whole text as one
/// `textDelta`; the harness treats both modes identically past this point.
public enum HarnessModelChunk: Sendable, Hashable {
    case textDelta(String)
    case reasoningDelta(String)
    /// Emitted once per call, complete. Conformers stitch streamed argument
    /// fragments themselves.
    case toolCall(HarnessToolCall)
    case usage(UsageInfo)
    case finished(reason: String?)
}

public enum HarnessModelError: Error, Sendable, Equatable, CustomStringConvertible {
    case http(status: Int, body: String)
    case transport(String)
    case malformed(String)
    /// The server rejected the request as longer than its context window.
    case contextOverflow(String)
    case unavailable(String)

    public var description: String {
        switch self {
        case .http(let status, let body): "Model server returned HTTP \(status): \(body.prefix(500))"
        case .transport(let detail): "Could not reach the model server: \(detail)"
        case .malformed(let detail): "Unexpected model response: \(detail)"
        case .contextOverflow(let detail): "The conversation no longer fits the model's context window. \(detail)"
        case .unavailable(let detail): detail
        }
    }

    /// Whether `body` is a provider's way of saying the prompt was too long.
    /// Spellings collected from llama.cpp, Ollama, LM Studio, vLLM and OpenAI.
    public static func mentionsContextOverflow(_ body: String) -> Bool {
        let lowered = body.lowercased()
        return [
            "context length", "context window", "maximum context", "exceeds the available context",
            "context_length_exceeded", "too many tokens", "prompt is too long", "n_ctx",
            "exceed_context_size", "input is too long",
        ].contains { lowered.contains($0) }
    }
}

// MARK: - Model protocol

/// Something that can answer a conversation, optionally with tool calls.
///
/// The harness's only dependency on inference. The bundled conformer speaks the
/// OpenAI `/chat/completions` dialect, which llama.cpp's `llama-server`, Ollama,
/// LM Studio, vLLM and MLX servers all implement — so a local model is just a
/// different `baseURL`. A host running inference in-process (MLX, Core ML)
/// conforms its own type instead.
public protocol HarnessModel: Sendable {
    /// Total tokens the model can attend to, prompt plus output. Drives
    /// automatic compaction; `nil` means unknown, and compaction falls back to
    /// reacting to overflow errors.
    var contextWindow: Int? { get }

    func send(_ request: HarnessModelRequest) -> AsyncThrowingStream<HarnessModelChunk, Error>
}

// MARK: - OpenAI-compatible model

/// A `/chat/completions` endpoint — local or remote.
public struct OpenAICompatibleHarnessModel: HarnessModel {
    public var baseURL: URL
    public var contextWindow: Int?
    public var headers: @Sendable () async -> [String: String]
    /// Extra top-level request fields (`top_p`, `repeat_penalty`, …).
    public var extraBody: [String: JSONValue]
    public var timeout: TimeInterval

    public init(
        baseURL: URL,
        contextWindow: Int? = nil,
        extraBody: [String: JSONValue] = [:],
        timeout: TimeInterval = 600,
        headers: @escaping @Sendable () async -> [String: String] = { [:] }
    ) {
        self.baseURL = baseURL
        self.contextWindow = contextWindow
        self.extraBody = extraBody
        self.timeout = timeout
        self.headers = headers
    }

    public func send(_ request: HarnessModelRequest) -> AsyncThrowingStream<HarnessModelChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await perform(request, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    var completionsURL: URL {
        let path = baseURL.path
        if path.hasSuffix("/chat/completions") { return baseURL }
        return baseURL.appending(path: "chat/completions")
    }

    // MARK: Encoding

    static func encodeMessages(system: String, messages: [HarnessMessage]) -> [JSONValue] {
        var encoded: [JSONValue] = []
        if !system.isEmpty {
            encoded.append(["role": "system", "content": .string(system)])
        }
        for message in messages {
            switch message.role {
            case .system:
                encoded.append(["role": "system", "content": .string(message.text)])
            case .user:
                if message.images.isEmpty {
                    encoded.append(["role": "user", "content": .string(message.text)])
                } else {
                    var parts: [JSONValue] = []
                    if !message.text.isEmpty {
                        parts.append(["type": "text", "text": .string(message.text)])
                    }
                    for image in message.images {
                        parts.append(["type": "image_url", "image_url": ["url": .string(image.dataURL)]])
                    }
                    encoded.append(["role": "user", "content": .array(parts)])
                }
            case .assistant:
                var fields: [String: JSONValue] = ["role": "assistant"]
                fields["content"] = message.text.isEmpty && !message.toolCalls.isEmpty
                    ? .null : .string(message.text)
                if !message.toolCalls.isEmpty {
                    fields["tool_calls"] = .array(message.toolCalls.map { call in
                        [
                            "id": .string(call.id),
                            "type": "function",
                            "function": [
                                "name": .string(call.name),
                                // Servers re-parse this; an invalid string would
                                // fail the whole request, so normalize it.
                                "arguments": .string(call.arguments?.jsonString ?? "{}"),
                            ],
                        ]
                    })
                }
                encoded.append(.object(fields))
            case .tool:
                encoded.append([
                    "role": "tool",
                    "tool_call_id": .string(message.toolCallID ?? ""),
                    "content": .string(message.text),
                ])
            }
        }
        return encoded
    }

    func body(for request: HarnessModelRequest) -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(Self.encodeMessages(system: request.system, messages: request.messages)),
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": tool.parameters,
                    ],
                ]
            })
            body["tool_choice"] = "auto"
        }
        if let maxOutputTokens = request.maxOutputTokens { body["max_tokens"] = .number(Double(maxOutputTokens)) }
        if let temperature = request.temperature { body["temperature"] = .number(temperature) }
        if request.mode == .streaming {
            body["stream"] = true
            body["stream_options"] = ["include_usage": true]
        } else {
            body["stream"] = false
        }
        for (key, value) in extraBody { body[key] = value }
        return body
    }

    // MARK: Transport

    private func perform(
        _ request: HarnessModelRequest,
        continuation: AsyncThrowingStream<HarnessModelChunk, Error>.Continuation
    ) async throws {
        var urlRequest = URLRequest(url: completionsURL, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(
            request.mode == .streaming ? "text/event-stream" : "application/json",
            forHTTPHeaderField: "Accept"
        )
        for (key, value) in await headers() { urlRequest.setValue(value, forHTTPHeaderField: key) }
        urlRequest.httpBody = Data(JSONValue.object(body(for: request)).jsonString.utf8)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 4
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        if request.mode == .generation {
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: urlRequest)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw HarnessModelError.transport(error.localizedDescription)
            }
            try Self.check(response, body: String(data: data, encoding: .utf8) ?? "")
            guard let json = JSONValue(jsonString: String(data: data, encoding: .utf8) ?? "") else {
                throw HarnessModelError.malformed("Response was not JSON.")
            }
            for chunk in try Self.decodeUnary(json) { continuation.yield(chunk) }
            return
        }

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HarnessModelError.transport(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            var body = ""
            for try await line in bytes.lines { body += line }
            try Self.check(response, body: body)
        }

        var decoder = StreamDecoder()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let (chunks, done) = try decoder.consume(line: line)
            for chunk in chunks { continuation.yield(chunk) }
            if done { break }
        }
        for chunk in decoder.finish() { continuation.yield(chunk) }
    }

    static func check(_ response: URLResponse, body: String) throws {
        guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else { return }
        if HarnessModelError.mentionsContextOverflow(body) {
            throw HarnessModelError.contextOverflow(String(body.prefix(300)))
        }
        throw HarnessModelError.http(status: http.statusCode, body: body)
    }

    static func usage(from value: JSONValue?) -> UsageInfo? {
        guard let value, !value.isNull, value.objectValue != nil else { return nil }
        return UsageInfo(
            inputTokens: value["prompt_tokens"]?.intValue ?? 0,
            outputTokens: value["completion_tokens"]?.intValue ?? 0,
            cacheReadTokens: value["prompt_tokens_details"]?["cached_tokens"]?.intValue ?? 0,
            cacheCreationTokens: 0,
            totalCostUSD: value["cost"]?.numberValue
        )
    }

    static func decodeUnary(_ json: JSONValue) throws -> [HarnessModelChunk] {
        if let message = json["error"]?["message"]?.stringValue {
            if HarnessModelError.mentionsContextOverflow(message) {
                throw HarnessModelError.contextOverflow(message)
            }
            throw HarnessModelError.malformed(message)
        }
        guard let choice = json["choices"]?[0] else {
            throw HarnessModelError.malformed("No choices in response.")
        }
        var chunks: [HarnessModelChunk] = []
        let message = choice["message"]
        if let reasoning = (message?["reasoning_content"] ?? message?["reasoning"])?.stringValue,
           !reasoning.isEmpty {
            chunks.append(.reasoningDelta(reasoning))
        }
        let content = message?["content"]?.stringValue ?? ""
        let (visible, thinking) = ThinkTagSplitter.split(content)
        if !thinking.isEmpty { chunks.append(.reasoningDelta(thinking)) }
        if !visible.isEmpty { chunks.append(.textDelta(visible)) }
        for (index, call) in (message?["tool_calls"]?.arrayValue ?? []).enumerated() {
            let function = call["function"]
            let arguments: String = switch function?["arguments"] {
            case .string(let text)?: text
            case let other?: other.jsonString
            case nil: "{}"
            }
            chunks.append(.toolCall(HarnessToolCall(
                id: call["id"]?.stringValue ?? "call_\(index)",
                name: function?["name"]?.stringValue ?? "",
                argumentsJSON: arguments
            )))
        }
        if let usage = usage(from: json["usage"]) { chunks.append(.usage(usage)) }
        chunks.append(.finished(reason: choice["finish_reason"]?.stringValue))
        return chunks
    }

    /// Server-Sent Events decoder for streamed completions. A value type so it
    /// can be unit-tested line by line.
    struct StreamDecoder {
        private var partials: [Int: (id: String, name: String, arguments: String)] = [:]
        private var finishReason: String?
        private var usage: UsageInfo?
        private var thinkSplitter = ThinkTagSplitter()

        /// Returns chunks ready to emit, and whether the stream signalled the end.
        mutating func consume(line: String) throws -> ([HarnessModelChunk], Bool) {
            guard line.hasPrefix("data:") else { return ([], false) }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { return ([], false) }
            if payload == "[DONE]" { return ([], true) }
            guard let json = JSONValue(jsonString: payload) else { return ([], false) }
            if let message = json["error"]?["message"]?.stringValue {
                if HarnessModelError.mentionsContextOverflow(message) {
                    throw HarnessModelError.contextOverflow(message)
                }
                throw HarnessModelError.malformed(message)
            }
            if let reported = OpenAICompatibleHarnessModel.usage(from: json["usage"]) { usage = reported }
            let choice = json["choices"]?[0]
            if let reason = choice?["finish_reason"]?.stringValue { finishReason = reason }
            guard let delta = choice?["delta"] else { return ([], false) }

            var chunks: [HarnessModelChunk] = []
            if let reasoning = (delta["reasoning_content"] ?? delta["reasoning"])?.stringValue,
               !reasoning.isEmpty {
                chunks.append(.reasoningDelta(reasoning))
            }
            if let content = delta["content"]?.stringValue, !content.isEmpty {
                for piece in thinkSplitter.feed(content) {
                    switch piece {
                    case .visible(let text): chunks.append(.textDelta(text))
                    case .thinking(let text): chunks.append(.reasoningDelta(text))
                    }
                }
            }
            for call in delta["tool_calls"]?.arrayValue ?? [] {
                let index = call["index"]?.intValue ?? 0
                var partial = partials[index] ?? (id: "", name: "", arguments: "")
                if let id = call["id"]?.stringValue, !id.isEmpty { partial.id = id }
                if let name = call["function"]?["name"]?.stringValue, !name.isEmpty { partial.name = name }
                if let arguments = call["function"]?["arguments"]?.stringValue { partial.arguments += arguments }
                partials[index] = partial
            }
            return (chunks, false)
        }

        mutating func finish() -> [HarnessModelChunk] {
            var chunks: [HarnessModelChunk] = []
            for piece in thinkSplitter.flush() {
                switch piece {
                case .visible(let text): chunks.append(.textDelta(text))
                case .thinking(let text): chunks.append(.reasoningDelta(text))
                }
            }
            for (index, partial) in partials.sorted(by: { $0.key < $1.key }) where !partial.name.isEmpty {
                chunks.append(.toolCall(HarnessToolCall(
                    id: partial.id.isEmpty ? "call_\(index)" : partial.id,
                    name: partial.name,
                    argumentsJSON: partial.arguments.isEmpty ? "{}" : partial.arguments
                )))
            }
            if let usage { chunks.append(.usage(usage)) }
            chunks.append(.finished(reason: finishReason))
            return chunks
        }
    }
}

// MARK: - <think> splitting

/// Separates `<think>…</think>` spans from visible text.
///
/// Many open-weight reasoning models (Qwen, DeepSeek-R1 distills) write their
/// reasoning inline in `content` when the server is not configured to split it
/// into `reasoning_content`. Showing it as the answer is wrong, and replaying it
/// wastes context, so it is routed to reasoning instead. Streaming-safe: a tag
/// split across two deltas is held back until it can be recognized.
struct ThinkTagSplitter {
    enum Piece: Equatable {
        case visible(String)
        case thinking(String)
    }

    private var buffer = ""
    private var inThink = false

    static func split(_ text: String) -> (visible: String, thinking: String) {
        var splitter = ThinkTagSplitter()
        var visible = ""
        var thinking = ""
        for piece in splitter.feed(text) + splitter.flush() {
            switch piece {
            case .visible(let text): visible += text
            case .thinking(let text): thinking += text
            }
        }
        return (visible.trimmingCharacters(in: .whitespacesAndNewlines), thinking)
    }

    mutating func feed(_ text: String) -> [Piece] {
        buffer += text
        var pieces: [Piece] = []
        while true {
            let tag = inThink ? "</think>" : "<think>"
            if let range = buffer.range(of: tag) {
                let before = String(buffer[..<range.lowerBound])
                if !before.isEmpty { pieces.append(inThink ? .thinking(before) : .visible(before)) }
                buffer = String(buffer[range.upperBound...])
                inThink.toggle()
                continue
            }
            // Hold back a suffix that could be the start of the tag.
            var keep = 0
            for length in stride(from: min(tag.count - 1, buffer.count), to: 0, by: -1)
                where tag.hasPrefix(String(buffer.suffix(length))) {
                keep = length
                break
            }
            let emit = String(buffer.dropLast(keep))
            if !emit.isEmpty { pieces.append(inThink ? .thinking(emit) : .visible(emit)) }
            buffer = String(buffer.suffix(keep))
            return pieces
        }
    }

    mutating func flush() -> [Piece] {
        defer { buffer = "" }
        guard !buffer.isEmpty else { return [] }
        return [inThink ? .thinking(buffer) : .visible(buffer)]
    }
}
