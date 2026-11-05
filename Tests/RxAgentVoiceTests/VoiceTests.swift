import Foundation
import Testing
@testable import RxAgentVoice

@Test func validatesPCMAlignment() throws {
    #expect(throws: VoiceError.invalidAudio) {
        try VoiceAudioFrame(data: Data([0]), format: .init())
    }
    #expect(throws: VoiceError.invalidAudio) {
        try VoiceAudioFrame(data: Data(), format: .init(sampleRate: 0))
    }
    let frame = try VoiceAudioFrame(data: Data([0, 0]), format: .init())
    #expect(frame.data.count == 2)
}

import RxAgentCore

private actor TestConnection: VoiceConnection {
    nonisolated let inputFormat = VoicePCMFormat()
    nonisolated let events: AsyncStream<VoiceEngineEvent>
    nonisolated let output: AsyncStream<VoiceEngineEvent>.Continuation
    var closes = 0
    init() { (events, output) = AsyncStream.makeStream() }
    func send(audio: VoiceAudioFrame) async throws {}
    func send(text: String) async throws {}
    func interrupt(_ interruption: VoiceInterruption) async throws {}
    func submitToolResult(callID: String, result: AgentToolResult) async throws {}
    func close() async { closes += 1; output.finish() }
}
private struct TestEngine: VoiceEngine {
    let displayName = "Test"
    let capabilities = VoiceEngineCapabilities()
    let connection: TestConnection
    func readiness() async -> VoiceEngineReadiness { .ready }
    func connect(_ config: VoiceSessionConfig) async throws -> any VoiceConnection { connection }
}
@MainActor private final class TestAudio: VoiceAudioDriver {
    var heardDuration: Duration = .zero
    var capturing = false
    var stops = 0
    var continuation: AsyncStream<VoiceAudioFrame>.Continuation?
    func start(format: VoicePCMFormat) async throws -> AsyncStream<VoiceAudioFrame> {
        let (stream, continuation) = AsyncStream<VoiceAudioFrame>.makeStream()
        self.continuation = continuation
        return stream
    }
    func play(_ frame: VoiceAudioFrame) throws {}
    func flush() {}
    func setCaptureEnabled(_ enabled: Bool) { capturing = enabled }
    func stop() { stops += 1; capturing = false; continuation?.finish() }
}
@Test @MainActor func pauseMuteAndCleanup() async throws {
    let connection = TestConnection()
    let audio = TestAudio()
    let session = VoiceSession(engine: TestEngine(connection: connection), audio: audio)
    try await session.start()
    #expect(audio.capturing)
    session.pause()
    #expect(!audio.capturing)
    session.setMuted(true)
    session.resume()
    #expect(!audio.capturing)
    session.setMuted(false)
    #expect(audio.capturing)
    await session.stop()
    await session.stop()
    #expect(await connection.closes == 1)
    #expect(audio.stops == 1)
}
@Test @MainActor func switchingModeClosesOldEngine() async throws {
    let first = TestConnection(), second = TestConnection()
    let runner = VoiceRunner(modes: [
        .init(id: "first", title: "First", engine: TestEngine(connection: first)),
        .init(id: "second", title: "Second", engine: TestEngine(connection: second))
    ], audio: { TestAudio() })
    try await runner.select("first")
    try await runner.select("second")
    #expect(await first.closes == 1)
    #expect(runner.selectedModeID == "second")
    await runner.stop()
    #expect(await second.closes == 1)
}

private struct StubRecognizer: SpeechRecognizing {
    let inputFormat = VoicePCMFormat()
    func start() async throws -> AsyncStream<String> { AsyncStream { $0.finish() } }
    func append(_ frame: VoiceAudioFrame) async throws {}
    func discard() async {}
    func stop() async {}
}
private struct StubSynthesizer: SpeechSynthesizing {
    func synthesize(_ text: String) async throws -> AsyncThrowingStream<VoiceAudioFrame, Error> {
        AsyncThrowingStream { continuation in
            do { continuation.yield(try .init(data: Data([0, 0]), format: .init())) }
            catch { continuation.finish(throwing: error); return }
            continuation.finish()
        }
    }
    func cancelAll() async {}
}
private struct StubResponder: VoiceResponder {
    func respond(to text: String) async throws -> AsyncStream<AgentEvent> {
        AsyncStream { $0.yield(.textDelta("Hello")); $0.finish() }
    }
    func cancel() async {}
}
@Test func pipelineProducesTranscriptAndPCM() async throws {
    let engine = PipelineVoiceEngine(recognizer: StubRecognizer(), synthesizer: StubSynthesizer(), responder: StubResponder())
    let connection = try await engine.connect(.init())
    try await connection.send(text: "Hi")
    var text = "", audioCount = 0, user = ""
    for await event in connection.events {
        switch event {
        case .userTranscript(_, let value, _): user = value
        case .assistantText(_, let value): text += value
        case .assistantAudio: audioCount += 1
        case .assistantDone: await connection.close()
        default: break
        }
    }
    #expect(user == "Hi")
    #expect(text == "Hello")
    #expect(audioCount == 1)
}

@Test func transportErrorsRemainReadableAcrossRunnerBoundary() {
    let original = VoiceError.transport("Connection closed normally")
    let forwarded = VoiceError.transport(String(describing: original))
    #expect(String(describing: forwarded) == "Connection closed normally")
    #expect(forwarded.localizedDescription == "Connection closed normally")
}
