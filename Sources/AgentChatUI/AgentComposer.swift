import os
import RxAgentContext
import RxAgentCore
import SwiftUI

/// The input area: text, attachments, completions, queued turns, send / stop.
///
/// The behaviours that matter, and why:
///
/// - **Enter sends, Shift+Enter inserts a newline.** Chat conventions, not text
///   editor conventions — this is a message box.
/// - **↑ walks back through what you already asked**, but only from an empty
///   draft, so it never eats a real cursor move.
/// - **Typing while a turn runs queues rather than interrupting.** `Agent.send`
///   handles that; the strip here is how the queue becomes visible and editable.
/// - **Completion popups float above the field** instead of pushing the
///   transcript around.
///
/// Everything app-specific arrives through `completions` and `accessories`, so
/// the view itself knows nothing about projects, backends, or slash commands.
public struct AgentComposer<Accessories: View>: View {
    @Binding private var text: String
    private let attachments: [AgentAttachment]
    private let isStreaming: Bool
    private let placeholder: String
    private let completions: [AgentCompletionSource]
    private let queuedTurns: [Agent.QueuedTurn]
    private let history: [String]
    private let onSend: () -> Void
    private let onStop: () -> Void
    private let onRemoveAttachment: ((AgentAttachment) -> Void)?
    private let onRemoveQueuedTurn: ((UUID) -> Void)?
    private let onMergeQueuedTurns: (() -> Void)?
    private let onDropFiles: (([URL]) -> Bool)?
    private let accessories: Accessories

    @State private var isInputFocused = false
    @State private var hasMarkedText = false
    @State private var focusTrigger: UUID? = UUID()
    @State private var selectedCompletion = 0
    @State private var historyIndex = -1
    @State private var isDropTargeted = false

    @Environment(\.agentTheme) private var theme

    public init(
        text: Binding<String>,
        attachments: [AgentAttachment] = [],
        isStreaming: Bool = false,
        placeholder: String = "Message the agent…",
        completions: [AgentCompletionSource] = [],
        queuedTurns: [Agent.QueuedTurn] = [],
        history: [String] = [],
        onSend: @escaping () -> Void,
        onStop: @escaping () -> Void = {},
        onRemoveAttachment: ((AgentAttachment) -> Void)? = nil,
        onRemoveQueuedTurn: ((UUID) -> Void)? = nil,
        onMergeQueuedTurns: (() -> Void)? = nil,
        onDropFiles: (([URL]) -> Bool)? = nil,
        @ViewBuilder accessories: () -> Accessories
    ) {
        self._text = text
        self.attachments = attachments
        self.isStreaming = isStreaming
        self.placeholder = placeholder
        self.completions = completions
        self.queuedTurns = queuedTurns
        self.history = history
        self.onSend = onSend
        self.onStop = onStop
        self.onRemoveAttachment = onRemoveAttachment
        self.onRemoveQueuedTurn = onRemoveQueuedTurn
        self.onMergeQueuedTurns = onMergeQueuedTurns
        self.onDropFiles = onDropFiles
        self.accessories = accessories()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !queuedTurns.isEmpty { queuedStrip }
            if !attachments.isEmpty { attachmentRow }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom, spacing: 8) {
                    field
                    actionButton
                }

                if !(accessories is EmptyView) {
                    HStack(spacing: 8) {
                        accessories
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            // Floats over the transcript, so it is glass rather than a solid
            // slab: content reads through faintly and the window's own ground
            // carries on behind the field instead of stopping at its edge. No
            // tint over it — a fill heavy enough to be "on-theme" is heavy
            // enough to turn the glass back into a slab.
            .glassEffect(.regular, in: fieldShape)
            .overlay {
                fieldShape
                    .strokeBorder(borderColor, lineWidth: isDropTargeted ? 2 : 1)
            }
            .clipShape(fieldShape)
            .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
            // Anchored above the field so opening it never reflows anything.
            .overlay(alignment: .topLeading) {
                if let query = activeQuery, !visibleItems(for: query).isEmpty {
                    AgentCompletionPopup(
                        items: visibleItems(for: query),
                        selectedIndex: selectedCompletion,
                        onChoose: { choose(index: $0, query: query) }
                    )
                    .alignmentGuide(.top) { $0[.bottom] + 8 }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .onChange(of: text) { _, _ in
            selectedCompletion = 0
            historyIndex = -1
        }
        .onDrop(of: [.fileURL], isTargeted: dropBinding) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Field

    private var field: some View {
        #if os(macOS)
        AgentTextInput(
            text: $text,
            isFocused: $isInputFocused,
            hasMarkedText: $hasMarkedText,
            focusTrigger: focusTrigger,
            font: .systemFont(ofSize: 14),
            textColor: .labelColor,
            placeholder: placeholder,
            handlers: AgentTextInputHandlers(
                onReturn: handleReturn,
                onUpArrow: handleUpArrow,
                onDownArrow: handleDownArrow,
                onTab: handleTab,
                onEscape: handleEscape
            )
        )
        .frame(height: fieldHeight)
        .accessibilityIdentifier("agent-composer-field")
        #else
        AgentTextInput(
            text: $text,
            isFocused: $isInputFocused,
            hasMarkedText: $hasMarkedText,
            focusTrigger: focusTrigger,
            placeholder: placeholder,
            handlers: AgentTextInputHandlers(onReturn: handleReturn)
        )
        .font(.system(size: 14))
        .lineLimit(theme.composerLines, reservesSpace: true)
        .accessibilityIdentifier("agent-composer-field")
        #endif
    }

    /// Rests at the low end of `theme.composerLines` and grows with the draft
    /// to the high end, then scrolls.
    ///
    /// Measured from newline count rather than a layout pass: the field is an
    /// `NSTextView` in a scroll view, so asking it its intrinsic height mid-edit
    /// fights with its own scrolling.
    private var fieldHeight: CGFloat {
        let lineHeight: CGFloat = 18
        let lines = text.reduce(into: 1) { count, character in
            if character.isNewline { count += 1 }
        }
        return CGFloat(theme.composerLines.clamping(lines)) * lineHeight
    }

    private var borderColor: Color {
        if isDropTargeted { return theme.accent }
        return isInputFocused ? theme.accent.opacity(0.5) : theme.toolBorder
    }

    /// Softer and rounder than a row card — it has to read as floating.
    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.cornerRadius + 8, style: .continuous)
    }

    // MARK: - Completions

    private var activeQuery: AgentCompletionQuery? {
        guard !completions.isEmpty, !hasMarkedText else { return nil }
        return AgentCompletionScanner.scan(text, triggers: Set(completions.map(\.trigger)))
    }

    private func visibleItems(for query: AgentCompletionQuery) -> [AgentCompletionItem] {
        guard let source = completions.first(where: { $0.trigger == query.trigger })
        else { return [] }
        return source.items(query.query)
    }

    private func choose(index: Int, query: AgentCompletionQuery) {
        let items = visibleItems(for: query)
        guard items.indices.contains(index) else { return }
        let item = items[index]

        if let insertion = item.insertion {
            text = AgentCompletionScanner.applying(insertion, to: text, query: query)
        } else {
            // A command consumes its own trigger text; leaving `/clear` behind
            // in the draft after running it would be a bug the user has to
            // clean up by hand.
            text = AgentCompletionScanner.removing(query: query, from: text)
            item.action?()
        }
        selectedCompletion = 0
        focusTrigger = UUID()
    }

    // MARK: - Queued turns

    private var queuedStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                Text(queuedTurns.count == 1 ? "1 queued" : "\(queuedTurns.count) queued")
                    .font(.caption)
                Spacer(minLength: 0)
                if queuedTurns.count > 1, let onMergeQueuedTurns {
                    Button("Merge", action: onMergeQueuedTurns)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(theme.accent)
                }
            }
            .foregroundStyle(theme.secondaryText)

            ForEach(queuedTurns) { turn in
                HStack(spacing: 6) {
                    Text(turn.text)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if let onRemoveQueuedTurn {
                        Button {
                            onRemoveQueuedTurn(turn.id)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.secondaryText)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(theme.toolChrome, in: .rect(cornerRadius: 7))
            }
        }
        .padding(.horizontal, 4)
        .accessibilityIdentifier("agent-composer-queue")
    }

    // MARK: - Attachments

    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 4) {
                        Image(systemName: "paperclip").font(.system(size: 10))
                        Text(attachment.label ?? "attachment").font(.caption).lineLimit(1)
                        if let onRemoveAttachment {
                            Button {
                                onRemoveAttachment(attachment)
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.toolChrome, in: .capsule)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Action button

    @ViewBuilder
    private var actionButton: some View {
        if isStreaming {
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(theme.danger, in: .circle)
            }
            .buttonStyle(.plain)
            .help("Stop")
            .accessibilityIdentifier("agent-composer-stop")
        } else {
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(canSend ? theme.accent : theme.secondaryText.opacity(0.4), in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send")
            .accessibilityIdentifier("agent-composer-send")
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sending while streaming is allowed: `Agent.send` queues it.
    private func submit() {
        guard canSend else { return }
        onSend()
        historyIndex = -1
    }

    // MARK: - Key handling

    private func handleReturn() {
        // A visible popup owns Enter — it is choosing a completion, not sending.
        if let query = activeQuery, !visibleItems(for: query).isEmpty {
            choose(index: selectedCompletion, query: query)
            return
        }
        submit()
    }

    private func handleTab() -> Bool {
        guard let query = activeQuery, !visibleItems(for: query).isEmpty else { return false }
        choose(index: selectedCompletion, query: query)
        return true
    }

    private func handleEscape() -> Bool {
        guard let query = activeQuery, !visibleItems(for: query).isEmpty else { return false }
        // Dismiss by removing the trigger: there is no separate "popup is open"
        // flag to clear, because the popup is a pure function of the text.
        text = AgentCompletionScanner.removing(query: query, from: text)
        return true
    }

    private func handleUpArrow() -> Bool {
        if let query = activeQuery, !visibleItems(for: query).isEmpty {
            selectedCompletion = max(0, selectedCompletion - 1)
            return true
        }
        return recallHistory(offset: 1)
    }

    private func handleDownArrow() -> Bool {
        if let query = activeQuery {
            let items = visibleItems(for: query)
            if !items.isEmpty {
                selectedCompletion = min(items.count - 1, selectedCompletion + 1)
                return true
            }
        }
        return recallHistory(offset: -1)
    }

    /// ↑/↓ through past prompts, newest first.
    ///
    /// Only from an empty draft or while already recalling — otherwise ↑ in the
    /// middle of a half-written message would throw it away.
    private func recallHistory(offset: Int) -> Bool {
        guard !history.isEmpty else { return false }
        guard historyIndex >= 0 || text.isEmpty else { return false }

        let next = historyIndex + offset
        if next < 0 {
            historyIndex = -1
            text = ""
            return true
        }
        guard next < history.count else { return true }

        historyIndex = next
        text = history[history.count - 1 - next]
        return true
    }

    // MARK: - Drop

    private var dropBinding: Binding<Bool> {
        Binding(
            get: { isDropTargeted },
            set: { value in
                guard onDropFiles != nil else { return }
                isDropTargeted = value
            }
        )
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let onDropFiles else { return false }

        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                guard let url = await provider.loadFileURL() else { continue }
                urls.append(url)
            }
            guard !urls.isEmpty else { return }
            _ = onDropFiles(urls)
        }
        return true
    }
}

// MARK: - Convenience initializer

public extension AgentComposer where Accessories == EmptyView {
    init(
        text: Binding<String>,
        attachments: [AgentAttachment] = [],
        isStreaming: Bool = false,
        placeholder: String = "Message the agent…",
        completions: [AgentCompletionSource] = [],
        queuedTurns: [Agent.QueuedTurn] = [],
        history: [String] = [],
        onSend: @escaping () -> Void,
        onStop: @escaping () -> Void = {},
        onRemoveAttachment: ((AgentAttachment) -> Void)? = nil,
        onRemoveQueuedTurn: ((UUID) -> Void)? = nil,
        onMergeQueuedTurns: (() -> Void)? = nil,
        onDropFiles: (([URL]) -> Bool)? = nil
    ) {
        self.init(
            text: text,
            attachments: attachments,
            isStreaming: isStreaming,
            placeholder: placeholder,
            completions: completions,
            queuedTurns: queuedTurns,
            history: history,
            onSend: onSend,
            onStop: onStop,
            onRemoveAttachment: onRemoveAttachment,
            onRemoveQueuedTurn: onRemoveQueuedTurn,
            onMergeQueuedTurns: onMergeQueuedTurns,
            onDropFiles: onDropFiles,
            accessories: { EmptyView() }
        )
    }
}

// MARK: - Item provider

private extension NSItemProvider {
    /// `loadItem` is a completion-handler API and can fire more than once in
    /// error paths, which would trap a continuation. The flag guards that.
    func loadFileURL() async -> URL? {
        guard hasItemConformingToTypeIdentifier("public.file-url") else { return nil }
        return await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                let alreadyResumed = resumed.withLock { state -> Bool in
                    if state { return true }
                    state = true
                    return false
                }
                guard !alreadyResumed else { return }

                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data {
                    continuation.resume(
                        returning: URL(dataRepresentation: data, relativeTo: nil)
                    )
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - Client picker

/// Switches the active client. One is active at a time; the transcript is
/// continuous across a switch.
public struct AgentClientPicker: View {
    private let clients: [any AgentClient]
    @Binding private var selection: AgentClientID

    @Environment(\.agentTheme) private var theme

    public init(clients: [any AgentClient], selection: Binding<AgentClientID>) {
        self.clients = clients
        self._selection = selection
    }

    public var body: some View {
        if clients.count > 1 {
            Picker("Agent", selection: $selection) {
                ForEach(clients, id: \.id) { client in
                    Text(client.displayName).tag(client.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("agent-client-picker")
        }
    }
}
