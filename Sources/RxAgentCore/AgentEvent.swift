import Foundation

// MARK: - Block reference

/// Identifies a content block within an assistant message.
public enum BlockRef: Sendable, Hashable {
    case text
    case thinking
    case toolUse(id: String, name: String)
}

public enum AgentRole: String, Sendable, Codable, Hashable {
    case user
    case assistant
    case system
}

// MARK: - Payloads

public struct SessionStarted: Sendable, Hashable {
    /// The client's own native session/thread id. Recorded so a later turn on
    /// the same client can resume it.
    public let nativeSessionID: String
    public let model: String?
    /// Tool names the agent reported at handshake, when it reports any.
    public let advertisedTools: [String]

    public init(nativeSessionID: String, model: String? = nil, advertisedTools: [String] = []) {
        self.nativeSessionID = nativeSessionID
        self.model = model
        self.advertisedTools = advertisedTools
    }
}

public struct UsageInfo: Sendable, Hashable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreationTokens: Int
    public var totalCostUSD: Double?

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        totalCostUSD: Double? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.totalCostUSD = totalCostUSD
    }
}

public struct ContextWindowInfo: Sendable, Hashable, Codable {
    public let usedTokens: Int
    public let maxTokens: Int

    public init(usedTokens: Int, maxTokens: Int) {
        self.usedTokens = usedTokens
        self.maxTokens = maxTokens
    }

    public var fractionUsed: Double {
        maxTokens > 0 ? Double(usedTokens) / Double(maxTokens) : 0
    }
}

public struct RateLimitInfo: Sendable, Hashable, Codable {
    public let message: String
    public let resetsAt: Date?

    public init(message: String, resetsAt: Date? = nil) {
        self.message = message
        self.resetsAt = resetsAt
    }
}

/// A long-running agent-side task (Claude's `task_started` / `task_notification`).
/// While one is live the inactivity watchdog stands down.
public struct BackgroundTaskEvent: Sendable, Hashable {
    public enum Status: String, Sendable { case started, updated, completed, failed }
    public let taskID: String
    public let status: Status
    public let detail: String?

    public init(taskID: String, status: Status, detail: String? = nil) {
        self.taskID = taskID
        self.status = status
        self.detail = detail
    }
}

public struct TurnResult: Sendable, Hashable {
    public let isError: Bool
    public let durationMS: Int?
    public let usage: UsageInfo?
    public let nativeSessionID: String?
    /// True when this result closes out a background task rather than the
    /// foreground turn — the turn itself may still be running.
    public let isBackgroundFollowUp: Bool

    public init(
        isError: Bool = false,
        durationMS: Int? = nil,
        usage: UsageInfo? = nil,
        nativeSessionID: String? = nil,
        isBackgroundFollowUp: Bool = false
    ) {
        self.isError = isError
        self.durationMS = durationMS
        self.usage = usage
        self.nativeSessionID = nativeSessionID
        self.isBackgroundFollowUp = isBackgroundFollowUp
    }
}

/// Non-semantic. For logs and bug reports. Nothing in the reducer switches on it.
public struct AgentDiagnostic: Sendable {
    public enum Level: String, Sendable { case debug, info, warning, error }

    public let level: Level
    public let client: AgentClientID
    public let message: String
    /// The undecoded frame, when there was one.
    public let raw: JSONValue?

    public init(level: Level, client: AgentClientID, message: String, raw: JSONValue? = nil) {
        self.level = level
        self.client = client
        self.message = message
        self.raw = raw
    }
}

// MARK: - The event

/// The normalized stream every client emits.
///
/// This replaces RxCode's `StreamEvent`, whose `.unknown(String)` case forced
/// Codex and ACP to *synthesize Claude wire frames* so they could reuse Claude's
/// parser, and left the real assembly state machine living in app state. Here
/// each client decodes into these cases directly and no client ever constructs
/// another client's wire format.
public enum AgentEvent: Sendable {
    // Session lifecycle
    case sessionStarted(SessionStarted)
    case turnStarted(turnID: UUID)

    // Message / block structure
    case messageStarted(role: AgentRole, id: String?)
    case blockStarted(BlockRef)
    case textDelta(String)
    case thinkingDelta(String)
    case toolCallStarted(id: String, name: String)
    /// Complete, parsed input — emitted exactly once per tool call.
    ///
    /// Clients whose wire format streams partial argument JSON (only Claude, via
    /// `input_json_delta`) accumulate it internally and emit only this. No UI can
    /// render half-parsed JSON, so exposing the partials would be all cost.
    case toolCallInput(id: String, input: [String: JSONValue])
    case toolCallResult(id: String, content: String, isError: Bool)
    case blockEnded(BlockRef)
    case messageEnded(id: String?, usage: UsageInfo?)

    // Side channels
    case todos([TodoItem])
    case usage(UsageInfo)
    case contextWindow(ContextWindowInfo)
    case rateLimit(RateLimitInfo)
    case modelsDiscovered([AgentModelOption])
    case permissionRequested(PermissionRequest)
    case backgroundTask(BackgroundTaskEvent)

    // Terminal
    case turnEnded(TurnResult)
    case failed(AgentError)

    case diagnostic(AgentDiagnostic)
}

// MARK: - Errors

public enum AgentError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The client's binary could not be found on PATH.
    case binaryNotFound(name: String)
    /// The child process exited before the turn completed.
    case processExited(code: Int32, stderr: String)
    case protocolViolation(String)
    case decodingFailed(String)
    case cancelled
    case timedOut(seconds: Int)
    /// This client cannot run on the current platform (process spawning is macOS-only).
    case unsupportedPlatform(clientID: AgentClientID)
    case agentReported(String)

    public var description: String {
        switch self {
        case .binaryNotFound(let name):
            "Could not find `\(name)` on PATH."
        case .processExited(let code, let stderr):
            "Agent process exited with code \(code)."
              + (stderr.isEmpty ? "" : "\n\(stderr)")
        case .protocolViolation(let detail):
            "Protocol violation: \(detail)"
        case .decodingFailed(let detail):
            "Could not decode agent output: \(detail)"
        case .cancelled:
            "Cancelled."
        case .timedOut(let seconds):
            "Timed out after \(seconds)s with no output."
        case .unsupportedPlatform(let clientID):
            "Client `\(clientID)` requires macOS."
        case .agentReported(let message):
            message
        }
    }
}
