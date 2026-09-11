import Foundation
import Observation

/// One conversation, potentially spanning several clients.
///
/// The thread owns an SDK-minted ``AgentThreadID`` that is never reassigned,
/// plus a map of each client's *own* native session id. That separation is what
/// makes provider switching work: the transcript stays continuous while each
/// client resumes only the session it actually created.
///
/// RxCode keyed the same map by provider, which collapsed two distinct ACP
/// agents into one bucket, and used the thread id as a provider session id until
/// the first real one arrived — the source of a large session-id reconciliation
/// complex that has no equivalent here.
@MainActor @Observable
public final class AgentThread: Identifiable {
    public let id: AgentThreadID

    public private(set) var messages: [AgentMessage] = []
    public private(set) var nativeSessionIDs: [AgentClientID: String] = [:]
    public private(set) var todos: [TodoItem] = []
    public private(set) var usage: UsageInfo?
    public private(set) var contextWindow: ContextWindowInfo?
    public private(set) var liveBackgroundTaskIDs: Set<String> = []

    /// The client that produced the most recent turn. Used to detect a handoff.
    public private(set) var lastClientID: AgentClientID?

    public var title: String?
    public let createdAt: Date

    /// Rolling digest of turns that have been compacted away.
    ///
    /// Compacted messages stay in ``messages`` — the user's scrollback is not
    /// the model's context window, and silently deleting rows to save tokens is
    /// the wrong trade. Only ``replayableHistory()`` shrinks.
    public private(set) var summary: String = ""

    /// Messages folded into ``summary`` and therefore no longer replayed.
    public private(set) var compactedMessageIDs: Set<UUID> = []

    @ObservationIgnored private var reducer = TranscriptReducer()

    public init(id: AgentThreadID = AgentThreadID(), createdAt: Date = Date()) {
        self.id = id
        self.createdAt = createdAt
    }

    // MARK: - Session ids

    public func record(client: AgentClientID, nativeID: String) {
        nativeSessionIDs[client] = nativeID
    }

    /// The id this client should resume, or `nil` if it has never run here.
    public func resumeID(for client: AgentClientID) -> String? {
        nativeSessionIDs[client]
    }

    public func hasRun(client: AgentClientID) -> Bool {
        nativeSessionIDs[client] != nil
    }

    // MARK: - Transcript

    public func appendUserMessage(_ text: String, attachments: [AgentAttachment] = []) {
        let message = AgentMessage(
            role: .user,
            blocks: [.text(id: UUID(), text)],
            attachments: attachments
        )
        _ = reducer.append(message)
        syncFromReducer()
    }

    public func apply(_ event: AgentEvent, from client: AgentClientID) {
        _ = reducer.apply(event)
        if case .sessionStarted(let started) = event {
            record(client: client, nativeID: started.nativeSessionID)
        }
        if case .turnEnded(let result) = event, let sessionID = result.nativeSessionID {
            record(client: client, nativeID: sessionID)
        }
        lastClientID = client
        syncFromReducer()
    }

    public func clear() {
        _ = reducer.reset()
        // Native session ids go too: a client that resumed its own session
        // after a clear would bring back exactly what the user just deleted.
        nativeSessionIDs.removeAll()
        lastClientID = nil
        summary = ""
        compactedMessageIDs.removeAll()
        syncFromReducer()
    }

    /// Seed a thread from persisted history (e.g. a resumed CLI session).
    public func load(
        messages: [AgentMessage],
        nativeSessionIDs: [AgentClientID: String] = [:],
        summary: String = "",
        compactedMessageIDs: Set<UUID> = []
    ) {
        reducer = TranscriptReducer(messages: messages)
        self.nativeSessionIDs = nativeSessionIDs
        self.summary = summary
        self.compactedMessageIDs = compactedMessageIDs
        syncFromReducer()
    }

    // MARK: - Compaction

    /// The turns an in-process client should replay: everything not yet folded
    /// into ``summary``.
    ///
    /// The summary itself is *not* prepended here — it belongs in the system
    /// context, which is where ``Agent`` puts it, so that a client replaying
    /// this array gets a clean alternating user/assistant sequence with no
    /// synthetic turn wedged into it.
    public func replayableHistory() -> [AgentMessage] {
        guard !compactedMessageIDs.isEmpty else { return messages }
        return messages.filter { !compactedMessageIDs.contains($0.id) }
    }

    /// Folds all but the last `keepingLast` replayable turns into `summary`.
    ///
    /// `summarize` is injected rather than performed here because summarizing is
    /// a model call and this type owns no client. Pass the digest of the given
    /// transcript; return `nil` to fall back to truncation, which is lossy but
    /// bounded — and bounded is the whole point of compacting.
    @discardableResult
    public func compact(
        keepingLast keep: Int = 6,
        maxSummaryCharacters: Int = 2000,
        summarize: (String, String) async -> String?
    ) async -> Bool {
        let replayable = replayableHistory()
        guard replayable.count > keep else { return false }

        let folded = replayable.prefix(replayable.count - keep)
        let transcript = folded.map { message in
            let role = message.role == .user ? "User" : "Assistant"
            var line = "\(role): \(message.plainText)"
            let tools = message.toolCalls.map(\.name)
            if !tools.isEmpty { line += "\n(tools: \(tools.joined(separator: ", ")))" }
            return line
        }
        .joined(separator: "\n\n")

        if let digest = await summarize(summary, transcript),
           !digest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            summary = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            summary = String((summary + "\n" + transcript).suffix(maxSummaryCharacters))
        }

        compactedMessageIDs.formUnion(folded.map(\.id))
        return true
    }

    /// Marks everything but the last `keepingLast` turns compacted without
    /// calling a model. What `/compact` runs: immediate and free, at the cost of
    /// a cruder digest.
    @discardableResult
    public func compactWithoutSummarizing(
        keepingLast keep: Int = 6,
        maxSummaryCharacters: Int = 2000
    ) -> Bool {
        let replayable = replayableHistory()
        guard replayable.count > keep else { return false }
        let folded = replayable.prefix(replayable.count - keep)
        let transcript = folded.map { message in
            let role = message.role == .user ? "User" : "Assistant"
            return "\(role): \(message.plainText)"
        }
        .joined(separator: "\n")
        summary = String((summary + "\n" + transcript).suffix(maxSummaryCharacters))
        compactedMessageIDs.formUnion(folded.map(\.id))
        return true
    }

    private func syncFromReducer() {
        messages = reducer.messages
        todos = reducer.todos
        usage = reducer.usage
        contextWindow = reducer.contextWindow
        liveBackgroundTaskIDs = reducer.liveBackgroundTaskIDs
    }

    // MARK: - Handoff

    /// A compact rendering of the transcript, for priming a client that has not
    /// seen this thread before. Capped so a long conversation doesn't blow out
    /// the prompt.
    public func handoffSummary(maxCharacters: Int = 4000) -> String {
        var lines: [String] = []
        for message in messages {
            let role = message.role == .user ? "User" : "Assistant"
            let text = message.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                lines.append("\(role): \(text)")
            }
            let tools = message.toolCalls.map(\.name)
            if !tools.isEmpty {
                lines.append("\(role) used tools: \(tools.joined(separator: ", "))")
            }
        }
        var rendered = lines.joined(separator: "\n\n")
        if rendered.count > maxCharacters {
            // Keep the tail — recent turns matter more than the opening.
            rendered = "…\n\n" + String(rendered.suffix(maxCharacters))
        }
        return rendered
    }
}
