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

public struct MessageList<Message: MessageListItem, RowContent: View>: View {
    private let messages: [Message]
    private let isStreaming: Bool
    private let shouldScrollToBottom: Bool
    private let scrollToBottomAnimated: Bool
    private let bottomInset: CGFloat
    @Binding private var isAtBottom: Bool
    private let hasMorePrevious: () -> Bool
    private let hasMore: () -> Bool
    private let loadMorePrevious: (() async throws -> Void)?
    private let loadMore: (() async throws -> Void)?
    private let onLoadError: (MessageListLoadDirection, Error) -> Void
    private let rowContent: (Message) -> RowContent

    @State private var anchor = MessageListScrollAnchor()
    @State private var geometryUpdates = MessageListGeometryUpdates()
    @State private var pinning = MessageListPinningController<Message.ID>()
    @State private var scrollPhase: ScrollPhase = .idle
    @State private var scrollViewHeight: CGFloat = 0
    @State private var activeTurnMeasurement: MessageListTurnMeasurement<Message.ID>?
    @State private var canReleasePinnedUserMessageByScroll = false
    @State private var pinTask: Task<Void, Never>?
    @State private var bottomScrollTask: Task<Void, Never>?
    @State private var lastStreamingBottomScrollDate = Date.distantPast
    @State private var isLoadingPrevious = false
    @State private var isLoadingNext = false
    @State private var previousLoadContentHeight: CGFloat?
    @State private var nextLoadContentHeight: CGFloat?
    @State private var previousLoadCooldownUntil: Date = .distantPast
    @State private var nextLoadCooldownUntil: Date = .distantPast

    public init(
        messages: [Message],
        isStreaming: Bool = false,
        shouldScrollToBottom: Bool = false,
        scrollToBottomAnimated: Bool = true,
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
        self.bottomInset = max(0, bottomInset)
        self._isAtBottom = isAtBottom
        self.hasMorePrevious = hasMorePrevious
        self.hasMore = hasMore
        self.loadMorePrevious = loadMorePrevious
        self.loadMore = loadMore
        self.onLoadError = onLoadError
        self.rowContent = rowContent
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    topLoadTrigger

                    ForEach(historyMessages) { message in
                        rowContent(message)
                            .id(message.id)
                    }

                    if let pinnedID = pinning.pinnedUserMessageID {
                        // Measure the current turn as one block. Separate lazy-row
                        // positions can update in different passes while scrolling,
                        // making their difference include unrelated history.
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(pinnedTurnMessages) { message in
                                rowContent(message)
                                    .id(message.id)
                            }
                        }
                        .onGeometryChange(for: MessageListTurnMeasurement<Message.ID>.self) { geometry in
                            MessageListTurnMeasurement(userMessageID: pinnedID, height: geometry.size.height)
                        } action: { measurement in
                            guard measurement.userMessageID == pinning.pinnedUserMessageID else { return }
                            var transaction = Transaction()
                            transaction.animation = nil
                            withTransaction(transaction) {
                                activeTurnMeasurement = measurement
                            }
                        }
                    }

                    tailMarker
                    bottomLoadTrigger
                    // The tail spacer is sized so that `turnHeight + spacer == viewport`
                    // (see `pinTailSpacerHeight`). The bottom anchor therefore sits BELOW
                    // the spacer: scrolling to it places the spacer's end at the viewport
                    // bottom, which is exactly the position where the latest user message
                    // rests at the top with the reserved space filling the rest. As the
                    // turn grows the spacer shrinks toward zero, at which point the same
                    // anchor naturally follows the streaming response.
                    pinTailSpacer
                    // Keeps real content clear of anything floating over the
                    // bottom of the list (a composer, a banner). It sits ABOVE
                    // the bottom anchor so scrolling to that anchor still parks
                    // the last row just above the floating chrome rather than
                    // underneath it.
                    bottomInsetSpacer
                    bottomAnchor
                }
            }
            .scrollIndicators(.hidden)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                scrollViewHeight = height
            }
            .onScrollGeometryChange(for: MessageListScrollMetrics.self) { geometry in
                MessageListScrollMetrics(
                    contentHeight: geometry.contentSize.height,
                    visibleMinY: geometry.visibleRect.minY,
                    visibleMaxY: geometry.visibleRect.maxY
                )
            } action: { _, metrics in
                let isUserDriven = isUserDrivenScroll
                geometryUpdates.scheduleMetrics(isUserDriven: isUserDriven) {
                    handleScrollMetrics(metrics, isUserDriven: isUserDriven, proxy: proxy)
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { oldOffsetY, offsetY in
                guard isDirectUserScroll,
                      pinning.isPinningUserMessage,
                      canReleasePinnedUserMessageByScroll,
                      offsetY > oldOffsetY + MessageListConstants.userScrollDownDelta
                else { return }
                geometryUpdates.schedulePinRelease {
                    guard pinning.isPinningUserMessage,
                          canReleasePinnedUserMessageByScroll else { return }
                    releasePinnedUserMessage(proxy: proxy)
                }
            }
            .onScrollPhaseChange { _, phase in
                scrollPhase = phase
            }
            .task {
                if shouldScrollToBottom {
                    scrollToBottom(proxy: proxy, animated: false, reason: "task.initial")
                }
            }
            .onChange(of: shouldScrollToBottom) { _, shouldScroll in
                guard shouldScroll else { return }
                guard !pinning.isPinningUserMessage else {
                    ScrollToBottomDiag.recordSkipped("onChangeShouldScroll.skippedPinning", animated: scrollToBottomAnimated, streaming: isStreaming)
                    return
                }
                // While streaming, the content `onChange` toggles this once per
                // token (≈4/sec). Scrolling immediately on each toggle stacks a
                // fresh spring animation per token — the visible "scrolls a lot"
                // churn. Funnel the streaming follow through the same throttle the
                // message-change path uses (`scheduleScrollToBottom`, gated to one
                // pending task and rate-limited to `streamingBottomScrollInterval`)
                // so it collapses to ≈1 scroll per interval. The animation is
                // preserved; only the cadence changes. Non-streaming toggles
                // (session open, new send, the non-animated stream-end re-assert)
                // keep the immediate path so they stay snappy and exact.
                if isStreaming {
                    scheduleScrollToBottom(proxy: proxy)
                    return
                }
                anchor.resetToBottom()
                scrollToBottom(proxy: proxy, animated: scrollToBottomAnimated, reason: "onChangeShouldScroll")
            }
            .onChange(of: isStreaming) { oldValue, newValue in
                if !newValue {
                    lastStreamingBottomScrollDate = .distantPast
                }
                applyPinningAction(
                    pinning.handleStreamingChange(
                        oldValue: oldValue,
                        newValue: newValue,
                        isAtBottom: isAnchoredAtBottom
                    ),
                    proxy: proxy
                )
            }
            .onChange(of: messageListChangeToken) { oldToken, newToken in
                handleMessageListChange(oldToken: oldToken, newToken: newToken, proxy: proxy)
            }
            .onDisappear {
                geometryUpdates.cancel()
            }
        }
    }

    private var topLoadTrigger: some View {
        Color.clear.frame(height: 1)
    }

    private var tailMarker: some View {
        Color.clear
            .frame(height: 1)
            .id(MessageListConstants.tailMarkerID)
    }

    private var bottomLoadTrigger: some View {
        Color.clear.frame(height: 1)
    }

    private var pinTailSpacer: some View {
        Color.clear.frame(height: pinTailSpacerHeight)
    }

    private var bottomInsetSpacer: some View {
        Color.clear.frame(height: bottomInset)
    }

    private var bottomAnchor: some View {
        Color.clear
            .frame(height: 1)
            .id(MessageListConstants.bottomAnchorID)
    }

    private var isUserDrivenScroll: Bool {
        switch scrollPhase {
        case .interacting, .tracking, .decelerating:
            true
        case .idle, .animating:
            false
        @unknown default:
            false
        }
    }

    private var isDirectUserScroll: Bool {
        switch scrollPhase {
        case .interacting, .tracking:
            true
        case .idle, .animating, .decelerating:
            false
        @unknown default:
            false
        }
    }

    private var pinTailSpacerHeight: CGFloat {
        // Persistent reservation: as long as there is a latest user message, reserve
        // `viewport - turnHeight` at the bottom so the turn (latest user message →
        // end of content) can rest at the top of the viewport. This is keyed off the
        // tracked user message — NOT the transient `isPinningUserMessage` flag — so the
        // reserved space survives scrolling and the pin "releasing"; it only collapses
        // naturally as the turn grows to fill the viewport, or when the latest user
        // message changes. A single size measurement also lets the reservation
        // grow again when tool rows collapse or text reflows in a wider window.
        //
        // `bottomInset` is subtracted because the inset spacer already occupies
        // that much of the viewport below the turn. Without this the two would
        // stack and push the pinned message off the top of the screen by exactly
        // the height of the floating composer.
        guard pinning.pinnedUserMessageID != nil, scrollViewHeight > 0 else { return 0 }
        return max(
            0,
            scrollViewHeight - bottomInset - activeTurnHeight
                - MessageListConstants.minimumPinnedTailSpacing
        )
    }

    private var activeTurnHeight: CGFloat {
        guard let measurement = activeTurnMeasurement,
              measurement.userMessageID == pinning.pinnedUserMessageID else { return 0 }
        return measurement.height
    }

    private var pinnedTurnStartIndex: Int? {
        guard let pinnedID = pinning.pinnedUserMessageID else { return nil }
        return messages.firstIndex { $0.id == pinnedID }
    }

    private var historyMessages: ArraySlice<Message> {
        messages[..<(pinnedTurnStartIndex ?? messages.endIndex)]
    }

    private var pinnedTurnMessages: ArraySlice<Message> {
        messages[(pinnedTurnStartIndex ?? messages.endIndex)...]
    }

    private var pinnedTurnFillsViewport: Bool {
        guard scrollViewHeight > 0 else { return false }
        return activeTurnHeight
            >= scrollViewHeight - bottomInset - MessageListConstants.minimumPinnedTailSpacing
    }

    private var isAnchoredAtBottom: Bool {
        anchor.isNearBottom && isAtBottom
    }

    private var latestContentItem: Message? {
        messages.last { !$0.isMessageListAccessory }
    }

    private var latestUserMessageID: Message.ID? {
        messages.last { $0.isUserMessage }?.id
    }

    private var hasContentAfterPinnedUserMessage: Bool {
        guard let pinnedID = pinning.pinnedUserMessageID,
              let pinnedIndex = messages.firstIndex(where: { $0.id == pinnedID })
        else { return false }

        let nextIndex = messages.index(after: pinnedIndex)
        guard nextIndex < messages.endIndex else { return false }
        return messages[nextIndex...].contains { !$0.isMessageListAccessory }
    }

    private var shouldReleasePinnedUserMessageForFilledTurn: Bool {
        pinning.isPinningUserMessage
            && hasContentAfterPinnedUserMessage
            && pinnedTurnFillsViewport
    }

    private var messageListChangeToken: MessageListChangeToken<Message.ID> {
        MessageListChangeToken(
            ids: messages.map(\.id),
            latestContentID: latestContentItem?.id,
            latestUserMessageID: latestUserMessageID
        )
    }

    private func handleScrollMetrics(
        _ metrics: MessageListScrollMetrics,
        isUserDriven: Bool,
        proxy: ScrollViewProxy
    ) {
        let decision = anchor.apply(
            contentHeight: metrics.contentHeight,
            visibleMaxY: metrics.visibleMaxY,
            isUserDriven: isUserDriven
        )
        updateIsAtBottomBinding(anchor.isNearBottom)

        if shouldReleasePinnedUserMessageForFilledTurn, !isUserDriven {
            releasePinnedUserMessage(proxy: proxy)
        }

        if decision == .scrollToBottom,
           isAtBottom,
           isStreaming,
           !isUserDriven,
           !pinning.isPinningUserMessage {
            scheduleScrollToBottom(proxy: proxy)
        }

        if isUserDriven, metrics.visibleMinY <= MessageListConstants.loadThreshold {
            triggerLoadPreviousIfNeeded(contentHeight: metrics.contentHeight)
        } else if metrics.visibleMinY > MessageListConstants.loadThreshold {
            previousLoadContentHeight = nil
        }

        if isUserDriven, metrics.contentHeight - metrics.visibleMaxY <= MessageListConstants.loadThreshold {
            triggerLoadNextIfNeeded(contentHeight: metrics.contentHeight)
        } else if metrics.contentHeight - metrics.visibleMaxY > MessageListConstants.loadThreshold {
            nextLoadContentHeight = nil
        }
    }

    private func handleMessageListChange(
        oldToken: MessageListChangeToken<Message.ID>,
        newToken: MessageListChangeToken<Message.ID>,
        proxy: ScrollViewProxy
    ) {
        // Drop a stale pin if its message is no longer present (e.g. switching
        // sessions or deleting messages). The persistent tail spacer is keyed off
        // `pinnedUserMessageID`, so a dangling id would otherwise reserve space for a
        // message that no longer exists.
        if let pinnedID = pinning.pinnedUserMessageID,
           !messages.contains(where: { $0.id == pinnedID }) {
            clearPinnedUserMessage()
        }

        let latestContentItem = latestContentItem
        if oldToken.latestUserMessageID != newToken.latestUserMessageID,
           let latestUserMessageID = newToken.latestUserMessageID,
           isStreaming || latestContentItem?.isUserMessage == true {
            let action = pinning.handleLastMessageChange(
                id: latestUserMessageID,
                isUserMessage: true,
                isStreaming: isStreaming,
                isAtBottom: isAnchoredAtBottom
            )
            applyPinningAction(action, proxy: proxy)
            return
        }

        let action = pinning.handleLastMessageChange(
            id: latestContentItem?.id,
            isUserMessage: latestContentItem?.isUserMessage == true,
            isStreaming: isStreaming,
            isAtBottom: isAnchoredAtBottom
        )
        applyPinningAction(action, proxy: proxy)
    }

    private func updateIsAtBottomBinding(_ value: Bool) {
        guard isAtBottom != value else { return }
        isAtBottom = value
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool, reason: String = "scrollToBottom") {
        // While reserved spacing exists below the latest turn, the content already fits
        // in the viewport — a follow/auto scroll would only pull the empty reserved
        // space into view and shove the turn around. Only scroll once the turn has
        // outgrown the viewport (no spacing left). The one scroll that is allowed to
        // move into the reserved area is the initial turn placement, which goes through
        // `scrollLatestTurnIntoView` (a direct `proxy.scrollTo`), not this path.
        guard pinTailSpacerHeight <= 0 else {
            ScrollToBottomDiag.recordSkipped("\(reason).skippedSpacer", animated: animated, streaming: isStreaming)
            return
        }
        ScrollToBottomDiag.record(reason, animated: animated, streaming: isStreaming)
        if animated {
            withAnimation(.spring(duration: MessageListConstants.scrollAnimationSeconds, bounce: 0)) {
                proxy.scrollTo(MessageListConstants.bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(MessageListConstants.bottomAnchorID, anchor: .bottom)
        }
    }

    private func scheduleScrollToBottom(proxy: ScrollViewProxy) {
        guard bottomScrollTask == nil else {
            PerformanceDiagnostics.increment("scroll.schedule.coalesced")
            return
        }
        PerformanceDiagnostics.increment("scroll.schedule.created")
        let delayNanoseconds = scrollToBottomDelayNanoseconds()
        bottomScrollTask = Task { @MainActor in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            bottomScrollTask = nil
            guard isAnchoredAtBottom, !isUserDrivenScroll, !pinning.isPinningUserMessage else { return }
            if isStreaming {
                lastStreamingBottomScrollDate = Date()
            }
            scrollToBottom(proxy: proxy, animated: true, reason: "scheduled")
        }
    }

    private func scrollToBottomDelayNanoseconds() -> UInt64 {
        guard isStreaming else {
            return MessageListConstants.layoutSettleDelayNanoseconds
        }
        let elapsed = Date().timeIntervalSince(lastStreamingBottomScrollDate)
        let delay = max(0, MessageListConstants.streamingBottomScrollInterval - elapsed)
        return UInt64(delay * 1_000_000_000)
    }

    /// Positions the latest user turn by scrolling to the bottom anchor — NOT by
    /// scrolling the user message to the top. Because the tail spacer is sized so that
    /// `turnHeight + spacer == viewport`, scrolling to the bottom anchor lands the
    /// latest user message at the top with the reserved space filling the rest. Using
    /// the bottom anchor here (the same target the auto-scroll uses) means the two
    /// never fight: a separate `scrollTo(userMessage, .top)` would disagree with the
    /// auto-scroll whenever the spacer hadn't settled yet, which caused the visible
    /// jump when a new message was added.
    private func scrollLatestTurnIntoView(proxy: ScrollViewProxy, animated: Bool) {
        bottomScrollTask?.cancel()
        bottomScrollTask = nil
        pinTask?.cancel()
        canReleasePinnedUserMessageByScroll = false

        pinTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }

            if animated {
                ScrollToBottomDiag.record("scrollLatestTurnIntoView.animated", animated: true, streaming: isStreaming)
                withAnimation(.spring(duration: MessageListConstants.pinAnimationSeconds, bounce: 0.05)) {
                    proxy.scrollTo(MessageListConstants.bottomAnchorID, anchor: .bottom)
                }
                try? await Task.sleep(for: MessageListConstants.pinAnimationDuration)
            }

            // Re-assert across several frames so the position tracks the tail spacer
            // as it settles to its final size (the turn height is measured a frame or
            // two after the freshly-added content lays out).
            for attempt in 0..<8 {
                guard !Task.isCancelled else { return }
                ScrollToBottomDiag.record("scrollLatestTurnIntoView.settle[\(attempt)]", animated: false, streaming: isStreaming)
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    proxy.scrollTo(MessageListConstants.bottomAnchorID, anchor: .bottom)
                }
                try? await Task.sleep(for: .milliseconds(16))
            }

            guard !Task.isCancelled, pinning.isPinningUserMessage else { return }
            canReleasePinnedUserMessageByScroll = true
        }
    }

    private func releasePinnedUserMessage(proxy: ScrollViewProxy) {
        pinTask?.cancel()
        canReleasePinnedUserMessageByScroll = false
        pinning.releasePin()
        anchor.resetToBottom()
        updateIsAtBottomBinding(true)
        scrollToBottom(proxy: proxy, animated: true)
    }

    private func clearPinnedUserMessage() {
        pinTask?.cancel()
        pinning.clear()
        activeTurnMeasurement = nil
        canReleasePinnedUserMessageByScroll = false
    }

    private func applyPinningAction(
        _ action: MessageListPinningAction<Message.ID>,
        proxy: ScrollViewProxy
    ) {
        switch action {
        case .none:
            break
        case .clearPin:
            clearPinnedUserMessage()
        case .pinUserMessageToTop:
            canReleasePinnedUserMessageByScroll = false
            scrollLatestTurnIntoView(proxy: proxy, animated: true)
        case .repinUserMessageToTop:
            // New streaming content arrived. While the reserved spacing still absorbs
            // the growth, the turn stays put on its own — re-asserting the scroll would
            // just cause an unnecessary jump. Only re-position once the spacing is gone.
            if pinTailSpacerHeight <= 0 {
                scrollLatestTurnIntoView(proxy: proxy, animated: false)
            }
        case .releasePinAndScrollToBottom:
            releasePinnedUserMessage(proxy: proxy)
        case .scrollToBottom:
            scheduleScrollToBottom(proxy: proxy)
        }
    }

    private func triggerLoadPreviousIfNeeded(contentHeight: CGFloat) {
        guard !isLoadingPrevious,
              Date() >= previousLoadCooldownUntil,
              hasMorePrevious(),
              let loadMorePrevious,
              previousLoadContentHeight != contentHeight
        else { return }

        previousLoadContentHeight = contentHeight
        isLoadingPrevious = true
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

    private func triggerLoadNextIfNeeded(contentHeight: CGFloat) {
        guard !isLoadingNext,
              Date() >= nextLoadCooldownUntil,
              hasMore(),
              let loadMore,
              nextLoadContentHeight != contentHeight
        else { return }

        nextLoadContentHeight = contentHeight
        isLoadingNext = true
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

/// Keep scroll geometry callbacks read-only during SwiftUI's layout pass.
/// Keep the last user-driven sample as well as the latest sample, so an idle
/// layout update in the same frame cannot hide a quick deliberate scroll.
@MainActor
final class MessageListGeometryUpdates {
    private var metricsUpdate: (() -> Void)?
    private var userDrivenMetricsUpdate: (() -> Void)?
    private var latestMetricsWasUserDriven = false
    private var metricsTask: Task<Void, Never>?
    private var pinReleaseUpdate: (() -> Void)?
    private var pinReleaseTask: Task<Void, Never>?

    func scheduleMetrics(isUserDriven: Bool, _ update: @escaping () -> Void) {
        metricsUpdate = update
        latestMetricsWasUserDriven = isUserDriven
        if isUserDriven { userDrivenMetricsUpdate = update }
        guard metricsTask == nil else { return }
        metricsTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            metricsTask = nil
            let userDrivenUpdate = userDrivenMetricsUpdate
            let latestUpdate = metricsUpdate
            let latestWasUserDriven = latestMetricsWasUserDriven
            metricsUpdate = nil
            userDrivenMetricsUpdate = nil
            userDrivenUpdate?()
            if !latestWasUserDriven { latestUpdate?() }
        }
    }

    func schedulePinRelease(_ update: @escaping () -> Void) {
        pinReleaseUpdate = update
        guard pinReleaseTask == nil else { return }
        pinReleaseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            pinReleaseTask = nil
            let update = pinReleaseUpdate
            pinReleaseUpdate = nil
            update?()
        }
    }

    func cancel() {
        metricsTask?.cancel()
        metricsTask = nil
        metricsUpdate = nil
        userDrivenMetricsUpdate = nil
        pinReleaseTask?.cancel()
        pinReleaseTask = nil
        pinReleaseUpdate = nil
    }
}

nonisolated struct MessageListScrollMetrics: Equatable {
    var contentHeight: CGFloat
    var visibleMinY: CGFloat
    var visibleMaxY: CGFloat
}

private nonisolated struct MessageListTurnMeasurement<ID: Hashable & Sendable>: Equatable {
    var userMessageID: ID
    var height: CGFloat
}

private nonisolated struct MessageListChangeToken<ID: Hashable & Sendable>: Equatable {
    var ids: [ID]
    var latestContentID: ID?
    var latestUserMessageID: ID?
}

private nonisolated enum MessageListConstants {
    static let bottomAnchorID = "message-list-bottom-anchor"
    static let tailMarkerID = "message-list-tail-marker"
    static let loadThreshold: CGFloat = 96
    static let minimumPinnedTailSpacing: CGFloat = 16
    static let userScrollDownDelta: CGFloat = 4
    static let layoutSettleDelayNanoseconds: UInt64 = 8_000_000
    static let streamingBottomScrollInterval: TimeInterval = 1.5
    static let loadMoreCooldownSeconds: TimeInterval = 1
    static let scrollAnimationSeconds: Double = 0.18
    static let pinAnimationDuration: Duration = .milliseconds(250)
    static let pinAnimationSeconds: Double = 0.25
}
