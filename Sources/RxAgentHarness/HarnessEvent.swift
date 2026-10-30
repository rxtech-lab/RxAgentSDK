import Foundation
import RxAgentCore

/// Why a compaction ran.
public enum HarnessCompactionReason: String, Sendable, Hashable {
    /// The context crossed the automatic threshold.
    case auto
    /// The server rejected the request as too long.
    case overflow
    /// The host asked for it (`/compact`).
    case manual
}

/// Token accounting, emitted as it changes.
public struct HarnessTokenUsage: Sendable, Hashable {
    /// Usage of the model call in flight (or just finished).
    public var step: UsageInfo
    /// Cumulative usage of this turn.
    public var turn: UsageInfo
    /// Cumulative usage of the whole session.
    public var session: UsageInfo
    /// True while `step.outputTokens` is an estimate counted from streamed
    /// text; false once the server's own numbers have arrived.
    public var isEstimate: Bool

    public init(step: UsageInfo, turn: UsageInfo, session: UsageInfo, isEstimate: Bool) {
        self.step = step
        self.turn = turn
        self.session = session
        self.isEstimate = isEstimate
    }
}

public struct HarnessTurnResult: Sendable, Hashable {
    public let sessionID: String
    /// The final assistant text of the turn.
    public let text: String
    public let steps: Int
    public let usage: UsageInfo
    public let durationMS: Int
    public let finishReason: String?
}

/// Everything the harness reports during a turn, in order.
///
/// Richer than ``AgentEvent``: it carries tool progress, permission traffic and
/// compaction, which a host built on the harness directly can render. A host
/// that only speaks ``AgentClient`` gets the mapped subset through
/// ``HarnessAgentClient``.
public enum HarnessEvent: Sendable {
    case sessionLoaded(HarnessSessionInfo)
    /// A model call began. `step` counts from 1 within the turn.
    case stepStarted(step: Int)
    case textDelta(String)
    case reasoningDelta(String)
    /// The model finished one message (it may still call tools after it).
    case messageCompleted(HarnessMessage)

    case toolCallStarted(id: String, name: String)
    case toolCallInput(id: String, input: JSONValue)
    case toolProgress(callID: String, event: HarnessToolEvent)
    case toolCallCompleted(id: String, name: String, output: HarnessToolOutput)

    case permissionAsked(HarnessPermissionAsk)
    case permissionReplied(id: String, reply: HarnessPermissionReply)

    case todos([TodoItem])
    case usage(HarnessTokenUsage)
    case contextWindow(ContextWindowInfo)

    case compactionStarted(reason: HarnessCompactionReason)
    /// `prunedToolOutputs` counts tool results whose text was cleared;
    /// `summarized` says whether a summary replaced older turns.
    case compactionFinished(reason: HarnessCompactionReason, prunedToolOutputs: Int, summarized: Bool)

    case turnFinished(HarnessTurnResult)
    case failed(String)
}
