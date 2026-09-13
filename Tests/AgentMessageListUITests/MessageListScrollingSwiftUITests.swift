#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import AgentMessageListUI

@MainActor
@Suite("MessageList reserved spacing while scrolling", .serialized)
struct MessageListScrollingSwiftUITests {
    @Test("Scrolling through variable-height history preserves the latest turn's top alignment")
    func scrollingPreservesReservedSpacing() async throws {
        let model = ScrollingModel()
        let host = ScrollingHost(model: model)
        defer { host.window.close() }
        try await Task.sleep(for: .milliseconds(150))
        model.messages = (0..<80).map { index in
            ScrollingMessage(height: CGFloat([44, 220, 72, 360][index % 4]))
        }
        try await Task.sleep(for: .milliseconds(150))
        model.messages.append(.init(isUserMessage: true, height: 44))
        model.messages.append(.init(height: 72))
        try await Task.sleep(for: .milliseconds(750))

        let scroll = try #require(host.scrollView)
        try await host.scrollToBottom(scroll)
        try await Task.sleep(for: .milliseconds(150))
        let initialY = try #require(model.userMinY)
        #expect(initialY >= -1 && initialY < 40, "initial user y=\(initialY)")

        for _ in 0..<3 {
            // Move far enough to recycle lazy history rows, then return to the
            // real bottom. The short current turn must still have room below it.
            for offset: CGFloat in [5000, 2000, 0] {
                scroll.contentView.scroll(to: CGPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(for: .milliseconds(80))
            }
            model.messages[model.messages.count - 1].height += 8
            try await Task.sleep(for: .milliseconds(100))
            try await host.scrollToBottom(scroll)
            try await Task.sleep(for: .milliseconds(180))
            let returnedY = try #require(model.userMinY)
            #expect(abs(returnedY - initialY) < 3, "user moved from \(initialY) to \(returnedY)")
        }

        model.isStreaming = false
        try await Task.sleep(for: .milliseconds(250))
        try await host.scrollToBottom(scroll)
        try await Task.sleep(for: .milliseconds(150))
        #expect(abs(try #require(model.userMinY) - initialY) < 3)
    }

    @Test("Collapsing response content restores space below the latest user message")
    func collapsedContentRestoresSpacing() async throws {
        let model = ScrollingModel()
        let host = ScrollingHost(model: model)
        defer { host.window.close() }
        try await Task.sleep(for: .milliseconds(150))
        model.messages = [
            .init(height: 600),
            .init(isUserMessage: true, height: 44),
            .init(height: 180),
        ]
        try await Task.sleep(for: .milliseconds(750))
        let scroll = try #require(host.scrollView)
        model.messages[2].height = 48
        try await Task.sleep(for: .milliseconds(250))
        try await host.scrollToBottom(scroll)
        try await Task.sleep(for: .milliseconds(200))
        let userY = try #require(model.userMinY)
        #expect(userY >= -1 && userY < 40, "collapsed turn user y=\(userY)")
    }
}

@MainActor @Observable
private final class ScrollingModel {
    var messages: [ScrollingMessage] = []
    var isStreaming = true
    var userMinY: CGFloat?
}

private struct ScrollingMessage: MessageListItem {
    let id = UUID()
    var isUserMessage = false
    var height: CGFloat
}

private struct ScrollingHarness: View {
    let model: ScrollingModel

    var body: some View {
        MessageList(messages: model.messages, isStreaming: model.isStreaming, bottomInset: 80) { message in
            Text(message.isUserMessage ? "Latest user message" : "Response")
                .frame(maxWidth: .infinity)
                .frame(height: message.height)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.frame(in: .named("scrolling-test-viewport")).minY
                } action: { value in
                    if message.isUserMessage { model.userMinY = value }
                }
        }
        .coordinateSpace(.named("scrolling-test-viewport"))
    }
}

@MainActor
private final class ScrollingHost {
    let view: NSHostingView<ScrollingHarness>
    let window: NSWindow

    init(model: ScrollingModel) {
        _ = NSApplication.shared
        view = NSHostingView(rootView: ScrollingHarness(model: model))
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 360, height: 420),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
    }

    var scrollView: NSScrollView? { findScrollView(in: view) }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScrollView(in: $0) }.first
    }

    func scrollToBottom(_ scroll: NSScrollView) async throws {
        // Lazy history updates its estimated content size as a long jump reveals
        // rows. Reach the settled bottom before checking the reserved space.
        for _ in 0..<8 {
            let bottom = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(30))
        }
        let bottom = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        #expect(abs(scroll.contentView.bounds.minY - bottom) < 2)
    }
}
#endif
