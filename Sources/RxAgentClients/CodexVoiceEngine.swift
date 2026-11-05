#if os(macOS)
import Foundation
import RxAgentCore
import RxAgentVoice

public struct CodexVoiceEngine: VoiceEngine {
    public let displayName = "Codex realtime"
    public let capabilities = VoiceEngineCapabilities(runsTools: true)
    private let client: CodexClient
    private let directory: URL
    private let voice: String?
    public init(client: CodexClient, workingDirectory: URL, voice: String? = nil) {
        self.client = client; directory = workingDirectory; self.voice = voice
    }
    public func readiness() async -> VoiceEngineReadiness {
        await client.isAvailable() ? .ready : .needsSetup("Install and authenticate Codex")
    }
    public func connect(_ config: VoiceSessionConfig) async throws -> any VoiceConnection {
        let transport = try await client.startRealtime(workingDirectory: directory, instructions: config.instructions, voice: voice)
        let connection = CodexVoiceConnection(transport: transport)
        await connection.start()
        return connection
    }
}
private actor CodexVoiceConnection: VoiceConnection {
    nonisolated let inputFormat = VoicePCMFormat()
    nonisolated let events: AsyncStream<VoiceEngineEvent>
    private let output: AsyncStream<VoiceEngineEvent>.Continuation
    private let transport: CodexRealtimeSession
    private var reader: Task<Void, Never>?
    private var closed = false
    init(transport: CodexRealtimeSession) {
        self.transport = transport
        (events, output) = AsyncStream.makeStream()
    }
    func start() {
        reader = Task { [weak self, transport] in
            for await event in transport.events {
                guard !Task.isCancelled else { break }
                await self?.receive(event)
            }
            await self?.finish()
        }
    }
    private func receive(_ event: CodexRealtimeSession.Event) {
        let value = event.params
        switch event.method {
        case "thread/realtime/started": output.yield(.ready)
        case "thread/realtime/outputAudio/delta":
            guard let audio = value["audio"], let encoded = audio["data"]?.stringValue,
                  let data = Data(base64Encoded: encoded),
                  let rate = audio["sampleRate"]?.numberValue, let channels = audio["numChannels"]?.numberValue,
                  rate > 0, rate <= 192000, channels > 0, channels <= 32 else {
                output.yield(.failed(.invalidAudio)); return
            }
            do { output.yield(.assistantAudio(itemID: audio["itemId"]?.stringValue,
                try .init(data: data, format: .init(sampleRate: Int(rate), channels: Int(channels))))) }
            catch { output.yield(.failed(.invalidAudio)) }
        case "thread/realtime/transcript/done":
            let text = value["text"]?.stringValue ?? ""
            if value["role"]?.stringValue == "user" {
                output.yield(.userTranscript(itemID: UUID().uuidString, text: text, isFinal: true))
            } else {
                let id = UUID().uuidString
                output.yield(.assistantText(itemID: id, delta: text))
                output.yield(.assistantDone(itemID: id))
            }
        case "thread/realtime/error": output.yield(.failed(.transport(value["message"]?.stringValue ?? "Codex realtime failed")))
        case "thread/realtime/closed": output.yield(.closed(reason: value["reason"]?.stringValue))
        default: break
        }
    }
    private func finish() { output.finish() }
    func send(audio: VoiceAudioFrame) async throws {
        guard !closed, audio.format == inputFormat else { throw VoiceError.invalidAudio }
        try await transport.appendAudio(audio.data, sampleRate: UInt32(inputFormat.sampleRate), channels: UInt16(inputFormat.channels))
    }
    func send(text: String) async throws { try await transport.appendText(text) }
    // No per-response cancellation RPC. VoiceSession suppresses interrupted playback locally.
    func interrupt(_ interruption: VoiceInterruption) async throws {}
    func submitToolResult(callID: String, result: AgentToolResult) async throws {
        throw VoiceError.unavailable("Codex owns its tools")
    }
    func close() async {
        guard !closed else { return }; closed = true
        reader?.cancel(); reader = nil
        await transport.close(); output.finish()
    }
}
#endif
