import Foundation
import Observation
import RxAgentCore

/// Bridges a host's existing Apple recognizer without importing its application module.
public struct LocalSpeechRecognizerAdapter: SpeechRecognizing {
    public let inputFormat: VoicePCMFormat
    private let begin: @Sendable () async throws -> AsyncStream<String>
    private let accept: @Sendable (VoiceAudioFrame) async throws -> Void
    private let reset: @Sendable () async -> Void
    private let end: @Sendable () async -> Void
    public init(inputFormat: VoicePCMFormat, start: @escaping @Sendable () async throws -> AsyncStream<String>,
                append: @escaping @Sendable (VoiceAudioFrame) async throws -> Void,
                discard: @escaping @Sendable () async -> Void, stop: @escaping @Sendable () async -> Void) {
        self.inputFormat = inputFormat; begin = start; accept = append; reset = discard; end = stop
    }
    public func start() async throws -> AsyncStream<String> { try await begin() }
    public func append(_ frame: VoiceAudioFrame) async throws { try await accept(frame) }
    public func discard() async { await reset() }
    public func stop() async { await end() }
}
/// Bridges PCM produced by a Kokoro worker or other host TTS service.
public struct LocalSpeechSynthesizerAdapter: SpeechSynthesizing {
    private let render: @Sendable (String) async throws -> AsyncThrowingStream<VoiceAudioFrame, Error>
    private let cancel: @Sendable () async -> Void
    public init(synthesize: @escaping @Sendable (String) async throws -> AsyncThrowingStream<VoiceAudioFrame, Error>,
                cancelAll: @escaping @Sendable () async -> Void) { render = synthesize; cancel = cancelAll }
    public func synthesize(_ text: String) async throws -> AsyncThrowingStream<VoiceAudioFrame, Error> { try await render(text) }
    public func cancelAll() async { await cancel() }
}
public struct VoiceMode: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let engine: any VoiceEngine
    public init(id: String, title: String, engine: any VoiceEngine) {
        self.id = id; self.title = title; self.engine = engine
    }
}
/// Stops and releases the previous session before changing engines.
@MainActor @Observable public final class VoiceRunner {
    public let modes: [VoiceMode]
    public private(set) var selectedModeID: String?
    public private(set) var session: VoiceSession?
    public private(set) var isSwitching = false
    private let toolRouter: (@Sendable (String, [String: JSONValue]) async -> AgentToolResult)?
    private let makeAudio: @MainActor () -> any VoiceAudioDriver
    public init(modes: [VoiceMode], audio: @escaping @MainActor () -> any VoiceAudioDriver,
                toolRouter: (@Sendable (String, [String: JSONValue]) async -> AgentToolResult)? = nil) {
        self.modes = modes; makeAudio = audio; self.toolRouter = toolRouter
    }
    public func select(_ id: String) async throws {
        guard !isSwitching else { throw VoiceError.invalidState }
        guard let mode = modes.first(where: { $0.id == id }) else { throw VoiceError.unavailable("Unknown voice mode") }
        isSwitching = true
        defer { isSwitching = false }
        await session?.stop()
        session = nil; selectedModeID = nil
        switch await mode.engine.readiness() {
        case .ready: break
        case .needsSetup(let reason), .needsDownload(let reason): throw VoiceError.unavailable(reason)
        }
        let next = VoiceSession(engine: mode.engine, audio: makeAudio(), toolRouter: toolRouter)
        session = next
        do { try await next.start(); selectedModeID = id }
        catch { await next.stop(); session = nil; throw error }
    }
    public func stop() async { await session?.stop() }
}
