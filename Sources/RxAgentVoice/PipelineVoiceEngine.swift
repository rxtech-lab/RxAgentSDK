import Foundation
import RxAgentCore

/// Implementations own utterance detection and emit final, nonempty utterances.
public protocol SpeechRecognizing: Sendable {
    var inputFormat: VoicePCMFormat { get }
    func start() async throws -> AsyncStream<String>
    func append(_ frame: VoiceAudioFrame) async throws
    func discard() async
    func stop() async
}
public protocol SpeechSynthesizing: Sendable {
    func synthesize(_ text: String) async throws -> AsyncThrowingStream<VoiceAudioFrame, Error>
    func cancelAll() async
}
public protocol VoiceResponder: Sendable {
    func respond(to text: String) async throws -> AsyncStream<AgentEvent>
    func cancel() async
}

/// The request factory supplies the host's thread, permissions, tools and history.
public actor AgentVoiceResponder: VoiceResponder {
    private let client: any AgentClient
    private let request: @Sendable (String) async throws -> AgentSendRequest
    private var turn: UUID?
    public init(client: any AgentClient, request: @escaping @Sendable (String) async throws -> AgentSendRequest) {
        self.client = client; self.request = request
    }
    public func respond(to text: String) async throws -> AsyncStream<AgentEvent> {
        await cancel()
        let value = try await request(text)
        turn = value.turnID
        return client.send(value)
    }
    public func cancel() async {
        let previous = turn; turn = nil
        if let previous { await client.cancel(turn: previous) }
    }
}
public struct PipelineVoiceEngine: VoiceEngine {
    public let displayName = "Local speech"
    public let capabilities = VoiceEngineCapabilities(canCancel: true, runsTools: true)
    private let recognizer: any SpeechRecognizing
    private let synthesizer: any SpeechSynthesizing
    private let responder: any VoiceResponder
    public init(recognizer: any SpeechRecognizing, synthesizer: any SpeechSynthesizing, responder: any VoiceResponder) {
        self.recognizer = recognizer; self.synthesizer = synthesizer; self.responder = responder
    }
    public func readiness() async -> VoiceEngineReadiness { .ready }
    public func connect(_ config: VoiceSessionConfig) async throws -> any VoiceConnection {
        let connection = PipelineVoiceConnection(recognizer: recognizer, synthesizer: synthesizer, responder: responder)
        try await connection.start()
        return connection
    }
}
private actor PipelineVoiceConnection: VoiceConnection {
    nonisolated let inputFormat: VoicePCMFormat
    nonisolated let events: AsyncStream<VoiceEngineEvent>
    private let output: AsyncStream<VoiceEngineEvent>.Continuation
    private let recognizer: any SpeechRecognizing
    private let synthesizer: any SpeechSynthesizing
    private let responder: any VoiceResponder
    private var recognition: Task<Void, Never>?
    private var response: Task<Void, Never>?
    private var revision = UUID()
    private var closed = false
    init(recognizer: any SpeechRecognizing, synthesizer: any SpeechSynthesizing, responder: any VoiceResponder) {
        self.recognizer = recognizer; self.synthesizer = synthesizer; self.responder = responder
        inputFormat = recognizer.inputFormat
        (events, output) = AsyncStream.makeStream()
    }
    func start() async throws {
        let utterances = try await recognizer.start()
        recognition = Task { [weak self] in
            for await text in utterances {
                guard !Task.isCancelled else { break }
                do { try await self?.send(text: text) }
                catch { await self?.failed(error) }
            }
        }
        output.yield(.ready)
    }
    func send(audio: VoiceAudioFrame) async throws {
        guard !closed else { throw VoiceError.invalidState }
        guard audio.format == inputFormat else { throw VoiceError.invalidAudio }
        try await recognizer.append(audio)
    }
    func send(text: String) async throws {
        guard !closed else { throw VoiceError.invalidState }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try await interrupt(.init(itemID: nil, heardDuration: .zero))
        guard !closed else { return }
        let token = UUID(); revision = token
        let id = UUID().uuidString
        output.yield(.userTranscript(itemID: UUID().uuidString, text: text, isFinal: true))
        response = Task { [weak self, responder, synthesizer] in
            do {
                let stream = try await responder.respond(to: text)
                var spoken = ""
                for await event in stream {
                    try Task.checkCancellation()
                    guard let self, await self.isCurrent(token) else { return }
                    if case .textDelta(let delta) = event {
                        spoken += delta
                        await self.emit(.assistantText(itemID: id, delta: delta))
                    } else if case .failed(let error) = event { throw error }
                    else { await self.emit(.toolActivity(event)) }
                }
                try Task.checkCancellation()
                if !spoken.isEmpty {
                    for try await frame in try await synthesizer.synthesize(spoken) {
                        try Task.checkCancellation()
                        guard let self, await self.isCurrent(token) else { return }
                        await self.emit(.assistantAudio(itemID: id, frame))
                    }
                }
                if let self, await self.isCurrent(token) { await self.emit(.assistantDone(itemID: id)) }
            } catch is CancellationError {} catch { await self?.failed(error) }
        }
    }
    private func isCurrent(_ token: UUID) -> Bool { !closed && revision == token }
    private func emit(_ event: VoiceEngineEvent) { output.yield(event) }
    private func failed(_ error: Error) { if !closed { output.yield(.failed(.transport(String(describing: error)))) } }
    func interrupt(_ interruption: VoiceInterruption) async throws {
        revision = UUID(); response?.cancel(); response = nil
        await responder.cancel(); await synthesizer.cancelAll(); await recognizer.discard()
    }
    func submitToolResult(callID: String, result: AgentToolResult) async throws {
        throw VoiceError.unavailable("The agent owns pipeline tools")
    }
    func close() async {
        guard !closed else { return }; closed = true
        recognition?.cancel(); recognition = nil
        try? await interrupt(.init(itemID: nil, heardDuration: .zero))
        await recognizer.stop(); output.finish()
    }
}
