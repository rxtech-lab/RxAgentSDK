#if os(macOS)
import SwiftUI
import Testing
@testable import AgentMessageListUI

@MainActor
@Suite("MessageList user message pinning option", .serialized)
struct MessageListUserMessagePinningSwiftUITests {
    @Test("onSend pins a sent message to the top even when not streaming")
    func onSendPinsWithoutStreaming() async throws {
        let model = PinningOptionModel(pinning: .onSend)
        let host = MessageListTestHost(size: CGSize(width: 260, height: 300)) {
            PinningOptionHarness(model: model)
        }
        defer { host.close() }

        model.messages = PinningOptionMessage.history
        try await Task.sleep(for: .milliseconds(400))

        // The app appends the question and an empty reply placeholder together.
        model.messages.append(contentsOf: [
            .init(text: "question", isUserMessage: true, height: 44),
            .init(text: "", isUserMessage: false, height: 30),
        ])
        try await Task.sleep(for: .milliseconds(600))

        let userMinY = try #require(host.rowFrame(at: PinningOptionMessage.history.count)?.minY)
        #expect(abs(userMinY - MessageListConstants.minimumPinnedTailSpacing) < 2, "sent message started at \(userMinY)")
    }

    @Test("whileStreaming keeps the old behavior: no pin without streaming")
    func whileStreamingDoesNotPinWithoutStreaming() async throws {
        let model = PinningOptionModel(pinning: .whileStreaming)
        let host = MessageListTestHost(size: CGSize(width: 260, height: 300)) {
            PinningOptionHarness(model: model)
        }
        defer { host.close() }

        model.messages = PinningOptionMessage.history
        try await Task.sleep(for: .milliseconds(400))
        model.messages.append(contentsOf: [
            .init(text: "question", isUserMessage: true, height: 44),
            .init(text: "", isUserMessage: false, height: 30),
        ])
        try await Task.sleep(for: .milliseconds(600))

        let viewport = try #require(host.list?.debugViewportHeight)
        let lastMaxY = try #require(host.rowFrame(at: PinningOptionMessage.history.count + 1)?.maxY)
        #expect(abs(lastMaxY - viewport) < 2, "last row ended at \(lastMaxY) of \(viewport)")
    }

    @Test("never scrolls a sent message to the bottom instead of pinning")
    func neverDoesNotPin() async throws {
        let model = PinningOptionModel(pinning: .never, isStreaming: true)
        let host = MessageListTestHost(size: CGSize(width: 260, height: 300)) {
            PinningOptionHarness(model: model)
        }
        defer { host.close() }

        model.messages = PinningOptionMessage.history
        try await Task.sleep(for: .milliseconds(400))
        model.messages.append(.init(text: "question", isUserMessage: true, height: 44))
        try await Task.sleep(for: .milliseconds(600))

        let viewport = try #require(host.list?.debugViewportHeight)
        let lastMaxY = try #require(host.rowFrame(at: PinningOptionMessage.history.count)?.maxY)
        #expect(abs(lastMaxY - viewport) < 2, "last row ended at \(lastMaxY) of \(viewport)")
    }
}

@MainActor
private final class PinningOptionModel: ObservableObject {
    let pinning: MessageListUserMessagePinning
    let isStreaming: Bool
    @Published var messages: [PinningOptionMessage] = []
    @Published var isAtBottom = true

    init(pinning: MessageListUserMessagePinning, isStreaming: Bool = false) {
        self.pinning = pinning
        self.isStreaming = isStreaming
    }
}

private struct PinningOptionHarness: View {
    @ObservedObject var model: PinningOptionModel

    var body: some View {
        MessageList(
            messages: model.messages,
            isStreaming: model.isStreaming,
            userMessagePinning: model.pinning,
            isAtBottom: $model.isAtBottom
        ) { message in
            Text(message.text)
                .frame(maxWidth: .infinity, minHeight: message.height, alignment: .leading)
        }
    }
}

private struct PinningOptionMessage: MessageListItem {
    let id = UUID()
    let text: String
    let isUserMessage: Bool
    var height: CGFloat

    static let history: [PinningOptionMessage] = (0..<6).map {
        .init(text: "row \($0)", isUserMessage: $0.isMultiple(of: 2), height: 80)
    }
}
#endif
