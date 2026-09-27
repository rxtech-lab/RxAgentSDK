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
        let host = MessageListTestHost(size: CGSize(width: 360, height: 420)) {
            ScrollingHarness(model: model)
        }
        defer { host.close() }
        try await Task.sleep(for: .milliseconds(150))
        model.messages = (0..<80).map { index in
            ScrollingMessage(height: CGFloat([44, 220, 72, 360][index % 4]))
        }
        try await Task.sleep(for: .milliseconds(150))
        model.messages.append(.init(isUserMessage: true, height: 44))
        model.messages.append(.init(height: 72))
        try await Task.sleep(for: .milliseconds(500))

        let scroll = try #require(host.scrollView)
        let userIndex = model.messages.count - 2
        let initialY = try #require(host.rowFrame(at: userIndex)?.minY)
        #expect(initialY >= -1 && initialY < 40, "initial user y=\(initialY)")

        for _ in 0..<3 {
            // Move far enough to recycle history rows, then return to the real
            // bottom. The short current turn must still have room below it.
            for offset: CGFloat in [5000, 2000, 0] {
                scroll.contentView.scroll(to: CGPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(for: .milliseconds(80))
            }
            model.messages[model.messages.count - 1].height += 8
            try await Task.sleep(for: .milliseconds(100))
            try await host.scrollToBottom()
            try await Task.sleep(for: .milliseconds(100))
            let returnedY = try #require(host.rowFrame(at: userIndex)?.minY)
            #expect(abs(returnedY - initialY) < 3, "user moved from \(initialY) to \(returnedY)")
        }

        model.isStreaming = false
        try await Task.sleep(for: .milliseconds(400))
        try await host.scrollToBottom()
        #expect(abs(try #require(host.rowFrame(at: userIndex)?.minY) - initialY) < 3)
    }

    @Test("Collapsing response content restores space below the latest user message")
    func collapsedContentRestoresSpacing() async throws {
        let model = ScrollingModel()
        let host = MessageListTestHost(size: CGSize(width: 360, height: 420)) {
            ScrollingHarness(model: model)
        }
        defer { host.close() }
        try await Task.sleep(for: .milliseconds(150))
        model.messages = [
            .init(height: 600),
            .init(isUserMessage: true, height: 44),
            .init(height: 180),
        ]
        try await Task.sleep(for: .milliseconds(500))
        model.messages[2].height = 48
        try await Task.sleep(for: .milliseconds(250))
        try await host.scrollToBottom()
        let userY = try #require(host.rowFrame(at: 1)?.minY)
        #expect(userY >= -1 && userY < 40, "collapsed turn user y=\(userY)")
    }

    @Test("Rows are sized to their SwiftUI content")
    func rowsMatchContentHeight() async throws {
        let model = ScrollingModel()
        let host = MessageListTestHost(size: CGSize(width: 360, height: 420)) {
            ScrollingHarness(model: model)
        }
        defer { host.close() }
        model.isStreaming = false
        model.messages = [.init(height: 44), .init(height: 120), .init(height: 60)]
        try await Task.sleep(for: .milliseconds(300))
        #expect(host.rowFrame(at: 0)?.height == 44)
        #expect(host.rowFrame(at: 1)?.height == 120)
        #expect(host.rowFrame(at: 2)?.minY == 164)

        model.messages[1].height = 200
        try await Task.sleep(for: .milliseconds(200))
        #expect(host.rowFrame(at: 1)?.height == 200)
        #expect(host.rowFrame(at: 2)?.minY == 244)
    }
}

@MainActor @Observable
private final class ScrollingModel {
    var messages: [ScrollingMessage] = []
    var isStreaming = true
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
        }
    }
}
#endif
