import RxAgentContext
import RxAgentCore
import SwiftUI

/// A complete chat surface for an ``Agent``.
///
/// ```swift
/// let agent = Agent(clients: [ClaudeCodeClient(), CodexClient()])
/// AgentChatView(agent: agent)
/// ```
public struct AgentChatView<RowContent: View>: View {
    private let agent: Agent
    private let rowContent: ((AgentTranscriptItem) -> RowContent)?

    @State private var draft = ""
    @State private var attachments: [AgentAttachment] = []
    @State private var isAtBottom = true
    @State private var shouldScrollToBottom = false
    @State private var scrollRequest: Task<Void, Never>?
    /// Measured height of the floating chrome, fed back to the list as a bottom
    /// inset so the last row parks just above it instead of behind it.
    @State private var floatingChromeHeight: CGFloat = 0

    @Environment(\.agentTheme) private var theme

    public init(agent: Agent) where RowContent == AgentMessageRow {
        self.agent = agent
        self.rowContent = nil
    }

    public init(
        agent: Agent,
        @ViewBuilder row: @escaping (AgentTranscriptItem) -> RowContent
    ) {
        self.agent = agent
        self.rowContent = row
    }

    public var body: some View {
        VStack(spacing: 0) {
            if agent.clients.count > 1 { toolbar }

            // The composer floats over the transcript rather than sitting under
            // it in a stack, so there is no rule across the window and content
            // passes behind the input as you scroll. The list is told how tall
            // the floating chrome is (`bottomInset`) so the last row still comes
            // to rest just above it.
            transcript
                .overlay(alignment: .bottom) { floatingChrome }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.ignoresSafeArea())
        .sheet(item: pendingPermission) { request in
            AgentPermissionSheet(request: request) { decision in
                (agent.permissions as? InteractivePermissionCoordinator)?.respond(decision)
            }
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        AgentTranscriptList(
            items: items,
            isStreaming: isStreaming,
            shouldScrollToBottom: shouldScrollToBottom,
            bottomInset: floatingChromeHeight,
            isAtBottom: $isAtBottom,
            rowPadding: theme.rowPadding
        ) { item in
            if let rowContent {
                rowContent(item)
            } else {
                AgentMessageRow(item: item)
            }
        }
        .frame(maxHeight: .infinity)
        .background(theme.background)
    }

    // MARK: Floating chrome

    /// Todos + composer, laid over the bottom of the list. Its own height is
    /// measured and handed back to the list; nothing here draws a full-width
    /// background, so the transcript stays visible around it.
    private var floatingChrome: some View {
        VStack(spacing: 8) {
            if !agent.thread.todos.isEmpty {
                AgentTodoStrip(todos: agent.thread.todos)
                    .padding(.horizontal, 12)
            }

            AgentComposer(
                text: $draft,
                attachments: attachments,
                isStreaming: isStreaming,
                onSend: send,
                onStop: { agent.stop() },
                onRemoveAttachment: { attachment in
                    attachments.removeAll { $0.id == attachment.id }
                }
            )
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height
        } action: { height in
            guard abs(height - floatingChromeHeight) > 0.5 else { return }
            floatingChromeHeight = height
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            AgentClientPicker(
                clients: agent.clients,
                selection: Binding(
                    get: { agent.activeClientID },
                    set: { agent.select($0) }
                )
            )

            if let usage = agent.thread.usage {
                Text("\(usage.inputTokens + usage.outputTokens) tokens")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer(minLength: 0)

            if let window = agent.thread.contextWindow {
                Text("\(Int(window.fractionUsed * 100))% context")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.toolChrome)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: State

    private var isStreaming: Bool {
        if case .streaming = agent.phase { return true }
        return false
    }

    private var items: [AgentTranscriptItem] {
        AgentTranscriptItem.items(for: agent.thread.messages)
    }

    private var pendingPermission: Binding<PermissionRequest?> {
        Binding(
            get: { (agent.permissions as? InteractivePermissionCoordinator)?.pending },
            set: { _ in }
        )
    }

    // MARK: Actions

    private func send() {
        let text = draft
        draft = ""
        let sending = attachments
        attachments = []
        agent.send(text, attachments: sending)
        pulseScrollToBottom()
    }

    /// `shouldScrollToBottom` is edge-triggered, not a command: the list acts on
    /// the false→true transition. Setting it true when it is already true does
    /// nothing, so a send has to pulse it. Do not "simplify" this to a plain
    /// assignment — that silently stops the scroll on the second message.
    private func pulseScrollToBottom() {
        scrollRequest?.cancel()
        shouldScrollToBottom = false
        scrollRequest = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled else { return }
            shouldScrollToBottom = true
        }
    }
}
