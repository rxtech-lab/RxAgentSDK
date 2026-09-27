#if os(macOS)
import SwiftUI
import Testing
@testable import AgentMessageListUI

@MainActor
@Suite("MessageList pinned turn behavior", .serialized)
struct MessageListPinnedTurnSwiftUITests {
    @Test("Streaming content that fills the reserved space keeps the list following the bottom")
    func streamingContentFillingReservedSpaceFollowsBottom() async throws {
        let model = MessageListPinnedTurnModel()
        let host = MessageListTestHost(size: CGSize(width: 260, height: 180)) {
            MessageListPinnedTurnHarness(model: model)
        }
        defer { host.close() }

        // A fresh user message pins to the top with reserved space below it.
        model.messages = [.init(text: "user", isUserMessage: true, height: 44)]
        try await Task.sleep(for: .milliseconds(450))

        // The streaming response grows the turn until it outgrows the viewport,
        // collapsing the reserved space. The list must keep following the
        // bottom rather than being stranded above it.
        model.messages.append(contentsOf: [
            .init(text: "assistant 1", isUserMessage: false, height: 88),
            .init(text: "assistant 2", isUserMessage: false, height: 88),
            .init(text: "assistant 3", isUserMessage: false, height: 88),
        ])
        try await Task.sleep(for: .milliseconds(600))

        #expect(model.isAtBottom)
        let viewport = try #require(host.list?.debugViewportHeight)
        let lastMaxY = try #require(host.rowFrame(at: 3)?.maxY)
        #expect(abs(lastMaxY - viewport) < 2, "last row ended at \(lastMaxY) of \(viewport)")
    }

    @Test("A growing streamed row stays followed at the bottom")
    func growingRowIsFollowed() async throws {
        let model = MessageListPinnedTurnModel()
        let host = MessageListTestHost(size: CGSize(width: 260, height: 180)) {
            MessageListPinnedTurnHarness(model: model)
        }
        defer { host.close() }

        model.messages = [
            .init(text: "user", isUserMessage: true, height: 44),
            .init(text: "assistant", isUserMessage: false, height: 60),
        ]
        try await Task.sleep(for: .milliseconds(400))
        for step in 1...6 {
            model.messages[1].height = 60 + CGFloat(step) * 60
            try await Task.sleep(for: .milliseconds(120))
        }
        try await Task.sleep(for: .milliseconds(200))

        let viewport = try #require(host.list?.debugViewportHeight)
        let lastMaxY = try #require(host.rowFrame(at: 1)?.maxY)
        #expect(abs(lastMaxY - viewport) < 2, "last row ended at \(lastMaxY) of \(viewport)")
    }
}

@MainActor
private final class MessageListPinnedTurnModel: ObservableObject {
    @Published var messages: [MessageListPinnedTurnMessage] = []
    @Published var isAtBottom = false
}

private struct MessageListPinnedTurnHarness: View {
    @ObservedObject var model: MessageListPinnedTurnModel

    var body: some View {
        MessageList(
            messages: model.messages,
            isStreaming: true,
            isAtBottom: $model.isAtBottom
        ) { message in
            Text(message.text)
                .frame(maxWidth: .infinity, minHeight: message.height, alignment: .leading)
        }
    }
}

private struct MessageListPinnedTurnMessage: MessageListItem {
    let id = UUID()
    let text: String
    let isUserMessage: Bool
    var height: CGFloat
}
#endif
