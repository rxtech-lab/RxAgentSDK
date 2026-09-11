import RxAgentCore
import SwiftUI

/// The input area: text, attachments, send / stop.
public struct AgentComposer: View {
    @Binding private var text: String
    private let attachments: [AgentAttachment]
    private let isStreaming: Bool
    private let placeholder: String
    private let onSend: () -> Void
    private let onStop: () -> Void
    private let onRemoveAttachment: ((AgentAttachment) -> Void)?

    @FocusState private var isFocused: Bool
    @Environment(\.agentTheme) private var theme

    public init(
        text: Binding<String>,
        attachments: [AgentAttachment] = [],
        isStreaming: Bool = false,
        placeholder: String = "Message the agent…",
        onSend: @escaping () -> Void,
        onStop: @escaping () -> Void = {},
        onRemoveAttachment: ((AgentAttachment) -> Void)? = nil
    ) {
        self._text = text
        self.attachments = attachments
        self.isStreaming = isStreaming
        self.placeholder = placeholder
        self.onSend = onSend
        self.onStop = onStop
        self.onRemoveAttachment = onRemoveAttachment
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty { attachmentRow }

            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($isFocused)
                    .font(.system(size: 14))
                    .onSubmit(submit)
                    .accessibilityIdentifier("agent-composer-field")

                actionButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            // Floats over the transcript, so it is glass rather than a solid
            // slab: the material lets content read through faintly while still
            // keeping the text legible. The tint keeps it on-theme.
            .background {
                fieldShape
                    .fill(.ultraThinMaterial)
                    .overlay { fieldShape.fill(theme.toolChrome.opacity(0.55)) }
            }
            .overlay {
                fieldShape
                    .strokeBorder(
                        isFocused ? theme.accent.opacity(0.5) : theme.toolBorder,
                        lineWidth: 1
                    )
            }
            .clipShape(fieldShape)
            .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .onAppear { isFocused = true }
    }

    /// Softer and rounder than a row card — it has to read as floating.
    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.cornerRadius + 8, style: .continuous)
    }

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
            .keyboardShortcut(.return, modifiers: [])
            .help("Send")
            .accessibilityIdentifier("agent-composer-send")
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSend, !isStreaming else { return }
        onSend()
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
