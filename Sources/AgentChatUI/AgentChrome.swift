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

/// Whether ``AgentChatView`` folds runs of consecutive tool-only assistant
/// messages into a single ``AgentTranscriptItem/Kind/transientGroup`` row.
public nonisolated enum AgentToolCallCollapse: Sendable, Hashable {
    /// Every message is its own row.
    case never
    /// Runs of at least `minimum` consecutive tool-only messages fold into one
    /// row. Anything else — text, thinking, an error — breaks the run.
    case consecutive(minimum: Int = 2)

    /// The run length that triggers a fold, or nil when folding is off.
    public var minimumRun: Int? {
        switch self {
        case .never: nil
        case .consecutive(let minimum): max(minimum, 1)
        }
    }
}

extension EnvironmentValues {
    @Entry public var agentToolCallCollapse: AgentToolCallCollapse = .never
}

public extension View {
    /// Fold runs of consecutive tool calls into one collapsed row.
    ///
    /// A long investigation — list, read, search, read again — otherwise
    /// buries the answer under a column of near-identical chips. The host's
    /// row renders the ``AgentTranscriptItem/Kind/transientGroup`` however it
    /// likes; the default row shows a "N tool calls" disclosure.
    func agentToolCallCollapse(_ mode: AgentToolCallCollapse) -> some View {
        environment(\.agentToolCallCollapse, mode)
    }

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
