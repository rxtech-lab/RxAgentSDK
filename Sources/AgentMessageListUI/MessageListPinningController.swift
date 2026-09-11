public nonisolated enum MessageListPinningAction<ID: Hashable & Sendable>: Equatable {
    case none
    case clearPin
    case pinUserMessageToTop(ID)
    case repinUserMessageToTop(ID)
    case releasePinAndScrollToBottom
    case scrollToBottom
}

public nonisolated struct MessageListPinningController<ID: Hashable & Sendable>: Equatable {
    public private(set) var pinnedUserMessageID: ID?
    public private(set) var isPinningUserMessage: Bool

    public init(pinnedUserMessageID: ID? = nil, isPinningUserMessage: Bool = false) {
        self.pinnedUserMessageID = pinnedUserMessageID
        self.isPinningUserMessage = isPinningUserMessage
    }

    public mutating func handleLastMessageChange(
        id: ID?,
        isUserMessage: Bool,
        isStreaming: Bool,
        isAtBottom: Bool
    ) -> MessageListPinningAction<ID> {
        guard let id else {
            clear()
            return .clearPin
        }

        if isUserMessage {
            pinnedUserMessageID = id
            isPinningUserMessage = true
            return .pinUserMessageToTop(id)
        }

        guard isPinningUserMessage, let pinnedUserMessageID else {
            return isAtBottom ? .scrollToBottom : .none
        }

        if isStreaming {
            return .repinUserMessageToTop(pinnedUserMessageID)
        }

        releasePin()
        return .releasePinAndScrollToBottom
    }

    public mutating func handleStreamingChange(
        oldValue: Bool,
        newValue: Bool,
        isAtBottom: Bool
    ) -> MessageListPinningAction<ID> {
        guard oldValue && !newValue else { return .none }
        guard isPinningUserMessage else { return isAtBottom ? .scrollToBottom : .none }
        releasePin()
        return .releasePinAndScrollToBottom
    }

    public mutating func releasePin() {
        isPinningUserMessage = false
    }

    public mutating func clear() {
        pinnedUserMessageID = nil
        isPinningUserMessage = false
    }
}
