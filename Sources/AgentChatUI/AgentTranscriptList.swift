import AgentMessageListUI
import RxAgentCore
import SwiftUI

// MARK: - Items

/// A non-message row: padding, loading spinners, a streaming indicator, or
/// anything the host wants to slot in.
public nonisolated struct AgentTranscriptAccessory: Identifiable, Hashable, Sendable {
    public nonisolated enum Kind: String, Hashable, Sendable {
        case topPadding
        case loadingPrevious
        case streamingIndicator
        case custom
    }

    public let id: String
    public let kind: Kind

    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    public static let topPadding = AgentTranscriptAccessory(id: "top-padding", kind: .topPadding)
    public static let loadingPrevious = AgentTranscriptAccessory(
        id: "loading-previous", kind: .loadingPrevious
    )
    public static let streamingIndicator = AgentTranscriptAccessory(
        id: "streaming-indicator", kind: .streamingIndicator
    )
}

public nonisolated struct AgentTranscriptItem: Identifiable, MessageListItem, Equatable, Sendable {
    public nonisolated enum Kind: Equatable, Sendable {
        case message(AgentMessage)
        /// Consecutive read-only/execution tool calls, collapsed into one row.
        /// Without this a long investigation buries the actual answer.
        case transientGroup([AgentToolCall])
        case accessory(AgentTranscriptAccessory)
    }

    public let id: String
    public let kind: Kind

    public var isUserMessage: Bool {
        guard case .message(let message) = kind else { return false }
        return message.role == .user
    }

    public var isMessageListAccessory: Bool {
        if case .accessory = kind { return true }
        return false
    }

    public static func message(_ message: AgentMessage) -> AgentTranscriptItem {
        AgentTranscriptItem(id: "m-\(message.id)", kind: .message(message))
    }

    public static func transientGroup(_ calls: [AgentToolCall]) -> AgentTranscriptItem {
        AgentTranscriptItem(
            id: "g-\(calls.first?.id ?? UUID().uuidString)",
            kind: .transientGroup(calls)
        )
    }

    public static func accessory(_ accessory: AgentTranscriptAccessory) -> AgentTranscriptItem {
        AgentTranscriptItem(id: "a-\(accessory.id)", kind: .accessory(accessory))
    }

    /// Build rows from a transcript, collapsing runs of transient tool calls.
    public static func items(
        for messages: [AgentMessage],
        transientGroupMinSize: Int = 3
    ) -> [AgentTranscriptItem] {
        messages.map { .message($0) }
    }
}

// MARK: - List

/// Chat-shaped wrapper over ``MessageList``.
///
/// Everything that makes the scrolling feel right — pinning the user's message
/// to the top, reserving space for the answer, the ratcheted turn height —
/// lives in `MessageList`. This layer only decides what a row looks like.
public struct AgentTranscriptList<AccessoryContent: View, RowContent: View>: View {
    private let items: [AgentTranscriptItem]
    private let isStreaming: Bool
    private let shouldScrollToBottom: Bool
    private let scrollToBottomAnimated: Bool
    private let bottomInset: CGFloat
    @Binding private var isAtBottom: Bool
    private let hasMorePrevious: () -> Bool
    private let loadMorePrevious: (() async throws -> Void)?
    private let onLoadError: (MessageListLoadDirection, Error) -> Void
    private let rowPadding: EdgeInsets?
    private let accessibilityIdentifier: String?
    private let accessoryContent: (AgentTranscriptAccessory) -> AccessoryContent
    private let rowContent: (AgentTranscriptItem) -> RowContent

    @Environment(\.agentTheme) private var theme

    public init(
        items: [AgentTranscriptItem],
        isStreaming: Bool = false,
        shouldScrollToBottom: Bool = false,
        scrollToBottomAnimated: Bool = true,
        bottomInset: CGFloat = 0,
        isAtBottom: Binding<Bool> = .constant(true),
        hasMorePrevious: @escaping () -> Bool = { false },
        loadMorePrevious: (() async throws -> Void)? = nil,
        onLoadError: @escaping (MessageListLoadDirection, Error) -> Void = { _, _ in },
        rowPadding: EdgeInsets? = nil,
        accessibilityIdentifier: String? = nil,
        @ViewBuilder accessoryContent: @escaping (AgentTranscriptAccessory) -> AccessoryContent,
        @ViewBuilder rowContent: @escaping (AgentTranscriptItem) -> RowContent
    ) {
        self.items = items
        self.isStreaming = isStreaming
        self.shouldScrollToBottom = shouldScrollToBottom
        self.scrollToBottomAnimated = scrollToBottomAnimated
        self.bottomInset = bottomInset
        self._isAtBottom = isAtBottom
        self.hasMorePrevious = hasMorePrevious
        self.loadMorePrevious = loadMorePrevious
        self.onLoadError = onLoadError
        self.rowPadding = rowPadding
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessoryContent = accessoryContent
        self.rowContent = rowContent
    }

    public var body: some View {
        MessageList(
            messages: items,
            isStreaming: isStreaming,
            shouldScrollToBottom: shouldScrollToBottom,
            scrollToBottomAnimated: scrollToBottomAnimated,
            bottomInset: bottomInset,
            isAtBottom: $isAtBottom,
            hasMorePrevious: hasMorePrevious,
            loadMorePrevious: loadMorePrevious,
            onLoadError: onLoadError
        ) { item in
            row(for: item)
                .padding(rowPadding ?? theme.rowPadding)
                .transition(transition(for: item))
        }
        .accessibilityIdentifier(accessibilityIdentifier ?? "agent-transcript")
    }

    @ViewBuilder
    private func row(for item: AgentTranscriptItem) -> some View {
        if case .accessory(let accessory) = item.kind {
            accessoryContent(accessory)
        } else {
            rowContent(item)
        }
    }

    /// User messages grow from the trailing edge, assistant from the leading —
    /// so a new row reads as coming from the right side of the conversation.
    private func transition(for item: AgentTranscriptItem) -> AnyTransition {
        guard case .message(let message) = item.kind else { return .opacity }
        let anchor: UnitPoint = message.role == .user ? .bottomTrailing : .bottomLeading
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: anchor)),
            removal: .opacity
        )
    }
}

public extension AgentTranscriptList where AccessoryContent == EmptyView {
    init(
        items: [AgentTranscriptItem],
        isStreaming: Bool = false,
        shouldScrollToBottom: Bool = false,
        bottomInset: CGFloat = 0,
        isAtBottom: Binding<Bool> = .constant(true),
        rowPadding: EdgeInsets? = nil,
        @ViewBuilder rowContent: @escaping (AgentTranscriptItem) -> RowContent
    ) {
        self.init(
            items: items,
            isStreaming: isStreaming,
            shouldScrollToBottom: shouldScrollToBottom,
            bottomInset: bottomInset,
            isAtBottom: isAtBottom,
            rowPadding: rowPadding,
            accessoryContent: { _ in EmptyView() },
            rowContent: rowContent
        )
    }
}
