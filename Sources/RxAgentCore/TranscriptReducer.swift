import Foundation

/// What changed, so an observer can update incrementally instead of diffing.
public enum TranscriptChange: Sendable, Equatable {
    case appended(messageIndex: Int)
    case updated(messageIndex: Int)
    case cleared
}

/// Folds a stream of ``AgentEvent`` into a transcript.
///
/// Pure and `nonisolated`: no actors, no UI, no I/O. This is the extraction of
/// what RxCode spread across `AppState+Stream.swift` and
/// `AppState+CrossProject.swift` — roughly 1,500 lines of `@MainActor` state
/// mutation — into a value type you can drive from a test with a literal array
/// of events.
public struct TranscriptReducer: Sendable {
    public private(set) var messages: [AgentMessage]

    /// Side channels the reducer tracks but that aren't part of the transcript.
    public private(set) var todos: [TodoItem]
    public private(set) var usage: UsageInfo?
    public private(set) var contextWindow: ContextWindowInfo?
    public private(set) var nativeSessionID: String?
    public private(set) var liveBackgroundTaskIDs: Set<String>

    /// Index of the assistant message currently receiving deltas.
    private var activeMessageIndex: Int?
    /// Block currently open, so deltas know where to land.
    private var activeBlock: BlockRef?
    /// Ids of `UUID`-keyed text/thinking blocks, so successive deltas append to
    /// the same block rather than creating a new one per delta.
    private var activeTextBlockID: UUID?
    private var activeThinkingBlockID: UUID?

    public init(messages: [AgentMessage] = []) {
        self.messages = messages
        self.todos = []
        self.liveBackgroundTaskIDs = []
    }

    // MARK: - Seeding

    /// Append a locally-authored message (the user's prompt) before the turn starts.
    public mutating func append(_ message: AgentMessage) -> [TranscriptChange] {
        // A user message landing mid-stream (steering) splits the answer: the
        // reply to it has to open a fresh assistant message *after* it rather
        // than keep writing into the one above.
        var changes = message.role == .user ? closeActiveMessage() : []
        messages.append(message)
        changes.append(.appended(messageIndex: messages.count - 1))
        return changes
    }

    public mutating func reset() -> [TranscriptChange] {
        messages.removeAll()
        todos.removeAll()
        usage = nil
        contextWindow = nil
        nativeSessionID = nil
        liveBackgroundTaskIDs.removeAll()
        activeMessageIndex = nil
        activeBlock = nil
        activeTextBlockID = nil
        activeThinkingBlockID = nil
        return [.cleared]
    }

    // MARK: - Reduction

    public mutating func apply(_ event: AgentEvent) -> [TranscriptChange] {
        switch event {
        case .sessionStarted(let started):
            nativeSessionID = started.nativeSessionID
            return []

        case .turnStarted:
            return []

        case .messageStarted(let role, _):
            guard role == .assistant else { return [] }
            return [openAssistantMessage()]

        case .blockStarted(let ref):
            activeBlock = ref
            switch ref {
            case .text: activeTextBlockID = nil
            case .thinking: activeThinkingBlockID = nil
            case .toolUse: break
            }
            return []

        case .textDelta(let delta):
            return appendText(delta)

        case .thinkingDelta(let delta):
            return appendThinking(delta)

        case .toolCallStarted(let id, let name):
            return startToolCall(id: id, name: name)

        case .toolCallInput(let id, let input):
            return updateToolCall(id: id) { call in
                call.input = input
                call.hasCompleteInput = true
            }

        case .toolCallResult(let id, let content, let isError):
            var changes = updateToolCall(id: id) { call in
                call.result = content
                call.isError = isError
            }
            // A TodoWrite result confirms the list; derive todos from its input.
            if let call = findToolCall(id: id), call.name.lowercased() == "todowrite" {
                todos = TodoExtractor.parse(todoWriteInput: call.input)
            }
            if changes.isEmpty { changes = [] }
            return changes

        case .blockEnded:
            activeBlock = nil
            return []

        case .messageEnded(_, let messageUsage):
            if let messageUsage { usage = merge(usage, messageUsage) }
            guard let index = activeMessageIndex else { return [] }
            messages[index].isStreaming = false
            activeMessageIndex = nil
            activeBlock = nil
            activeTextBlockID = nil
            activeThinkingBlockID = nil
            return [.updated(messageIndex: index)]

        case .todos(let items):
            todos = items
            return []

        case .usage(let info):
            usage = merge(usage, info)
            return []

        case .contextWindow(let info):
            contextWindow = info
            return []

        case .rateLimit, .modelsDiscovered, .permissionRequested, .diagnostic:
            return []

        case .backgroundTask(let task):
            switch task.status {
            case .started, .updated: liveBackgroundTaskIDs.insert(task.taskID)
            case .completed, .failed: liveBackgroundTaskIDs.remove(task.taskID)
            }
            return []

        case .turnEnded(let result):
            if let resultUsage = result.usage { usage = merge(usage, resultUsage) }
            if let sessionID = result.nativeSessionID { nativeSessionID = sessionID }
            guard !result.isBackgroundFollowUp else { return [] }
            return closeActiveMessage()

        case .failed(let error):
            var changes = closeActiveMessage()
            if let index = activeMessageIndex ?? messages.indices.last,
               messages[index].role == .assistant {
                messages[index].error = error.description
                changes.append(.updated(messageIndex: index))
            } else {
                var message = AgentMessage(role: .assistant)
                message.error = error.description
                messages.append(message)
                changes.append(.appended(messageIndex: messages.count - 1))
            }
            activeMessageIndex = nil
            return changes
        }
    }

    // MARK: - Message helpers

    private mutating func openAssistantMessage() -> TranscriptChange {
        if let index = activeMessageIndex { return .updated(messageIndex: index) }
        messages.append(AgentMessage(role: .assistant, isStreaming: true))
        activeMessageIndex = messages.count - 1
        return .appended(messageIndex: messages.count - 1)
    }

    /// Ensure there's a streaming assistant message to write into. Clients don't
    /// all emit `messageStarted` before their first delta, so deltas self-heal.
    private mutating func ensureAssistantMessage() -> [TranscriptChange] {
        if activeMessageIndex != nil { return [] }
        return [openAssistantMessage()]
    }

    private mutating func closeActiveMessage() -> [TranscriptChange] {
        guard let index = activeMessageIndex else { return [] }
        messages[index].isStreaming = false
        activeMessageIndex = nil
        activeBlock = nil
        activeTextBlockID = nil
        activeThinkingBlockID = nil
        return [.updated(messageIndex: index)]
    }

    private mutating func appendText(_ delta: String) -> [TranscriptChange] {
        var changes = ensureAssistantMessage()
        guard let index = activeMessageIndex else { return changes }

        if let blockID = activeTextBlockID,
           let position = messages[index].blocks.firstIndex(where: {
               if case .text(let id, _) = $0 { return id == blockID }
               return false
           }),
           case .text(let id, let existing) = messages[index].blocks[position] {
            messages[index].blocks[position] = .text(id: id, existing + delta)
        } else {
            let id = UUID()
            activeTextBlockID = id
            messages[index].blocks.append(.text(id: id, delta))
        }
        changes.append(.updated(messageIndex: index))
        return changes
    }

    private mutating func appendThinking(_ delta: String) -> [TranscriptChange] {
        var changes = ensureAssistantMessage()
        guard let index = activeMessageIndex else { return changes }

        if let blockID = activeThinkingBlockID,
           let position = messages[index].blocks.firstIndex(where: {
               if case .thinking(let id, _) = $0 { return id == blockID }
               return false
           }),
           case .thinking(let id, let existing) = messages[index].blocks[position] {
            messages[index].blocks[position] = .thinking(id: id, existing + delta)
        } else {
            let id = UUID()
            activeThinkingBlockID = id
            messages[index].blocks.append(.thinking(id: id, delta))
        }
        changes.append(.updated(messageIndex: index))
        return changes
    }

    // MARK: - Tool call helpers

    private mutating func startToolCall(id: String, name: String) -> [TranscriptChange] {
        var changes = ensureAssistantMessage()
        guard let index = activeMessageIndex else { return changes }
        // A repeated start for the same id is an update, not a duplicate.
        if messages[index].blocks.contains(where: { $0.toolCall?.id == id }) {
            changes.append(.updated(messageIndex: index))
            return changes
        }
        // Once a tool call opens, later text starts a fresh block.
        activeTextBlockID = nil
        messages[index].blocks.append(.toolCall(AgentToolCall(id: id, name: name)))
        changes.append(.updated(messageIndex: index))
        return changes
    }

    /// Tool results can arrive after the owning message closed (Claude delivers
    /// them in a following `user` frame), so search the whole transcript.
    private mutating func updateToolCall(
        id: String,
        _ mutate: (inout AgentToolCall) -> Void
    ) -> [TranscriptChange] {
        for messageIndex in messages.indices.reversed() {
            for blockIndex in messages[messageIndex].blocks.indices
            where messages[messageIndex].blocks[blockIndex].toolCall?.id == id {
                guard case .toolCall(var call) = messages[messageIndex].blocks[blockIndex] else {
                    continue
                }
                mutate(&call)
                messages[messageIndex].blocks[blockIndex] = .toolCall(call)
                return [.updated(messageIndex: messageIndex)]
            }
        }
        return []
    }

    private func findToolCall(id: String) -> AgentToolCall? {
        for message in messages.reversed() {
            for block in message.blocks where block.toolCall?.id == id {
                return block.toolCall
            }
        }
        return nil
    }

    private func merge(_ existing: UsageInfo?, _ incoming: UsageInfo) -> UsageInfo {
        // Providers report cumulative totals for the turn, so the newer value
        // replaces rather than adds. Cost is kept if the newer frame omits it.
        guard let existing else { return incoming }
        var merged = incoming
        if merged.totalCostUSD == nil { merged.totalCostUSD = existing.totalCostUSD }
        return merged
    }
}
