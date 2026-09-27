#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import AgentMessageListUI

/// Puts a SwiftUI view in a real window and finds the list's native scroll
/// view, so tests can read row positions the way a user would see them.
@MainActor
final class MessageListTestHost<Content: View> {
    let view: NSHostingView<Content>
    let window: NSWindow

    init(size: CGSize, @ViewBuilder content: () -> Content) {
        _ = NSApplication.shared
        view = NSHostingView(rootView: content())
        window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: 100, y: 100), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
    }

    func close() { window.close() }

    var scrollView: NSScrollView? { find(NSScrollView.self, in: view) }
    var list: (any MessageListDebugView)? { scrollView as? any MessageListDebugView }

    func rowFrame(at index: Int) -> CGRect? {
        list?.debugFrameInViewport(ofRowAt: index)
    }

    func scrollToBottom() async throws {
        let scroll = try #require(scrollView)
        for _ in 0..<4 {
            let bottom = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }
}
#endif
