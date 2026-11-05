import Foundation
import Observation
import RxAgentCore

public enum VoiceLifecycle: Sendable, Equatable {
    case idle, connecting, active, paused, stopping, stopped, failed(VoiceError)
}
public enum VoiceActivity: Sendable { case listening, userSpeaking, thinking, usingTools, agentSpeaking }
public struct VoiceTranscriptEntry: Sendable, Identifiable {
    public let id: UUID
    public let itemID: String?
    public let isUser: Bool
    public var text: String
    public var isFinal: Bool
}
@MainActor @Observable public final class VoiceMeters {
    public var input: Float = 0
    public var output: Float = 0
    public init() {}
}

/// Own one session per presentation. Stop it before releasing the audio driver.
@MainActor @Observable public final class VoiceSession {
    public private(set) var lifecycle: VoiceLifecycle = .idle
    public private(set) var activity: VoiceActivity = .listening
    public private(set) var transcript: [VoiceTranscriptEntry] = []
    public private(set) var isMuted = false
    public let meters = VoiceMeters()
    public let capabilities: VoiceEngineCapabilities
    private let engine: any VoiceEngine
    private let audio: any VoiceAudioDriver
    private let toolRouter: (@Sendable (String, [String: JSONValue]) async -> AgentToolResult)?
    private var handledCalls: Set<String> = []
    private let config: VoiceSessionConfig
    private var connection: (any VoiceConnection)?
    private var tasks: [Task<Void, Never>] = []
    private var generation = UUID()
    private var itemID: String?
    private var suppressed: Set<String> = []
    private var startedAt: ContinuousClock.Instant?
    private var elapsed: Duration = .zero
    public var duration: Duration { elapsed + (startedAt.map { $0.duration(to: .now) } ?? .zero) }

    public init(engine: any VoiceEngine, audio: any VoiceAudioDriver, config: VoiceSessionConfig = .init(),
                toolRouter: (@Sendable (String, [String: JSONValue]) async -> AgentToolResult)? = nil) {
        self.engine = engine
        self.audio = audio
        self.config = config
        self.toolRouter = toolRouter
        capabilities = engine.capabilities
    }
    public func start() async throws {
        guard lifecycle == .idle || lifecycle == .stopped else { throw VoiceError.invalidState }
        let token = UUID()
        generation = token
        suppressed.removeAll(); handledCalls.removeAll(); elapsed = .zero
        lifecycle = .connecting
        do {
            let conn = try await engine.connect(config)
            guard token == generation else { await conn.close(); return }
            connection = conn
            let frames = try await audio.start(format: conn.inputFormat)
            guard token == generation else { audio.stop(); await conn.close(); return }
            lifecycle = .active
            startedAt = .now
            audio.setCaptureEnabled(!isMuted)
            tasks.append(Task { [weak self] in
                for await event in conn.events {
                    guard let self, self.generation == token, !Task.isCancelled else { break }
                    await self.receive(event)
                }
                if let self, self.generation == token { await self.stop() }
            })
            tasks.append(Task { [weak self] in
                do {
                    for await frame in frames {
                        guard let self, self.generation == token, !Task.isCancelled else { break }
                        if self.lifecycle == .active && !self.isMuted { try await conn.send(audio: frame) }
                    }
                } catch { await self?.fail(error) }
            })
        } catch {
            if token == generation { await fail(error) }
            throw error
        }
    }
    public func pause() {
        guard lifecycle == .active else { return }
        freezeClock()
        lifecycle = .paused
        audio.setCaptureEnabled(false)
        interrupt()
    }
    public func resume() {
        guard lifecycle == .paused else { return }
        lifecycle = .active
        startedAt = .now
        audio.setCaptureEnabled(!isMuted)
    }
    public func setMuted(_ muted: Bool) {
        isMuted = muted
        audio.setCaptureEnabled(!muted && lifecycle == .active)
    }
    public func send(text: String) async throws {
        guard lifecycle == .active, let connection else { throw VoiceError.invalidState }
        try await connection.send(text: text)
    }
    public func interrupt() {
        let interruption = VoiceInterruption(itemID: itemID, heardDuration: audio.heardDuration)
        if let itemID { suppressed.insert(itemID) }
        audio.flush()
        activity = .listening
        guard let connection else { return }
        tasks.append(Task { [weak self] in
            do { try await connection.interrupt(interruption) }
            catch { await self?.fail(error) }
        })
    }
    public func stop() async {
        guard lifecycle != .stopping && lifecycle != .stopped else { return }
        generation = UUID()
        lifecycle = .stopping
        freezeClock()
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        audio.stop()
        let old = connection
        connection = nil
        await old?.close()
        lifecycle = .stopped
    }
    private func freezeClock() {
        if let startedAt { elapsed += startedAt.duration(to: .now) }
        startedAt = nil
    }
    private func fail(_ error: Error) async {
        await stop()
        lifecycle = .failed(error as? VoiceError ?? .transport(String(describing: error)))
    }
    private func receive(_ event: VoiceEngineEvent) async {
        switch event {
        case .ready: break
        case .userSpeechStarted: interrupt(); activity = .userSpeaking
        case .userSpeechStopped: activity = .thinking
        case .userTranscript(let id, let text, let final):
            update(id: id, user: true, text: text, final: final)
        case .assistantText(let id, let delta):
            update(id: id, user: false, text: delta, final: false)
        case .assistantAudio(let id, let frame):
            guard lifecycle == .active, id.map({ !suppressed.contains($0) }) ?? true else { return }
            itemID = id
            activity = .agentSpeaking
            do { try audio.play(frame) } catch { await fail(error) }
        case .assistantDone(let id):
            if let index = transcript.lastIndex(where: { !$0.isUser && $0.itemID == id }) {
                transcript[index].isFinal = true
            }
            activity = .listening
        case .toolCallRequested(let id, let name, let input):
            guard handledCalls.insert(id).inserted, let connection else { return }
            let token = generation
            let router = toolRouter
            tasks.append(Task { [weak self] in
                let result = await router?(name, input) ?? .error("No voice tool router configured")
                guard let self, self.generation == token, !Task.isCancelled else { return }
                do { try await connection.submitToolResult(callID: id, result: result) }
                catch { if self.generation == token { await self.fail(error) } }
            })
        case .toolActivity: activity = .usingTools
        case .closed: await stop()
        case .failed(let error): await fail(error)
        }
    }
    private func update(id: String?, user: Bool, text: String, final: Bool) {
        if let index = transcript.lastIndex(where: { $0.itemID == id && $0.isUser == user && !$0.isFinal }) {
            if user { transcript[index].text = text } else { transcript[index].text += text }
            transcript[index].isFinal = final
        } else {
            transcript.append(.init(id: UUID(), itemID: id, isUser: user, text: text, isFinal: final))
        }
    }
}
