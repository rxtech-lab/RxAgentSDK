import SwiftUI

/// Whether ``AgentChatView`` draws its own header — the client picker and the
/// token/context readouts.
public nonisolated enum AgentToolbarVisibility: Sendable, Hashable {
    /// Shown only when there is more than one client to switch between.
    case automatic
    case visible
    case hidden
}

extension EnvironmentValues {
    @Entry public var agentToolbarVisibility: AgentToolbarVisibility = .automatic
}

public extension View {
    /// Show or hide the chat surface's own header.
    ///
    /// Hide it when the host already offers an engine picker of its own through
    /// `accessories`: two pickers in one window disagree about which is the
    /// real one, and the header's opaque chrome cuts a band across a window
    /// that is otherwise meant to read as a single surface.
    func agentToolbar(_ visibility: AgentToolbarVisibility) -> some View {
        environment(\.agentToolbarVisibility, visibility)
    }
}
