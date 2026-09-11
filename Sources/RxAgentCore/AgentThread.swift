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
        nativeSessionIDs.removeAll()
        lastClientID = nil
        syncFromReducer()
    }

    /// Seed a thread from persisted history (e.g. a resumed CLI session).
    public func load(messages: [AgentMessage], nativeSessionIDs: [AgentClientID: String] = [:]) {
        reducer = TranscriptReducer(messages: messages)
        self.nativeSessionIDs = nativeSessionIDs
        syncFromReducer()
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
