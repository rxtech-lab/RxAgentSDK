#if os(macOS)
import SwiftUI
import Testing
import ViewInspector
@testable import AgentMessageListUI

/// A floating composer sits over the bottom of the list, and `bottomInset` is
/// how the list is told about it. The interesting property is that the inset
/// must come *out of* the reserved tail spacing rather than stack on top of it —
/// otherwise every new turn starts pushed off the top of the viewport by exactly
/// the height of the composer.
@MainActor
@Suite("MessageList bottom inset")
struct MessageListBottomInsetSwiftUITests {

    @Test(
        "A pinned turn rests at the top of the viewport whatever the bottom inset is",
        arguments: [CGFloat(0), 60]
    )
    func pinnedTurnRestsAtTopRegardlessOfInset(inset: CGFloat) async throws {
        let model = BottomInsetModel(bottomInset: inset)
        let view = BottomInsetHarness(model: model)

        ViewHosting.host(
            view: view,
            size: CGSize(width: 260, height: 240),
            function: "\(#function)-\(inset)"
        )
        defer { ViewHosting.expel(function: "\(#function)-\(inset)") }

        model.messages = [.init(text: "user", isUserMessage: true, height: 44)]
        try await Task.sleep(for: .milliseconds(600))

        // ~`minimumPinnedTailSpacing` from the top, with or without the inset.
        // Bounded on BOTH sides: if the inset stacked on top of the reserved
        // spacing instead of coming out of it, the message would be scrolled off
        // the top and this would land at roughly -inset.
        let minY = try #require(model.userMinY)
        #expect(
            minY >= -1 && minY < 40,
            "pinned message sat at y=\(minY) with a \(inset)pt inset"
        )
    }

    @Test("The inset keeps the last row clear of the floating chrome")
    func insetKeepsLastRowClearOfChrome() async throws {
        let inset: CGFloat = 60
        let model = BottomInsetModel(bottomInset: inset)
        let view = BottomInsetHarness(model: model)

        ViewHosting.host(view: view, size: CGSize(width: 260, height: 240), function: #function)
        defer { ViewHosting.expel(function: #function) }

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

        let lastMaxY = try #require(model.lastRowMaxY)
        #expect(
            lastMaxY <= model.viewportHeight - inset + 1,
            "last row reached \(lastMaxY) in a \(model.viewportHeight)pt viewport with a \(inset)pt inset"
        )
    }
}

@MainActor
private final class BottomInsetModel: ObservableObject {
    let bottomInset: CGFloat
    @Published var messages: [BottomInsetMessage] = []
    @Published var isAtBottom = false
    @Published var userMinY: CGFloat?
    @Published var lastRowMaxY: CGFloat?
    @Published var viewportHeight: CGFloat = 0

    init(bottomInset: CGFloat) {
        self.bottomInset = bottomInset
    }
}

private let hostSpace = "bottom-inset-host"

private struct BottomInsetHarness: View {
    @ObservedObject var model: BottomInsetModel

    var body: some View {
        MessageList(
            messages: model.messages,
            isStreaming: true,
            bottomInset: model.bottomInset,
            isAtBottom: Binding(
                get: { model.isAtBottom },
                set: { model.isAtBottom = $0 }
            )
        ) { message in
            Text(message.text)
                .frame(maxWidth: .infinity, minHeight: message.height, alignment: .leading)
                .onGeometryChange(for: CGRect.self) { geometry in
                    geometry.frame(in: .named(hostSpace))
                } action: { frame in
                    if message.isUserMessage { model.userMinY = frame.minY }
                    if message.id == model.messages.last?.id { model.lastRowMaxY = frame.maxY }
                }
        }
        .coordinateSpace(.named(hostSpace))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.viewportHeight = $0 }
    }
}

private struct BottomInsetMessage: MessageListItem {
    let id = UUID()
    let text: String
    let isUserMessage: Bool
    let height: CGFloat
}
#endif
