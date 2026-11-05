import Foundation
import RxAgentCore

/// Credentials and config are minted by the host server. No embedded provider key is required.
public struct GeminiVoiceConnectionInfo: Sendable {
    public let url: URL
    public let protocols: [String]
    public let config: JSONValue
    public init(url: URL, protocols: [String] = [], config: JSONValue) {
        self.url = url; self.protocols = protocols; self.config = config
    }
}
/// Chippy/AI Gateway normalized Gemini wire protocol (not the native Gemini protocol).
public struct GeminiVoiceEngine: VoiceEngine {
    public let displayName = "Gemini"
    public let capabilities = VoiceEngineCapabilities()
    private let credentials: @Sendable () async throws -> GeminiVoiceConnectionInfo
    public init(connection: @escaping @Sendable () async throws -> GeminiVoiceConnectionInfo) { credentials = connection }
    public func readiness() async -> VoiceEngineReadiness { .ready }
    public func connect(_ config: VoiceSessionConfig) async throws -> any VoiceConnection {
        let info = try await credentials()
        let connection = GeminiVoiceConnection(info: info)
        do { try await connection.start(); return connection }
        catch { await connection.close(); throw error }
    }
}
private actor GeminiVoiceConnection: VoiceConnection {
    nonisolated let inputFormat = VoicePCMFormat(sampleRate: 16_000)
    nonisolated let events: AsyncStream<VoiceEngineEvent>
    private let output: AsyncStream<VoiceEngineEvent>.Continuation
    private let socket: URLSessionWebSocketTask
    private let config: JSONValue
    private var reader: Task<Void, Never>?
    private var closed = false
    private var itemID = UUID().uuidString
    private var toolNames: [String: String] = [:]
    init(info: GeminiVoiceConnectionInfo) {
        socket = URLSession.shared.webSocketTask(with: info.url, protocols: info.protocols)
        socket.maximumMessageSize = 2 * 1024 * 1024
        config = info.config
        (events, output) = AsyncStream.makeStream()
    }
    func start() async throws {
        socket.resume()
        try await write(["type": .string("session-update"), "config": config])
        reader = Task { [weak self, socket] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: continue
                    }
                    try await self?.receive(JSONDecoder().decode(JSONValue.self, from: data))
                }
            } catch { await self?.failed(error) }
        }
    }
    private func write(_ value: [String: JSONValue]) async throws {
        guard !closed else { throw VoiceError.invalidState }
        let data = try JSONEncoder().encode(value)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    func send(audio: VoiceAudioFrame) async throws {
        guard audio.format == inputFormat else { throw VoiceError.invalidAudio }
        try await write(["type": .string("input-audio-append"), "audio": .string(audio.data.base64EncodedString())])
    }
    func send(text: String) async throws {
        throw VoiceError.unavailable("This Gemini gateway supports microphone input only")
    }
    func interrupt(_ interruption: VoiceInterruption) async throws { /* Provider VAD cancels; session flushes playback. */ }
    func submitToolResult(callID: String, result: AgentToolResult) async throws {
        try await write(["type": .string("conversation-item-create"), "item": .object([
            "type": .string("function-call-output"), "callId": .string(callID), "name": .string(toolNames.removeValue(forKey: callID) ?? ""), "output": .string(result.content)
        ])])
    }
    private func receive(_ value: JSONValue) throws {
        if case .array(let events) = value {
            for event in events { try receive(event) }
            return
        }
        let text = value["delta"]?.stringValue ?? ""
        switch value["type"]?.stringValue {
        case "session-created", "session-updated", "session-started": output.yield(.ready)
        case "speech-started": output.yield(.userSpeechStarted)
        case "response-created": itemID = UUID().uuidString
        case "audio-delta", "audio-chunk":
            guard let data = Data(base64Encoded: text) else { throw VoiceError.invalidAudio }
            output.yield(.assistantAudio(itemID: itemID, try .init(data: data, format: .init())))
        case "audio-transcript-delta", "text-delta": output.yield(.assistantText(itemID: itemID, delta: text))
        case "input-transcription-completed":
            output.yield(.userTranscript(itemID: value["itemId"]?.stringValue, text: value["transcript"]?.stringValue ?? "", isFinal: true))
        case "response-done": output.yield(.assistantDone(itemID: itemID))
        case "function-call-arguments-done":
            guard let id = value["callId"]?.stringValue, let name = value["name"]?.stringValue,
                  let arguments = value["arguments"]?.stringValue else { throw VoiceError.transport("Malformed tool call") }
            let input = try JSONDecoder().decode([String: JSONValue].self, from: Data(arguments.utf8))
            toolNames[id] = name
            output.yield(.toolCallRequested(id: id, name: name, input: input))
        case "custom":
            if value["raw"]?["serverContent"]?["interrupted"] == .bool(true) { output.yield(.userSpeechStarted) }
        case "session-closed": output.yield(.closed(reason: nil)); output.finish()
        case "error": output.yield(.failed(.transport(value["message"]?.stringValue ?? "Gemini connection failed")))
        default: break
        }
    }
    private func failed(_ error: Error) {
        if !closed { output.yield(.failed(.transport(String(describing: error)))); output.finish() }
    }
    func close() async {
        guard !closed else { return }; closed = true
        reader?.cancel(); reader = nil
        socket.cancel(with: .normalClosure, reason: nil); output.finish()
    }
}
