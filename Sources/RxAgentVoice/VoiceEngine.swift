import Foundation
import RxAgentCore

public struct VoicePCMFormat: Sendable, Equatable {
    public let sampleRate: Int
    public let channels: Int
    public init(sampleRate: Int = 24_000, channels: Int = 1) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// Interleaved signed 16-bit little-endian PCM.
public struct VoiceAudioFrame: Sendable {
    public let data: Data
    public let format: VoicePCMFormat
    public init(data: Data, format: VoicePCMFormat) throws {
        guard format.sampleRate > 0, format.channels > 0,
              data.count.isMultiple(of: format.channels * 2) else {
            throw VoiceError.invalidAudio
        }
        self.data = data
        self.format = format
    }
}

public enum VoiceError: Error, Sendable, Equatable, LocalizedError, CustomStringConvertible {
    case invalidAudio, invalidState, unavailable(String), transport(String)
    public var description: String {
        switch self {
        case .invalidAudio: "The voice audio format is invalid."
        case .invalidState: "The voice session is no longer connected."
        case .unavailable(let message), .transport(let message): message
        }
    }
    public var errorDescription: String? { description }
}
public enum VoiceEngineReadiness: Sendable { case ready, needsSetup(String), needsDownload(String) }
public struct VoiceEngineCapabilities: Sendable {
    public var canCancel: Bool
    public var canTruncate: Bool
    public var runsTools: Bool
    public init(canCancel: Bool = false, canTruncate: Bool = false, runsTools: Bool = false) {
        self.canCancel = canCancel
        self.canTruncate = canTruncate
        self.runsTools = runsTools
    }
}
public struct VoiceSessionConfig: Sendable {
    public var instructions: String
    public init(instructions: String = "") { self.instructions = instructions }
}
public struct VoiceInterruption: Sendable {
    public let itemID: String?
    public let heardDuration: Duration
    public init(itemID: String?, heardDuration: Duration) {
        self.itemID = itemID
        self.heardDuration = heardDuration
    }
}
public enum VoiceEngineEvent: Sendable {
    case ready, userSpeechStarted, userSpeechStopped
    case userTranscript(itemID: String?, text: String, isFinal: Bool)
    case assistantAudio(itemID: String?, VoiceAudioFrame)
    case assistantText(itemID: String?, delta: String)
    case assistantDone(itemID: String?)
    case toolCallRequested(id: String, name: String, input: [String: JSONValue])
    case toolActivity(AgentEvent)
    case closed(reason: String?)
    case failed(VoiceError)
}
public protocol VoiceEngine: Sendable {
    var displayName: String { get }
    var capabilities: VoiceEngineCapabilities { get }
    func readiness() async -> VoiceEngineReadiness
    func connect(_ config: VoiceSessionConfig) async throws -> any VoiceConnection
}
public protocol VoiceConnection: Sendable {
    var inputFormat: VoicePCMFormat { get }
    var events: AsyncStream<VoiceEngineEvent> { get }
    func send(audio: VoiceAudioFrame) async throws
    func send(text: String) async throws
    func interrupt(_ interruption: VoiceInterruption) async throws
    func submitToolResult(callID: String, result: AgentToolResult) async throws
    func close() async
}

/// Playback clocks must count rendered samples, not queued samples.
@MainActor public protocol VoiceAudioDriver: AnyObject {
    var heardDuration: Duration { get }
    func start(format: VoicePCMFormat) async throws -> AsyncStream<VoiceAudioFrame>
    func play(_ frame: VoiceAudioFrame) throws
    func flush()
    func setCaptureEnabled(_ enabled: Bool)
    func stop()
}
