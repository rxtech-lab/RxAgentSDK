import RxAgentContext
import RxAgentCore
import SwiftUI

/// A complete chat surface for an ``Agent``.
///
/// ```swift
/// let agent = Agent(clients: [ClaudeCodeClient(), CodexClient()])
/// AgentChatView(agent: agent)
/// ```
public struct AgentChatView<RowContent: View, Accessories: View>: View {
    private let agent: Agent
    private let rowContent: ((AgentTranscriptItem) -> RowContent)?
    private let completions: [AgentCompletionSource]
    private let onDropFiles: (@MainActor ([URL]) -> Bool)?
    private let accessories: Accessories

    /// Supplied when the host keeps the draft itself — one agent per
    /// conversation means switching conversations would otherwise discard a
    /// half-written message.
    private let externalDraft: Binding<String>?

    @State private var internalDraft = ""
    private var attachments: [AgentAttachment] { agent.draftAttachments }
    @State private var attachmentSendError: String?
    @State private var isAtBottom = true
    @State private var shouldScrollToBottom = false
    @State private var scrollRequest: Task<Void, Never>?
    /// Measured height of the floating chrome, fed back to the list as a bottom
    /// inset so the last row parks just above it instead of behind it.
    @State private var floatingChromeHeight: CGFloat = 0

    @Environment(\.agentTheme) private var theme
    @Environment(\.agentToolbarVisibility) private var toolbarVisibility
    @Environment(\.agentToolCallCollapse) private var toolCallCollapse

    /// The full form. Everything app-specific enters here:
    ///
    /// - `completions` supplies the `/` and `@` popups.
    /// - `accessories` is the row under the field — engine pickers, mode
    ///   toggles, anything the host wants beside the composer.
    /// - `row` replaces the default transcript row, for hosts that render
    ///   message kinds the SDK doesn't know about.
    public init(
        agent: Agent,
        draft: Binding<String>? = nil,
        completions: [AgentCompletionSource] = [],
        onDropFiles: (@MainActor ([URL]) -> Bool)? = nil,
        @ViewBuilder row: @escaping (AgentTranscriptItem) -> RowContent,
        @ViewBuilder accessories: () -> Accessories
    ) {
        self.agent = agent
        self.externalDraft = draft
        self.rowContent = row
        self.completions = completions
        self.onDropFiles = onDropFiles
        self.accessories = accessories()
    }

    public init(agent: Agent, draft: Binding<String>? = nil)
    where RowContent == AgentMessageRow, Accessories == EmptyView {
        self.agent = agent
        self.externalDraft = draft
        self.rowContent = nil
        self.completions = []
        self.onDropFiles = nil
        self.accessories = EmptyView()
    }

    public init(
        agent: Agent,
        draft: Binding<String>? = nil,
        @ViewBuilder row: @escaping (AgentTranscriptItem) -> RowContent
    ) where Accessories == EmptyView {
        self.agent = agent
        self.externalDraft = draft
        self.rowContent = row
        self.completions = []
        self.onDropFiles = nil
        self.accessories = EmptyView()
    }

    public init(
        agent: Agent,
        draft: Binding<String>? = nil,
        completions: [AgentCompletionSource] = [],
        onDropFiles: (@MainActor ([URL]) -> Bool)? = nil,
        @ViewBuilder accessories: () -> Accessories
    ) where RowContent == AgentMessageRow {
        self.agent = agent
        self.externalDraft = draft
        self.rowContent = nil
        self.completions = completions
        self.onDropFiles = onDropFiles
        self.accessories = accessories()
    }

    public var body: some View {
        VStack(spacing: 0) {
            if showsToolbar { toolbar }

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
        // `select(_:)` refreshes these on a switch, but the first client is
        // never selected — without this the reasoning picker would stay empty
        // until the user changed engines.
        .task { await agent.refreshClientOptions() }
        .alert("Attachments aren't supported", isPresented: Binding(
            get: { attachmentSendError != nil },
            set: { if !$0 { attachmentSendError = nil } }
        )) {
            Button("OK") { attachmentSendError = nil }
        } message: { Text(attachmentSendError ?? "") }
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
            rowPadding: theme.rowPadding,
            accessoryContent: { accessory in
                if accessory.kind == .streamingIndicator {
                    AgentStreamingIndicator(
                        isStreaming: isStreaming,
                        usage: agent.thread.usage
                    )
                }
            },
            rowContent: { item in
                if let rowContent {
                    rowContent(item)
                } else {
                    AgentMessageRow(item: item)
                }
            }
        )
        .frame(maxHeight: .infinity)
        .background(theme.listBackground)
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
                text: draft,
                attachments: attachments,
                isStreaming: isStreaming,
                completions: completions,
                queuedTurns: agent.queuedTurns,
                history: promptHistory,
                onSend: send,
                onStop: { agent.stop() },
                onAddAttachments: agent.activeClient.capabilities.contains(.attachments)
                    ? { @MainActor images in agent.draftAttachments.append(contentsOf: images) } : nil,
                onRemoveAttachment: { attachment in
                    agent.draftAttachments.removeAll { $0.id == attachment.id }
                },
                onRemoveQueuedTurn: { agent.removeQueuedTurn(id: $0) },
                onSendQueuedTurnNow: { agent.sendQueuedTurnNow(id: $0) },
                onMergeQueuedTurns: { agent.mergeQueuedTurns() },
                onDropFiles: onDropFiles,
                accessories: { accessories }
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

            AgentModelPicker(agent: agent)

            AgentReasoningPicker(agent: agent)

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

    /// Ours to draw only when the host hasn't taken the job over.
    private var showsToolbar: Bool {
        switch toolbarVisibility {
        // Also when there is a model or a reasoning level to choose: with one
        // client and no header, those pickers would have nowhere to live.
        case .automatic: agent.clients.count > 1
            || !agent.availableReasoningLevels.isEmpty
            || !agent.availableModels.isEmpty
        case .visible: true
        case .hidden: false
        }
    }

    /// The host's draft when it supplied one, otherwise our own.
    private var draft: Binding<String> {
        externalDraft ?? $internalDraft
    }

    private var isStreaming: Bool {
        // Tool approval is part of the same live turn. Keep the activity row,
        // scroll following and Stop control active until the turn finishes.
        agent.phase.isBusy
    }

    private var items: [AgentTranscriptItem] {
        var rows = AgentTranscriptItem.items(
            for: agent.thread.messages,
            transientGroupMinSize: toolCallCollapse.minimumRun
        )
        if showsFoot { rows.append(.accessory(.streamingIndicator)) }
        return rows
    }

    /// The foot row earns its place while a turn is running, and afterwards for
    /// as long as there is a token total to report — which is the only place
    /// that number appears once a host hides the header.
    private var showsFoot: Bool {
        guard !agent.thread.messages.isEmpty else { return false }
        if isStreaming { return true }
        guard let usage = agent.thread.usage else { return false }
        return usage.inputTokens + usage.outputTokens > 0
    }

    /// What ↑ walks back through: this thread's own prompts, oldest first.
    private var promptHistory: [String] {
        agent.thread.messages
            .filter { $0.role == .user }
            .map(\.plainText)
            .filter { !$0.isEmpty }
    }

    private var pendingPermission: Binding<PermissionRequest?> {
        Binding(
            get: { (agent.permissions as? InteractivePermissionCoordinator)?.pending },
            set: { _ in }
        )
    }

    // MARK: Actions

    private func send() {
        guard attachments.isEmpty || agent.activeClient.capabilities.contains(.attachments) else {
            attachmentSendError = "This agent doesn't support attachments. Choose another agent or remove the attachments."
            return
        }
        let text = draft.wrappedValue
        draft.wrappedValue = ""
        let sending = attachments
        agent.draftAttachments = []
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
