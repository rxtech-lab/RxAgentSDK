#if os(macOS)
import Foundation
import RxAgentCore
import RxAgentProcess

/// How a realtime session carries audio.
public enum CodexRealtimeTransport: Sendable, Equatable {
    /// Audio travels through `appendAudio` and output notifications. Codex requires API key auth here,
    /// so a ChatGPT sign-in fails with "realtime conversation requires API key auth".
    case websocket
    /// The host's peer connection carries audio directly, and works with a ChatGPT sign-in. Pass a complete
    /// offer (ICE gathering finished); the answer arrives as a `thread/realtime/sdp` event.
    case webRTC(offer: String)
}

/// Persistent experimental Codex voice transport. The host owns audio capture/playback.
/// Consume `events` once and always call `close()` when dismissing the voice UI.
public actor CodexRealtimeSession {
    public nonisolated let events: AsyncStream<Event>
    public struct Event: Sendable {
        public let method: String
        public let params: JSONValue
    }
    public let threadID: String
    private let process: ManagedProcess
    private let connection: JSONRPCConnection
    private let continuation: AsyncStream<Event>.Continuation
    private var closed = false

    init(threadID: String, process: ManagedProcess, connection: JSONRPCConnection,
         events: AsyncStream<Event>, continuation: AsyncStream<Event>.Continuation) {
        self.threadID = threadID
        self.process = process
        self.connection = connection
        self.events = events
        self.continuation = continuation
    }

    /// Audio bytes must use the PCM format expected by the installed Codex server.
    public func appendAudio(_ data: Data, sampleRate: UInt32, channels: UInt16,
                            samplesPerChannel: UInt32? = nil) async throws {
        guard sampleRate > 0, channels > 0, !data.isEmpty else {
            throw AgentError.protocolViolation("Empty audio or invalid audio format")
        }
        var audio: [String: JSONValue] = [
            "data": .string(data.base64EncodedString()),
            "sampleRate": .number(Double(sampleRate)),
            "numChannels": .number(Double(channels)),
        ]
        if let samplesPerChannel { audio["samplesPerChannel"] = .number(Double(samplesPerChannel)) }
        try await send("appendAudio", fields: ["audio": .object(audio)])
    }

    public func appendText(_ text: String) async throws {
        try await send("appendText", fields: ["text": .string(text)])
    }

    public func appendSpeech(_ text: String) async throws {
        try await send("appendSpeech", fields: ["text": .string(text)])
    }

    private func send(_ operation: String, fields: [String: JSONValue]) async throws {
        guard !closed else { throw AgentError.protocolViolation("Realtime session closed") }
        var params = fields
        params["threadId"] = .string(threadID)
        try await connection.request("thread/realtime/" + operation, params: .object(params))
    }

    /// Gracefully stop realtime; use `close()` to abort a stalled or disconnected server.
    public func stop() async throws {
        guard !closed else { return }
        do {
            try await send("stop", fields: [:])
            await close()
        } catch {
            await close()
            throw error
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        await connection.close()
        process.closeStdin()
        await process.terminate()
        _ = await process.waitForExit()
        continuation.finish()
    }
}

extension CodexClient {
    /// Starts a dedicated app-server and creates/resumes a thread for live voice.
    /// Uses the CLI's existing authentication. Unsupported experimental APIs throw RPC errors.
    /// Approval requests are delegated to the host; by default they fail closed.
    public func startRealtime(
        workingDirectory: URL,
        resumeThreadID: String? = nil,
        instructions: String = "",
        voice: String? = nil,
        model: String? = nil,
        transport: CodexRealtimeTransport = .websocket,
        version: String? = nil,
        onRequest: JSONRPCConnection.RequestHandler? = nil
    ) async throws -> CodexRealtimeSession {
        guard let binary = await resolveBinary() else { throw AgentError.binaryNotFound(name: "codex") }
        var environment = await ShellEnvironment.shared.environment()
        environment.merge(environmentOverrides) { _, new in new }
        Self.bypassProxyForLoopback(&environment)
        try Task.checkCancellation()
        let process = try ManagedProcess.launch(executable: binary, arguments: launchArguments(),
                                                environment: environment, workingDirectory: workingDirectory.path)
        let connection = JSONRPCConnection(process: process)
        let (events, continuation) = AsyncStream<CodexRealtimeSession.Event>.makeStream()
        await connection.start(onRequest: onRequest, onNotification: { method, params in
            continuation.yield(.init(method: method, params: params))
        })
        do {
            try await connection.request("initialize", params: .object([
                "clientInfo": .object(["name": .string("RxAgentSDK"), "version": .string("1.0.0")]),
                "capabilities": .object(["experimentalApi": .bool(true)]),
            ]))
            try await connection.notify("initialized", params: .object([:]))
            var thread: [String: JSONValue] = [
                "cwd": .string(workingDirectory.path),
                "approvalPolicy": .string(approvalPolicy.rawValue),
                "sandbox": .string(sandbox.rawValue),
            ]
            if !instructions.isEmpty { thread["developerInstructions"] = .string(instructions) }
            if let resumeThreadID { thread["threadId"] = .string(resumeThreadID) }
            let result = try await connection.request(resumeThreadID == nil ? "thread/start" : "thread/resume", params: .object(thread))
            guard let threadID = Self.threadID(from: result) else {
                throw AgentError.protocolViolation("Missing realtime thread ID")
            }
            var params: [String: JSONValue] = [
                "threadId": .string(threadID), "outputModality": .string("audio"),
            ]
            switch transport {
            case .websocket:
                params["transport"] = .object(["type": .string("websocket")])
            case .webRTC(let offer):
                params["transport"] = .object(["type": .string("webrtc"), "sdp": .string(offer)])
            }
            // Codex defaults WebRTC to v1, which the backend rejects for lacking a quicksilver=v2 header.
            if let version = version ?? (transport == .websocket ? nil : "v3") {
                params["version"] = .string(version)
            }
            if let voice { params["voice"] = .string(voice) }
            if let model { params["model"] = .string(model) }
            try await connection.request("thread/realtime/start", params: .object(params))
            let session = CodexRealtimeSession(threadID: threadID, process: process, connection: connection,
                                               events: events, continuation: continuation)
            continuation.onTermination = { [weak session] _ in Task { await session?.close() } }
            Task { [weak session] in
                _ = await process.waitForExit()
                await session?.close()
            }
            return session
        } catch {
            await connection.close()
            await process.terminate()
            _ = await process.waitForExit()
            continuation.finish()
            throw error
        }
    }
}
#endif
