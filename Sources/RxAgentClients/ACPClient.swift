#if os(macOS)
import Foundation
import RxAgentBridge
import RxAgentCore
import RxAgentProcess

/// Drives any agent speaking the Agent Client Protocol.
///
/// Unlike the other two clients, ACP keeps its child process **alive across
/// turns**. `session/prompt` carries no history, so the conversation lives
/// inside the agent process; killing it between turns would silently reset the
/// conversation. (`session/load` exists but replays the whole history as
/// updates, which would duplicate every message in the transcript.)
public struct ACPClient: AgentClient {
    public enum Launch: Sendable, Hashable {
        case binary(path: String, args: [String])
        case npx(package: String, args: [String])
        case uvx(package: String, args: [String])
        case custom(command: String, args: [String])
    }

    public let id: AgentClientID
    public let displayName: String
    public var provider: AgentProvider { .acp }
    public let capabilities: AgentCapabilities

    let launch: Launch
    let environmentOverrides: [String: String]
    /// Some agents select their model through an env var rather than a protocol
    /// field (e.g. `ANTHROPIC_MODEL`).
    let modelEnvVar: String?

    private let runtime: ACPRuntime

    // MARK: - Init

    public init(
        binaryFile: URL,
        args: [String] = [],
        env: [String: String] = [:],
        id: AgentClientID? = nil,
        displayName: String? = nil,
        modelEnvVar: String? = nil,
        capabilities: AgentCapabilities = .acpDefaults
    ) {
        let name = displayName ?? binaryFile.deletingPathExtension().lastPathComponent
        self.id = id ?? .acp(binaryFile.lastPathComponent)
        self.displayName = name
        self.launch = .binary(path: binaryFile.path, args: args)
        self.environmentOverrides = env
        self.modelEnvVar = modelEnvVar
        self.capabilities = capabilities
        self.runtime = ACPRuntime()
    }

    public init(
        npx package: String,
        args: [String] = [],
        env: [String: String] = [:],
        displayName: String,
        id: AgentClientID? = nil,
        modelEnvVar: String? = nil,
        capabilities: AgentCapabilities = .acpDefaults
    ) {
        self.id = id ?? .acp(package)
        self.displayName = displayName
        self.launch = .npx(package: package, args: args)
        self.environmentOverrides = env
        self.modelEnvVar = modelEnvVar
        self.capabilities = capabilities
        self.runtime = ACPRuntime()
    }

    public init(
        uvx package: String,
        args: [String] = [],
        env: [String: String] = [:],
        displayName: String,
        id: AgentClientID? = nil,
        modelEnvVar: String? = nil,
        capabilities: AgentCapabilities = .acpDefaults
    ) {
        self.id = id ?? .acp(package)
        self.displayName = displayName
        self.launch = .uvx(package: package, args: args)
        self.environmentOverrides = env
        self.modelEnvVar = modelEnvVar
        self.capabilities = capabilities
        self.runtime = ACPRuntime()
    }

    public init(
        command: String,
        args: [String] = [],
        env: [String: String] = [:],
        displayName: String,
        id: AgentClientID,
        modelEnvVar: String? = nil,
        capabilities: AgentCapabilities = .acpDefaults
    ) {
        self.id = id
        self.displayName = displayName
        self.launch = .custom(command: command, args: args)
        self.environmentOverrides = env
        self.modelEnvVar = modelEnvVar
        self.capabilities = capabilities
        self.runtime = ACPRuntime()
    }

    // MARK: - Availability

    public func isAvailable() async -> Bool {
        switch launch {
        case .binary(let path, _):
            return FileManager.default.isExecutableFile(atPath: path)
        case .npx:
            return await ShellEnvironment.shared.findBinary(named: "npx") != nil
        case .uvx:
            return await ShellEnvironment.shared.findBinary(named: "uvx") != nil
        case .custom(let command, _):
            if command.hasPrefix("/") {
                return FileManager.default.isExecutableFile(atPath: command)
            }
            return await ShellEnvironment.shared.findBinary(named: command) != nil
        }
    }

    func resolvedLaunch() -> (executable: String, arguments: [String]) {
        switch launch {
        case .binary(let path, let args):
            (path, args)
        case .npx(let package, let args):
            ("/usr/bin/env", ["npx", "-y", package] + args)
        case .uvx(let package, let args):
            ("/usr/bin/env", ["uvx", package] + args)
        case .custom(let command, let args):
            command.hasPrefix("/") ? (command, args) : ("/usr/bin/env", [command] + args)
        }
    }

    // MARK: - Send

    public func send(_ request: AgentSendRequest) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task { await run(request, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: AgentSendRequest,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async {
        continuation.yield(.turnStarted(turnID: request.turnID))

        do {
            let session = try await runtime.session(
                for: request,
                client: self,
                continuation: continuation
            )

            await session.decoder.begin(
                turnID: request.turnID,
                continuation: continuation,
                permissions: request.permissions,
                permissionMode: request.permissionMode
            )

            continuation.yield(.sessionStarted(SessionStarted(
                nativeSessionID: session.agentSessionID,
                model: request.model
            )))

            let result = try await session.connection.request("session/prompt", params: .object([
                "sessionId": .string(session.agentSessionID),
                "prompt": .array([.object([
                    "type": .string("text"),
                    "text": .string(composePrompt(request, isNewSession: session.isNew)),
                ])]),
            ]))

            await session.decoder.finishTurn(
                sessionID: session.agentSessionID,
                stopReason: result["stopReason"]?.stringValue
            )
        } catch {
            if Task.isCancelled {
                continuation.yield(.failed(.cancelled))
            } else if let agentError = error as? AgentError {
                continuation.yield(.failed(agentError))
            } else {
                continuation.yield(.failed(.protocolViolation(String(describing: error))))
            }
        }

        continuation.finish()
    }

    /// ACP has no system-prompt channel, so context rides in the prompt. On a
    /// pooled session the agent already saw it, so only a fresh session pays
    /// the cost.
    private func composePrompt(_ request: AgentSendRequest, isNewSession: Bool) -> String {
        guard isNewSession, !request.contextText.isEmpty else { return request.prompt }
        return "\(request.contextText)\n\n---\n\n\(request.prompt)"
    }

    // MARK: - Lifecycle

    public func cancel(turn: UUID) async {
        await runtime.cancel(turnID: turn)
    }

    /// Tears down the pooled process. Without this an `Agent` that is simply
    /// released leaves a child running.
    public func endSession(thread: AgentThreadID) async {
        await runtime.end(threadID: thread)
    }
}
#endif
