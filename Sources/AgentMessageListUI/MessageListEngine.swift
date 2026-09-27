import CoreGraphics
import Foundation
import RxAgentUISupport

/// What the engine needs from a native scroll view. Every y value is in
/// "content" coordinates: 0 is the top of the first row, and the visible area
/// is the part of the viewport not covered by system safe areas.
@MainActor
protocol MessageListSurface: AnyObject {
    /// Height of the visible area, excluding system safe areas.
    var visibleHeight: CGFloat { get }
    /// Content y at the top of the visible area.
    var visibleMinY: CGFloat { get }
    /// Largest `visibleMinY` the scroll view can reach with its current tail.
    var maxVisibleMinY: CGFloat { get }
    /// Total height of the message rows, not counting the tail.
    var rowsHeight: CGFloat { get }
    /// True while the user's finger / trackpad (or its momentum) moves the list.
    var isUserScrolling: Bool { get }

    func rowMinY(at index: Int) -> CGFloat?
    /// Space below the last row: `bottomInset` plus any reserved space that
    /// lets the latest turn rest at the top of the viewport.
    func setTailHeight(_ height: CGFloat)
    func scroll(toVisibleMinY y: CGFloat, animated: Bool)
}

/// Lets tests read row positions without reaching into either backend.
@MainActor
protocol MessageListDebugView: AnyObject {
    /// The row's frame with y = 0 at the top of the visible area.
    func debugFrameInViewport(ofRowAt index: Int) -> CGRect?
    var debugViewportHeight: CGFloat { get }
}

/// Scroll policy shared by the UIKit and AppKit backends.
///
/// The native views only lay rows out and report geometry; every decision —
/// pinning the latest user message to the top, reserving space for the answer,
/// following a stream, paging — happens here.
@MainActor
final class MessageListEngine<Message: MessageListItem> {
    struct Configuration {
        var messages: [Message] = []
        var isStreaming = false
        var shouldScrollToBottom = false
        var scrollToBottomAnimated = true
        var bottomInset: CGFloat = 0
        var hasMorePrevious: () -> Bool = { false }
        var hasMore: () -> Bool = { false }
        var loadMorePrevious: (() async throws -> Void)?
        var loadMore: (() async throws -> Void)?
        var onLoadError: (MessageListLoadDirection, Error) -> Void = { _, _ in }
        var setIsAtBottom: (Bool) -> Void = { _ in }
        var isAtBottom = true
    }

    weak var surface: (any MessageListSurface)?

    private(set) var configuration = Configuration()
    private var anchor = MessageListScrollAnchor()
    private(set) var pinning = MessageListPinningController<Message.ID>()
    private var changeToken: MessageListChangeToken<Message.ID>?
    private var hasAppliedInitialConfiguration = false
    private var tailHeight: CGFloat = 0
    private var isAnimatingScroll = false
    private var isInLayoutPass = false
    private var reportedIsAtBottom: Bool?

    private var isLoadingPrevious = false
    private var isLoadingNext = false
    private var previousLoadRowsHeight: CGFloat?
    private var nextLoadRowsHeight: CGFloat?
    private var previousLoadCooldownUntil: Date = .distantPast
    private var nextLoadCooldownUntil: Date = .distantPast

    // MARK: Inputs

    /// Call after the rows for `configuration.messages` are applied and laid out.
    func update(_ newConfiguration: Configuration) {
        let old = configuration
        configuration = newConfiguration

        if let pinnedID = pinning.pinnedUserMessageID,
           !newConfiguration.messages.contains(where: { $0.id == pinnedID }) {
            pinning.clear()
        }

        if hasAppliedInitialConfiguration, old.isStreaming != newConfiguration.isStreaming {
            apply(pinning.handleStreamingChange(
                oldValue: old.isStreaming,
                newValue: newConfiguration.isStreaming,
                isAtBottom: isAnchoredAtBottom
            ))
        }

        let newToken = makeChangeToken()
        if newToken != changeToken {
            handleMessageListChange(old: changeToken, new: newToken)
            changeToken = newToken
        }

        let shouldScrollRose = newConfiguration.shouldScrollToBottom
            && (!old.shouldScrollToBottom || !hasAppliedInitialConfiguration)
        if shouldScrollRose {
            if pinning.isPinningUserMessage {
                ScrollToBottomDiag.recordSkipped("shouldScroll.skippedPinning", animated: false, streaming: configuration.isStreaming)
            } else {
                anchor.resetToBottom()
                let animated = hasAppliedInitialConfiguration
                    && newConfiguration.scrollToBottomAnimated
                    && !newConfiguration.isStreaming
                scrollToBottom(animated: animated, reason: "shouldScroll")
            }
        }

        hasAppliedInitialConfiguration = true
        layoutDidChange()
    }

    /// Rows resized, rows were inserted, or the viewport changed size.
    func layoutDidChange() {
        guard let surface, !isInLayoutPass else { return }
        isInLayoutPass = true
        defer { isInLayoutPass = false }

        refreshTail()
        sampleAnchor()

        if pinning.isPinningUserMessage, hasContentAfterPinnedUserMessage, reservedHeight <= 0 {
            // The answer outgrew the viewport; from here on just follow it.
            pinning.releasePin()
        }

        guard !surface.isUserScrolling, !isAnimatingScroll else { return }
        let follows = pinning.isPinningUserMessage
            || (configuration.isStreaming && isAnchoredAtBottom)
        if follows {
            snapToBottom()
        }
    }

    func didScroll() {
        guard let surface, !isInLayoutPass else { return }
        let isUserDriven = surface.isUserScrolling
        sampleAnchor()

        if isUserDriven, !anchor.isNearBottom, pinning.isPinningUserMessage {
            // The user went to read something else; don't yank them back when
            // the stream ends.
            pinning.releasePin()
        }

        guard isUserDriven else { return }
        let visibleMinY = surface.visibleMinY
        let distanceToEnd = surface.maxVisibleMinY - visibleMinY
        if visibleMinY <= MessageListConstants.loadThreshold {
            triggerLoadPreviousIfNeeded()
        } else {
            previousLoadRowsHeight = nil
        }
        if distanceToEnd <= MessageListConstants.loadThreshold {
            triggerLoadNextIfNeeded()
        } else {
            nextLoadRowsHeight = nil
        }
    }

    func userScrollDidEnd() {
        sampleAnchor()
    }

    func scrollAnimationDidEnd() {
        isAnimatingScroll = false
        layoutDidChange()
    }

    /// Whether the backend should keep the first visible row in place across a
    /// data change (true) or leave positioning to the engine (false).
    var shouldPreserveVisibleRow: Bool {
        !(pinning.isPinningUserMessage || isAnchoredAtBottom)
    }

    // MARK: Pinning & following

    private func handleMessageListChange(
        old: MessageListChangeToken<Message.ID>?,
        new: MessageListChangeToken<Message.ID>
    ) {
        let latestContentItem = self.latestContentItem
        if old?.latestUserMessageID != new.latestUserMessageID,
           let latestUserMessageID = new.latestUserMessageID,
           configuration.isStreaming || latestContentItem?.isUserMessage == true {
            apply(pinning.handleLastMessageChange(
                id: latestUserMessageID,
                isUserMessage: true,
                isStreaming: configuration.isStreaming,
                isAtBottom: isAnchoredAtBottom
            ))
            return
        }

        apply(pinning.handleLastMessageChange(
            id: latestContentItem?.id,
            isUserMessage: latestContentItem?.isUserMessage == true,
            isStreaming: configuration.isStreaming,
            isAtBottom: isAnchoredAtBottom
        ))
    }

    private func apply(_ action: MessageListPinningAction<Message.ID>) {
        switch action {
        case .none, .repinUserMessageToTop:
            // Re-pinning needs no scroll: the reserved tail keeps the turn in
            // place, and `layoutDidChange` follows once it has outgrown it.
            break
        case .clearPin:
            pinning.clear()
        case .pinUserMessageToTop:
            anchor.resetToBottom()
            refreshTail()
            scrollToBottom(animated: hasAppliedInitialConfiguration, reason: "pinUserMessage")
        case .releasePinAndScrollToBottom:
            anchor.resetToBottom()
            scrollToBottom(animated: true, reason: "releasePin")
        case .scrollToBottom:
            scrollToBottom(animated: !configuration.isStreaming, reason: "messagesChanged")
        }
    }

    /// Scrolls to the end of the content. With a pinned turn that is exactly
    /// where the latest user message rests at the top of the viewport.
    private func scrollToBottom(animated: Bool, reason: String) {
        guard let surface else { return }
        ScrollToBottomDiag.record(reason, animated: animated, streaming: configuration.isStreaming)
        updateIsAtBottom(true)
        let target = surface.maxVisibleMinY
        guard abs(surface.visibleMinY - target) > 0.5 else { return }
        if animated {
            isAnimatingScroll = true
        }
        surface.scroll(toVisibleMinY: target, animated: animated)
    }

    private func snapToBottom() {
        guard let surface else { return }
        let target = surface.maxVisibleMinY
        guard abs(surface.visibleMinY - target) > 0.5 else { return }
        ScrollToBottomDiag.record("follow", animated: false, streaming: configuration.isStreaming)
        surface.scroll(toVisibleMinY: target, animated: false)
    }

    // MARK: Reserved tail

    private func refreshTail() {
        guard let surface else { return }
        let height = configuration.bottomInset + reservedHeight
        guard abs(height - tailHeight) > 0.5 else { return }
        tailHeight = height
        surface.setTailHeight(height)
    }

    /// Space that lets the latest turn (latest user message → end) rest at the
    /// top of the viewport. Keyed off the tracked user message rather than the
    /// transient pinning flag so it survives scrolling; it collapses as the
    /// turn grows to fill the viewport. `bottomInset` comes out of it because
    /// the inset already occupies that much of the viewport below the turn.
    private var reservedHeight: CGFloat {
        guard let surface,
              let pinnedID = pinning.pinnedUserMessageID,
              let index = configuration.messages.firstIndex(where: { $0.id == pinnedID }),
              let turnMinY = surface.rowMinY(at: index),
              surface.visibleHeight > 0
        else { return 0 }
        let turnHeight = surface.rowsHeight - turnMinY
        return max(
            0,
            surface.visibleHeight - configuration.bottomInset - turnHeight
                - MessageListConstants.minimumPinnedTailSpacing
        )
    }

    // MARK: Bottom tracking

    private func sampleAnchor() {
        guard let surface else { return }
        // Distance is measured to the furthest reachable offset, so the reserved
        // tail counts as "the bottom".
        anchor.apply(
            contentHeight: surface.maxVisibleMinY + surface.visibleHeight,
            visibleMaxY: surface.visibleMinY + surface.visibleHeight,
            isUserDriven: surface.isUserScrolling
        )
        updateIsAtBottom(anchor.isNearBottom)
    }

    private var isAnchoredAtBottom: Bool {
        anchor.isNearBottom && configuration.isAtBottom
    }

    private func updateIsAtBottom(_ value: Bool) {
        guard reportedIsAtBottom != value || configuration.isAtBottom != value else { return }
        reportedIsAtBottom = value
        configuration.isAtBottom = value
        let setIsAtBottom = configuration.setIsAtBottom
        // Never write SwiftUI state from inside a view update.
        DispatchQueue.main.async {
            setIsAtBottom(value)
        }
    }

    // MARK: Derived state

    private var latestContentItem: Message? {
        configuration.messages.last { !$0.isMessageListAccessory }
    }

    private var hasContentAfterPinnedUserMessage: Bool {
        guard let pinnedID = pinning.pinnedUserMessageID,
              let pinnedIndex = configuration.messages.firstIndex(where: { $0.id == pinnedID })
        else { return false }
        return configuration.messages[(pinnedIndex + 1)...].contains { !$0.isMessageListAccessory }
    }

    private func makeChangeToken() -> MessageListChangeToken<Message.ID> {
        MessageListChangeToken(
            ids: configuration.messages.map(\.id),
            latestContentID: latestContentItem?.id,
            latestUserMessageID: configuration.messages.last { $0.isUserMessage }?.id
        )
    }

    // MARK: Paging

    private func triggerLoadPreviousIfNeeded() {
        guard let surface,
              !isLoadingPrevious,
              Date() >= previousLoadCooldownUntil,
              configuration.hasMorePrevious(),
              let loadMorePrevious = configuration.loadMorePrevious,
              previousLoadRowsHeight != surface.rowsHeight
        else { return }

        previousLoadRowsHeight = surface.rowsHeight
        isLoadingPrevious = true
        let onLoadError = configuration.onLoadError
        Task { @MainActor in
            defer {
                previousLoadCooldownUntil = Date().addingTimeInterval(MessageListConstants.loadMoreCooldownSeconds)
                isLoadingPrevious = false
            }
            do {
                try await loadMorePrevious()
            } catch {
                onLoadError(.previous, error)
            }
        }
    }

    private func triggerLoadNextIfNeeded() {
        guard let surface,
              !isLoadingNext,
              Date() >= nextLoadCooldownUntil,
              configuration.hasMore(),
              let loadMore = configuration.loadMore,
              nextLoadRowsHeight != surface.rowsHeight
        else { return }

        nextLoadRowsHeight = surface.rowsHeight
        isLoadingNext = true
        let onLoadError = configuration.onLoadError
        Task { @MainActor in
            defer {
                nextLoadCooldownUntil = Date().addingTimeInterval(MessageListConstants.loadMoreCooldownSeconds)
                isLoadingNext = false
            }
            do {
                try await loadMore()
            } catch {
                onLoadError(.next, error)
            }
        }
    }
}

nonisolated struct MessageListChangeToken<ID: Hashable & Sendable>: Equatable {
    var ids: [ID]
    var latestContentID: ID?
    var latestUserMessageID: ID?
}

nonisolated enum MessageListConstants {
    static let loadThreshold: CGFloat = 96
    static let minimumPinnedTailSpacing: CGFloat = 16
    static let loadMoreCooldownSeconds: TimeInterval = 1
    static let estimatedRowHeight: CGFloat = 80
    static let scrollAnimationSeconds: Double = 0.25
}

extension Array where Element: MessageListItem {
    /// Diffing needs unique ids; keep the first occurrence of any duplicate.
    func uniquedByID() -> [Element] {
        var seen = Set<Element.ID>()
        seen.reserveCapacity(count)
        let result = filter { seen.insert($0.id).inserted }
        if result.count != count {
            PerformanceDiagnostics.increment("messageList.duplicateIDs")
        }
        return result
    }
}
