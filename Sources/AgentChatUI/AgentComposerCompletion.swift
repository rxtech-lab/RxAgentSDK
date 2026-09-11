import SwiftUI

/// One row in a composer completion popup.
///
/// `insertion` and `action` are alternatives: a **mention** inserts a token into
/// the draft (`@caption:Opening titles`), while a **command** runs something and
/// leaves the draft empty (`/clear`). Both are the same popup, so both are the
/// same item type, with the distinction carried by which field is set.
public struct AgentCompletionItem: Identifiable, Sendable {
    public let id: String
    public var label: String
    public var detail: String?
    public var systemImage: String?
    /// Replaces the trigger and its query when chosen. `nil` when `action` runs
    /// instead.
    public var insertion: String?
    /// Run when chosen, in place of inserting text.
    public var action: (@MainActor @Sendable () -> Void)?

    public init(
        id: String,
        label: String,
        detail: String? = nil,
        systemImage: String? = nil,
        insertion: String? = nil,
        action: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.id = id
        self.label = label
        self.detail = detail
        self.systemImage = systemImage
        self.insertion = insertion
        self.action = action
    }
}

/// A completion source bound to a trigger character.
///
/// The composer watches for `trigger` at a word boundary, collects the
/// characters after it as a query, and asks `items` what to show. Filtering is
/// the source's job, not the composer's: only the host knows whether a project
/// should match on its name, its id, or its group.
public struct AgentCompletionSource: Sendable {
    public let trigger: Character
    /// Query → rows. Called on every keystroke while the popup is open, so it
    /// should be cheap; sort and cap the result here.
    public let items: @MainActor @Sendable (String) -> [AgentCompletionItem]

    public init(
        trigger: Character,
        items: @escaping @MainActor @Sendable (String) -> [AgentCompletionItem]
    ) {
        self.trigger = trigger
        self.items = items
    }
}

// MARK: - Trigger scanning

/// Where an open completion popup starts, and what has been typed since.
struct AgentCompletionQuery: Equatable {
    var trigger: Character
    /// Index of the trigger character itself.
    var triggerIndex: String.Index
    var query: String
}

enum AgentCompletionScanner {
    /// Finds an active trigger in `text`, scanning back from the end.
    ///
    /// A trigger only counts at a **word boundary** — the start of the draft or
    /// after whitespace. Without that rule an email address opens the mention
    /// popup on every keystroke, and a file path opens the command popup.
    ///
    /// The query stops at the first whitespace, so a popup closes as soon as the
    /// user moves past the token rather than accumulating the rest of the line.
    static func scan(_ text: String, triggers: Set<Character>) -> AgentCompletionQuery? {
        guard !text.isEmpty, !triggers.isEmpty else { return nil }

        var index = text.endIndex
        var query = ""

        while index > text.startIndex {
            let previous = text.index(before: index)
            let character = text[previous]

            if triggers.contains(character) {
                let isAtBoundary = previous == text.startIndex
                    || text[text.index(before: previous)].isWhitespace
                guard isAtBoundary else { return nil }
                return AgentCompletionQuery(
                    trigger: character,
                    triggerIndex: previous,
                    query: query
                )
            }

            if character.isWhitespace { return nil }

            query.insert(character, at: query.startIndex)
            index = previous
        }

        return nil
    }

    /// Replaces the trigger and its query with `insertion`, plus a trailing
    /// space so the next word starts cleanly.
    static func applying(
        _ insertion: String,
        to text: String,
        query: AgentCompletionQuery
    ) -> String {
        String(text[text.startIndex ..< query.triggerIndex]) + insertion + " "
    }

    /// Removes the trigger and its query entirely. Used when a command runs
    /// instead of inserting.
    static func removing(query: AgentCompletionQuery, from text: String) -> String {
        String(text[text.startIndex ..< query.triggerIndex])
    }
}

// MARK: - Popup

/// The floating list of completions.
///
/// Drawn as an overlay anchored above the field rather than inserted into the
/// layout, so opening it never reflows the transcript behind it.
struct AgentCompletionPopup: View {
    let items: [AgentCompletionItem]
    let selectedIndex: Int
    let onChoose: (Int) -> Void

    @Environment(\.agentTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item, isSelected: index == selectedIndex)
                    .contentShape(.rect)
                    .onTapGesture { onChoose(index) }
            }
        }
        .padding(4)
        .background {
            RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                .strokeBorder(theme.toolBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .frame(maxWidth: 380, alignment: .leading)
        .accessibilityIdentifier("agent-composer-completions")
    }

    private func row(_ item: AgentCompletionItem, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            if let systemImage = item.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
                    .frame(width: 14)
            }
            Text(item.label)
                .font(.system(size: 13))
                .lineLimit(1)
            if let detail = item.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.accent.opacity(0.16))
            }
        }
    }
}
