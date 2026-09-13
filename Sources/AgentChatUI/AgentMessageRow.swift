import AgentMarkdownUI
import RxAgentCore
import SwiftUI

/// One transcript row: a user bubble, an assistant response, or a collapsed
/// group of transient tool calls.
public struct AgentMessageRow: View {
    private let item: AgentTranscriptItem
    @Environment(\.agentTheme) private var theme

    public init(item: AgentTranscriptItem) {
        self.item = item
    }

    public var body: some View {
        switch item.kind {
        case .message(let message):
            AgentMessageBubble(message: message)
        case .transientGroup(let calls):
            AgentTransientGroupRow(calls: calls)
        case .accessory:
            EmptyView()
        }
    }
}

// MARK: - Bubble

struct AgentMessageBubble: View {
    let message: AgentMessage
    @Environment(\.agentTheme) private var theme

    var body: some View {
        switch message.role {
        case .user:
            userBubble
        case .assistant, .system:
            assistantContent
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 6) {
                MarkdownView(text: message.plainText, style: theme.markdown)
                    .textSelection(.enabled)
                if !message.attachments.isEmpty {
                    attachmentChips
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(theme.userBubble, in: .rect(cornerRadius: theme.cornerRadius))
        }
    }

    private var attachmentChips: some View {
        HStack(spacing: 6) {
            ForEach(message.attachments) { attachment in
                AgentAttachmentPreview(attachment: attachment)
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    private var assistantContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(renderBlocks, id: \.id) { block in
                switch block {
                case .text(_, let text):
                    MarkdownView(
                        text: text,
                        showsTrailingCursor: message.isStreaming && block.id == renderBlocks.last?.id,
                        style: theme.markdown,
                        fadeNewText: message.isStreaming
                    )
                    .textSelection(.enabled)

                case .thinking(_, let text):
                    AgentThinkingBlock(text: text, isStreaming: message.isStreaming)

                case .toolCall(let call):
                    AgentToolCallRow(call: call)
                }
            }

            if let error = message.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(theme.danger)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Merge adjacent text blocks so a tool call in the middle of a sentence
    /// doesn't split the prose into two paragraphs.
    private var renderBlocks: [AgentBlock] {
        var result: [AgentBlock] = []
        for block in message.blocks {
            if case .text(let id, let text) = block,
               case .text(let previousID, let previous)? = result.last {
                result[result.count - 1] = .text(id: previousID, previous + text)
                _ = id
            } else {
                result.append(block)
            }
        }
        return result
    }
}

// MARK: - Thinking

struct AgentThinkingBlock: View {
    let text: String
    let isStreaming: Bool

    @State private var isExpanded = false
    @Environment(\.agentTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Image(systemName: "brain")
                        .font(.system(size: 10))
                    Text(isStreaming ? "Thinking…" : "Thought process")
                        .font(.caption)
                }
                .foregroundStyle(theme.secondaryText)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
                    .textSelection(.enabled)
                    .padding(.leading, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Transient group

/// Collapsed summary of a run of read-only tool calls.
struct AgentTransientGroupRow: View {
    let calls: [AgentToolCall]

    @State private var isExpanded = false
    @Environment(\.agentTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Image(systemName: "eye.slash")
                        .font(.system(size: 10))
                    Text("\(calls.count) tool calls")
                        .font(.caption)
                }
                .foregroundStyle(theme.secondaryText)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(calls) { call in
                        AgentToolCallRow(call: call)
                    }
                }
                .padding(.leading, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
