import AgentMarkdownUI
import RxAgentCore
import SwiftUI

/// A tool call: collapsible header plus a body rendered per tool kind.
///
/// The typed bodies are the point. A `Bash` call shown as raw JSON is unreadable;
/// shown as a terminal line with its output underneath it is obvious at a glance.
struct AgentToolCallRow: View {
    let call: AgentToolCall

    @State private var isExpanded = false
    @Environment(\.agentTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider().overlay(theme.toolBorder)
                body(for: call)
                    .padding(10)
            }
        }
        .background(theme.toolChrome, in: .rect(cornerRadius: theme.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .strokeBorder(theme.toolBorder, lineWidth: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)

                Image(systemName: call.category.systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.accent)

                Text(call.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.assistantText)

                if let summary {
                    Text(summary)
                        .font(theme.monoFont)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
                statusIndicator
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tool-call-\(call.name)")
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if call.isError {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(theme.danger)
        } else if call.isComplete {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(theme.accent.opacity(0.7))
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// A one-line gist for the collapsed header.
    private var summary: String? {
        guard call.hasCompleteInput else { return nil }
        switch call.name.lowercased() {
        case "bash":
            return call.input["command"]?.stringValue
        case "read", "edit", "write", "multiedit":
            return call.input["file_path"]?.stringValue.map {
                URL(filePath: $0).lastPathComponent
            }
        case "grep":
            return call.input["pattern"]?.stringValue
        case "todowrite":
            let count = call.input["todos"]?.arrayValue?.count ?? 0
            return "\(count) items"
        default:
            return nil
        }
    }

    // MARK: Bodies

    @ViewBuilder
    private func body(for call: AgentToolCall) -> some View {
        switch call.name.lowercased() {
        case "bash":
            bashBody
        case "edit", "write", "multiedit":
            diffBody
        case "read":
            fileBody
        case "todowrite":
            todoBody
        default:
            genericBody
        }
    }

    private var bashBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let command = call.input["command"]?.stringValue {
                Text("$ \(command)")
                    .font(theme.monoFont)
                    .foregroundStyle(theme.assistantText)
                    .textSelection(.enabled)
            }
            if let result = call.result, !result.isEmpty {
                outputBlock(result)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var diffBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let path = call.input["file_path"]?.stringValue {
                Text(path)
                    .font(theme.monoFont)
                    .foregroundStyle(theme.secondaryText)
                    .textSelection(.enabled)
            }
            ForEach(Array(diffPairs.enumerated()), id: \.offset) { _, pair in
                AgentDiffView(oldText: pair.old, newText: pair.new)
            }
            if let result = call.result, !result.isEmpty, diffPairs.isEmpty {
                outputBlock(result)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Normalized across Write (content only), Edit (one pair) and MultiEdit
    /// (an `edits` array) — the three names every provider is mapped onto.
    private var diffPairs: [(old: String, new: String)] {
        if let edits = call.input["edits"]?.arrayValue {
            return edits.map {
                ($0["old_string"]?.stringValue ?? "", $0["new_string"]?.stringValue ?? "")
            }
        }
        if let content = call.input["content"]?.stringValue {
            return [("", content)]
        }
        if let old = call.input["old_string"]?.stringValue,
           let new = call.input["new_string"]?.stringValue {
            return [(old, new)]
        }
        return []
    }

    private var fileBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let path = call.input["file_path"]?.stringValue {
                Label(path, systemImage: "doc.text")
                    .font(theme.monoFont)
                    .foregroundStyle(theme.secondaryText)
                    .textSelection(.enabled)
            }
            if let result = call.result, !result.isEmpty {
                outputBlock(result)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var todoBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(TodoExtractor.parse(todoWriteInput: call.input)) { todo in
                AgentTodoRow(todo: todo)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var genericBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if call.hasCompleteInput, !call.input.isEmpty {
                Text(JSONValue.object(call.input).jsonString)
                    .font(theme.monoFont)
                    .foregroundStyle(theme.secondaryText)
                    .textSelection(.enabled)
            }
            if let result = call.result, !result.isEmpty {
                outputBlock(result)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func outputBlock(_ text: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(theme.monoFont)
                .foregroundStyle(call.isError ? theme.danger : theme.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: 220)
    }
}

// MARK: - Diff

/// A minimal line-level diff. Enough to see what changed without pulling in a
/// diffing dependency.
struct AgentDiffView: View {
    let oldText: String
    let newText: String

    @Environment(\.agentTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 6) {
                    Text(line.marker)
                        .font(theme.monoFont)
                        .foregroundStyle(color(for: line.kind))
                        .frame(width: 10, alignment: .leading)
                    Text(line.text)
                        .font(theme.monoFont)
                        .foregroundStyle(theme.assistantText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(background(for: line.kind))
            }
        }
        .clipShape(.rect(cornerRadius: 6))
    }

    private enum Kind { case removed, added }
    private struct Line {
        let kind: Kind
        let text: String
        var marker: String { kind == .removed ? "−" : "+" }
    }

    private var lines: [Line] {
        var result: [Line] = []
        if !oldText.isEmpty {
            result += oldText.components(separatedBy: "\n").map { Line(kind: .removed, text: $0) }
        }
        if !newText.isEmpty {
            result += newText.components(separatedBy: "\n").map { Line(kind: .added, text: $0) }
        }
        // Long files would otherwise blow out the row.
        return Array(result.prefix(60))
    }

    private func color(for kind: Kind) -> Color {
        kind == .removed ? theme.danger : theme.accent
    }

    private func background(for kind: Kind) -> Color {
        (kind == .removed ? theme.danger : theme.accent).opacity(0.08)
    }
}

// MARK: - Todos

struct AgentTodoRow: View {
    let todo: TodoItem
    @Environment(\.agentTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(todo.status == .completed ? theme.accent : theme.secondaryText)
            Text(todo.status == .inProgress ? todo.activeForm : todo.content)
                .font(.callout)
                .foregroundStyle(theme.assistantText)
                .strikethrough(todo.status == .completed, color: theme.secondaryText)
            Spacer(minLength: 0)
        }
    }

    private var symbol: String {
        switch todo.status {
        case .completed: "checkmark.circle.fill"
        case .inProgress: "circle.dotted"
        case .pending: "circle"
        }
    }
}

/// The compact todo strip shown above the composer.
struct AgentTodoStrip: View {
    let todos: [TodoItem]
    @Environment(\.agentTheme) private var theme

    var body: some View {
        if let active = todos.first(where: { $0.status == .inProgress }) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(active.activeForm)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(completedCount)/\(todos.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            // A floating pill, not a full-width bar: it sits over the transcript
            // just above the composer, so it must not read as a docked strip.
            .background {
                let shape = Capsule(style: .continuous)
                shape.fill(.ultraThinMaterial)
                    .overlay { shape.fill(theme.toolChrome.opacity(0.6)) }
                    .overlay { shape.strokeBorder(theme.toolBorder, lineWidth: 1) }
            }
            .clipShape(.capsule(style: .continuous))
            .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
        }
    }

    private var completedCount: Int {
        todos.filter { $0.status == .completed }.count
    }
}
