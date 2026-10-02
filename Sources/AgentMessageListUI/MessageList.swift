import Foundation
import RxAgentUISupport
import SwiftUI

/// Counts scroll activity without logging on the hot main-actor path. The app
/// periodically drains these counters into its performance diagnostic file.
@MainActor
enum ScrollToBottomDiag {
    static func record(_ reason: String, animated: Bool, streaming: Bool) {
        PerformanceDiagnostics.increment("scroll.actual.total")
        PerformanceDiagnostics.increment("scroll.actual.reason.\(reason)")
        if animated { PerformanceDiagnostics.increment("scroll.actual.animated") }
        if streaming { PerformanceDiagnostics.increment("scroll.actual.streaming") }
    }

    static func recordSkipped(_ reason: String, animated: Bool, streaming: Bool) {
        PerformanceDiagnostics.increment("scroll.skipped.total")
        PerformanceDiagnostics.increment("scroll.skipped.reason.\(reason)")
        if animated { PerformanceDiagnostics.increment("scroll.skipped.animated") }
        if streaming { PerformanceDiagnostics.increment("scroll.skipped.streaming") }
    }
}

public protocol MessageListItem: Identifiable, Sendable where ID: Hashable & Sendable {
    var isUserMessage: Bool { get }
    var isMessageListAccessory: Bool { get }
}

public extension MessageListItem {
    var isMessageListAccessory: Bool { false }
}

public enum MessageListLoadDirection: Sendable, Equatable {
    case previous
    case next
}

/// When the latest user message is pinned to the top of the viewport, with
/// space reserved below it for the answer.
public enum MessageListUserMessagePinning: Sendable, Equatable {
    /// Pin while `isStreaming` is true, or while the user message is the last row.
    case whileStreaming
    /// Also pin a user message appended after the existing rows, even when
    /// `isStreaming` stays false or a reply placeholder is appended with it.
    case onSend
    /// Never pin; new messages just scroll the list to the bottom.
    case never
}

public struct MessageList<Message: MessageListItem, RowContent: View>: View {
    private let messages: [Message]
    private let isStreaming: Bool
    private let shouldScrollToBottom: Bool
    private let scrollToBottomAnimated: Bool
    private let userMessagePinning: MessageListUserMessagePinning
    private let bottomInset: CGFloat
    @Binding private var isAtBottom: Bool
    private let hasMorePrevious: () -> Bool
    private let hasMore: () -> Bool
    private let loadMorePrevious: (() async throws -> Void)?
    private let loadMore: (() async throws -> Void)?
    private let onLoadError: (MessageListLoadDirection, Error) -> Void
    private let rowContent: (Message) -> RowContent

    public init(
        messages: [Message],
        isStreaming: Bool = false,
        shouldScrollToBottom: Bool = false,
        scrollToBottomAnimated: Bool = true,
        userMessagePinning: MessageListUserMessagePinning = .whileStreaming,
        bottomInset: CGFloat = 0,
        isAtBottom: Binding<Bool> = .constant(true),
        hasMorePrevious: @escaping () -> Bool = { false },
        hasMore: @escaping () -> Bool = { false },
        loadMorePrevious: (() async throws -> Void)? = nil,
        loadMore: (() async throws -> Void)? = nil,
        onLoadError: @escaping (MessageListLoadDirection, Error) -> Void = { _, _ in },
        @ViewBuilder rowContent: @escaping (Message) -> RowContent
    ) {
        self.messages = messages
        self.isStreaming = isStreaming
        self.shouldScrollToBottom = shouldScrollToBottom
        self.scrollToBottomAnimated = scrollToBottomAnimated
        self.userMessagePinning = userMessagePinning
        self.bottomInset = max(0, bottomInset)
        self._isAtBottom = isAtBottom
        self.hasMorePrevious = hasMorePrevious
        self.hasMore = hasMore
        self.loadMorePrevious = loadMorePrevious
        self.loadMore = loadMore
        self.onLoadError = onLoadError
        self.rowContent = rowContent
    }

    /// Rows are hosted in a `UICollectionView` (iOS) or `NSTableView` (macOS):
    /// cell reuse and native scrolling hold up on long transcripts where a
    /// SwiftUI `ScrollView` + `LazyVStack` stutters and mis-scrolls.
    public var body: some View {
        MessageListRepresentable(
            configuration: MessageListEngine<Message>.Configuration(
                messages: messages.uniquedByID(),
                isStreaming: isStreaming,
                shouldScrollToBottom: shouldScrollToBottom,
                scrollToBottomAnimated: scrollToBottomAnimated,
                userMessagePinning: userMessagePinning,
                bottomInset: bottomInset,
                hasMorePrevious: hasMorePrevious,
                hasMore: hasMore,
                loadMorePrevious: loadMorePrevious,
                loadMore: loadMore,
                onLoadError: onLoadError,
                setIsAtBottom: { [isAtBottom = $isAtBottom] value in
                    if isAtBottom.wrappedValue != value { isAtBottom.wrappedValue = value }
                },
                isAtBottom: isAtBottom
            ),
            rowContent: rowContent
        )
    }
}
