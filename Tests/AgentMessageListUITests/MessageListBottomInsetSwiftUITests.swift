#if os(macOS)
import SwiftUI
import Testing
@testable import AgentMessageListUI

/// A floating composer sits over the bottom of the list, and `bottomInset` is
/// how the list is told about it. The interesting property is that the inset
/// must come *out of* the reserved tail spacing rather than stack on top of it —
/// otherwise every new turn starts pushed off the top of the viewport by exactly
/// the height of the composer.
@MainActor
@Suite("MessageList bottom inset", .serialized)
struct MessageListBottomInsetSwiftUITests {

    @Test(
        "A pinned turn rests at the top of the viewport whatever the bottom inset is",
        arguments: [CGFloat(0), 60]
    )
    func pinnedTurnRestsAtTopRegardlessOfInset(inset: CGFloat) async throws {
        let model = BottomInsetModel(bottomInset: inset)
        let host = MessageListTestHost(size: CGSize(width: 260, height: 240)) {
            BottomInsetHarness(model: model)
        }
        defer { host.close() }

        model.messages = [.init(text: "user", isUserMessage: true, height: 44)]
        try await Task.sleep(for: .milliseconds(600))

        // Near the top, with or without the inset. Bounded on BOTH sides: if the
        // inset stacked on top of the reserved spacing instead of coming out of
        // it, the message would be scrolled off the top.
        let minY = try #require(host.rowFrame(at: 0)?.minY)
        #expect(minY >= -1 && minY < 40, "pinned message sat at y=\(minY) with a \(inset)pt inset")
    }

    @Test("A pinned turn under older history rests at the top of the viewport")
    func pinnedTurnUnderHistoryRestsAtTop() async throws {
        let model = BottomInsetModel(bottomInset: 60)
        let host = MessageListTestHost(size: CGSize(width: 260, height: 240)) {
            BottomInsetHarness(model: model)
        }
        defer { host.close() }

        model.messages = (0..<6).map { .init(text: "old \($0)", isUserMessage: false, height: 90) }
        try await Task.sleep(for: .milliseconds(300))
        model.messages.append(.init(text: "user", isUserMessage: true, height: 44))
        try await Task.sleep(for: .milliseconds(600))

        let minY = try #require(host.rowFrame(at: 6)?.minY)
        #expect(abs(minY - MessageListConstants.minimumPinnedTailSpacing) < 2, "pinned message sat at y=\(minY)")
    }

    @Test("The inset keeps the last row clear of the floating chrome")
    func insetKeepsLastRowClearOfChrome() async throws {
        let inset: CGFloat = 60
        let model = BottomInsetModel(bottomInset: inset)
        let host = MessageListTestHost(size: CGSize(width: 260, height: 240)) {
            BottomInsetHarness(model: model)
        }
        defer { host.close() }

        // Enough content that the turn outgrows the viewport and the reserved
        // spacing collapses to zero — the inset is all that is left holding the
        // last row above the composer.
        model.messages = [
            .init(text: "user", isUserMessage: true, height: 44),
            .init(text: "a1", isUserMessage: false, height: 120),
            .init(text: "a2", isUserMessage: false, height: 120),
            .init(text: "a3", isUserMessage: false, height: 120),
        ]
        try await Task.sleep(for: .milliseconds(800))

        let viewport = try #require(host.list?.debugViewportHeight)
        let lastMaxY = try #require(host.rowFrame(at: 3)?.maxY)
        #expect(
            abs(lastMaxY - (viewport - inset)) < 2,
            "last row reached \(lastMaxY) in a \(viewport)pt viewport with a \(inset)pt inset"
        )
    }
}

@MainActor
private final class BottomInsetModel: ObservableObject {
    let bottomInset: CGFloat
    @Published var messages: [BottomInsetMessage] = []
    @Published var isAtBottom = true

    init(bottomInset: CGFloat) {
        self.bottomInset = bottomInset
    }
}

private struct BottomInsetHarness: View {
    @ObservedObject var model: BottomInsetModel

    var body: some View {
        MessageList(
            messages: model.messages,
            isStreaming: true,
            bottomInset: model.bottomInset,
            isAtBottom: $model.isAtBottom
        ) { message in
            Text(message.text)
                .frame(maxWidth: .infinity, minHeight: message.height, alignment: .leading)
        }
    }
}

private struct BottomInsetMessage: MessageListItem {
    let id = UUID()
    let text: String
    let isUserMessage: Bool
    let height: CGFloat
}
#endif
