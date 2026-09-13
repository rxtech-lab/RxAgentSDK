import RxAgentCore
import SwiftUI

// MARK: - Item

/// One row in an agent picker: a model, a thinking level, or anything else a
/// host wants to offer beside them.
///
/// Deliberately *not* generic over the SDK's own option types. A host that
/// discovers its models from a CLI, or its levels from a gateway, has its own
/// catalogue types — the picker only needs an id it can write back, something to
/// read, and optionally a line explaining when to reach for it.
public struct AgentPickerItem: Identifiable, Hashable, Sendable {
    /// The value written to the selection. For a model this is what goes to
    /// `--model`; for a thinking level, the client's own wire spelling.
    public let id: String
    public var title: String
    /// One line of rationale. Shown as the row's tooltip, and under the title
    /// when the style asks for subtitles.
    public var subtitle: String?
    public var systemImage: String?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
    }

    public init(_ model: AgentModelOption) {
        self.init(id: model.id, title: model.displayName, subtitle: model.modelDescription)
    }

    public init(_ level: AgentReasoningOption) {
        self.init(id: level.id, title: level.displayName, subtitle: level.levelDescription)
    }
}

public extension [AgentPickerItem] {
    static func models(_ options: [AgentModelOption]) -> [AgentPickerItem] {
        options.map(AgentPickerItem.init)
    }

    static func levels(_ options: [AgentReasoningOption]) -> [AgentPickerItem] {
        options.map(AgentPickerItem.init)
    }
}

// MARK: - Style

/// How an agent picker looks. The knobs a host actually reaches for when
/// fitting these controls into its own chrome — everything else is inherited
/// from ``AgentTheme`` and the surrounding container.
public struct AgentPickerStyle: Sendable, Hashable {
    /// Leading glyph on the control itself. `nil` draws text alone.
    public var systemImage: String?
    public var font: Font
    /// Whether the control paints itself in the theme's accent once the user has
    /// chosen something other than the default.
    public var tintsWhenSet: Bool
    /// macOS: strip the menu's button chrome so the control reads as a label.
    /// Ignored on iOS, where a menu already renders that way.
    public var isBorderless: Bool
    /// Draw each row's `subtitle` under its title instead of only as a tooltip.
    public var showsSubtitles: Bool

    public init(
        systemImage: String? = nil,
        font: Font = .caption,
        tintsWhenSet: Bool = true,
        isBorderless: Bool = true,
        showsSubtitles: Bool = false
    ) {
        self.systemImage = systemImage
        self.font = font
        self.tintsWhenSet = tintsWhenSet
        self.isBorderless = isBorderless
        self.showsSubtitles = showsSubtitles
    }

    /// A compact glyph-and-text control, sized to its content. What the chat
    /// header uses.
    public static func chip(
        icon: String?,
        font: Font = .caption,
        showsSubtitles: Bool = false
    ) -> AgentPickerStyle {
        AgentPickerStyle(systemImage: icon, font: font, showsSubtitles: showsSubtitles)
    }

    public static let chip = AgentPickerStyle()
    /// Ordinary control chrome, for a settings pane rather than a toolbar.
    public static let bordered = AgentPickerStyle(isBorderless: false, showsSubtitles: false)
}

// MARK: - Section

/// One selectable group of rows: its own items, its own selection.
///
/// Several can share a menu — that is how an engine's models and its thinking
/// levels end up under one control instead of two.
public struct AgentPickerSection: Identifiable {
    /// How a section sits in a menu that has more than one.
    public enum Presentation: Sendable, Hashable {
        /// Rows inline, under a header when `title` is set.
        case inline
        /// Rows behind a submenu named by `title`.
        case submenu
    }

    public let id: String
    public var title: String?
    public var items: [AgentPickerItem]
    /// Title of the leading row that clears the selection — "Auto", "Default
    /// model", "Engine default". `nil` omits it, for a selection that must
    /// always name something.
    public var defaultTitle: String?
    /// What a *control* calls this section while nothing is picked, when that
    /// differs from the clearing row's own title.
    ///
    /// A standalone chip wants those to differ: the control should read
    /// "Thinking" at rest — it is the only thing naming the axis — while the row
    /// inside it has to say what clearing actually does ("Engine default").
    /// `nil` uses ``defaultTitle`` for both.
    public var restingTitle: String?
    public var selection: Binding<String?>
    public var presentation: Presentation

    public init(
        id: String? = nil,
        title: String? = nil,
        items: [AgentPickerItem],
        defaultTitle: String? = "Default",
        restingTitle: String? = nil,
        selection: Binding<String?>,
        presentation: Presentation = .inline
    ) {
        self.id = id ?? title ?? "section"
        self.title = title
        self.items = items
        self.defaultTitle = defaultTitle
        self.restingTitle = restingTitle
        self.selection = selection
        self.presentation = presentation
    }

    /// The row matching the current selection, or `nil` when it is the default
    /// (or names something no longer offered).
    public var selected: AgentPickerItem? {
        guard let value = selection.wrappedValue else { return nil }
        return items.first { $0.id == value }
    }

    /// What a control should call this section right now.
    public var selectionTitle: String? {
        selected?.title ?? restingTitle ?? defaultTitle
    }
}

// MARK: - Rows

/// The rows of one section, without a menu around them.
///
/// The embedding hook: a host that already has its own `Menu` — nested engine
/// submenus, app-specific rows — adds a thinking-level or model group to it
/// without giving up the menu it built.
///
/// ```swift
/// Menu { myEngineRows; Divider(); AgentPickerRows(thinkingSection) } label: { … }
/// ```
public struct AgentPickerRows: View {
    private let section: AgentPickerSection
    private let showsSubtitles: Bool

    public init(_ section: AgentPickerSection, showsSubtitles: Bool = false) {
        self.section = section
        self.showsSubtitles = showsSubtitles
    }

    public init(
        items: [AgentPickerItem],
        selection: Binding<String?>,
        defaultTitle: String? = "Default",
        showsSubtitles: Bool = false
    ) {
        self.init(
            AgentPickerSection(items: items, defaultTitle: defaultTitle, selection: selection),
            showsSubtitles: showsSubtitles
        )
    }

    public var body: some View {
        if let defaultTitle = section.defaultTitle {
            row(id: nil, title: defaultTitle, subtitle: nil)
            if !section.items.isEmpty { Divider() }
        }
        ForEach(section.items) { item in
            row(id: item.id, title: item.title, subtitle: item.subtitle)
        }
    }

    /// A checkmark rather than a `Picker`: the rows have to survive being
    /// dropped into a host's menu next to unrelated buttons, and a `Picker`'s
    /// selection styling does not travel that way.
    @ViewBuilder
    private func row(id: String?, title: String, subtitle: String?) -> some View {
        Button {
            section.selection.wrappedValue = id
        } label: {
            if section.selection.wrappedValue == id {
                Label(rowTitle(title, subtitle: subtitle), systemImage: "checkmark")
            } else {
                Text(rowTitle(title, subtitle: subtitle))
            }
        }
        .help(subtitle ?? "")
    }

    /// Menu rows are one line, so a shown subtitle joins the title rather than
    /// stacking under it, where SwiftUI would drop it on macOS.
    private func rowTitle(_ title: String, subtitle: String?) -> String {
        guard showsSubtitles, let subtitle, !subtitle.isEmpty else { return title }
        return "\(title) — \(subtitle)"
    }
}

// MARK: - Menu

/// A menu over one or more ``AgentPickerSection``s.
///
/// Renders nothing when every section is empty: a client with no models to
/// offer and no thinking dial should leave no inert control behind.
public struct AgentOptionMenu: View {
    /// What the control itself says.
    public enum Label: Sendable, Hashable {
        /// The sections' own selections, joined — "Sonnet · High".
        case automatic
        /// A fixed string the host composes itself.
        case text(String)
    }

    private let label: Label
    private let sections: [AgentPickerSection]
    private let style: AgentPickerStyle
    private let accessibilityName: String

    @Environment(\.agentTheme) private var theme

    public init(
        label: Label = .automatic,
        sections: [AgentPickerSection],
        style: AgentPickerStyle = .chip,
        accessibilityName: String = "Agent options"
    ) {
        self.label = label
        self.sections = sections
        self.style = style
        self.accessibilityName = accessibilityName
    }

    public var body: some View {
        if sections.contains(where: { !$0.items.isEmpty }) {
            Menu {
                content
            } label: {
                chip
            }
            .agentPickerChrome(borderless: style.isBorderless)
            .fixedSize()
            .help(helpText)
            .accessibilityLabel(accessibilityName)
            .accessibilityValue(labelText)
        }
    }

    @ViewBuilder
    private var content: some View {
        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
            switch section.presentation {
            case .submenu:
                Menu(section.title ?? "") {
                    AgentPickerRows(section, showsSubtitles: style.showsSubtitles)
                }
            case .inline:
                if let title = section.title {
                    Section(title) {
                        AgentPickerRows(section, showsSubtitles: style.showsSubtitles)
                    }
                } else {
                    if index > 0 { Divider() }
                    AgentPickerRows(section, showsSubtitles: style.showsSubtitles)
                }
            }
        }
    }

    private var chip: some View {
        SwiftUI.Label {
            Text(labelText)
        } icon: {
            if let systemImage = style.systemImage {
                Image(systemName: systemImage)
            }
        }
        .font(style.font)
        .foregroundStyle(tint)
    }

    private var tint: Color {
        guard style.tintsWhenSet else { return theme.secondaryText }
        let isSet = sections.contains { $0.selection.wrappedValue != nil }
        return isSet ? theme.accent : theme.secondaryText
    }

    private var labelText: String {
        switch label {
        case .text(let text):
            return text
        case .automatic:
            let parts = sections.compactMap(\.selectionTitle)
            return parts.isEmpty ? accessibilityName : parts.joined(separator: " · ")
        }
    }

    /// The control is a couple of words wide, so the chosen rows' rationale goes
    /// in the tooltip rather than being dropped.
    private var helpText: String {
        let lines = sections.compactMap { section -> String? in
            guard let selected = section.selected else { return nil }
            guard let subtitle = selected.subtitle, !subtitle.isEmpty else { return selected.title }
            return "\(selected.title) — \(subtitle)"
        }
        return lines.isEmpty ? accessibilityName : lines.joined(separator: "\n")
    }
}

// MARK: - Builder

/// Assembles a picker section by section.
///
/// The point of entry for a host building its own control: the SDK's model and
/// thinking-level rows, the host's own rows, one menu, one label, one style.
///
/// ```swift
/// AgentPickerBuilder(style: .chip(icon: "sparkles"))
///     .label("Codex · GPT-5.5")
///     .models(catalog.options(for: .codex), selection: $model, defaultTitle: "Default model")
///     .thinkingLevels(.describing(levels), selection: $effort, defaultTitle: "Engine default")
///     .picker()
/// ```
///
/// Every method returns a copy, so a builder can be held as a value and
/// finished differently in two places.
public struct AgentPickerBuilder {
    private var label: AgentOptionMenu.Label
    private var style: AgentPickerStyle
    private var accessibilityName: String
    private var sections: [AgentPickerSection] = []

    public init(
        style: AgentPickerStyle = .chip,
        accessibilityName: String = "Agent options"
    ) {
        self.label = .automatic
        self.style = style
        self.accessibilityName = accessibilityName
    }

    // MARK: Chrome

    public func label(_ text: String) -> Self {
        var copy = self
        copy.label = .text(text)
        return copy
    }

    /// Label from the sections' own selections. The default.
    public func automaticLabel() -> Self {
        var copy = self
        copy.label = .automatic
        return copy
    }

    public func style(_ style: AgentPickerStyle) -> Self {
        var copy = self
        copy.style = style
        return copy
    }

    public func accessibilityName(_ name: String) -> Self {
        var copy = self
        copy.accessibilityName = name
        return copy
    }

    // MARK: Sections

    public func section(_ section: AgentPickerSection) -> Self {
        var copy = self
        copy.sections.append(section)
        return copy
    }

    public func section(
        title: String? = nil,
        items: [AgentPickerItem],
        selection: Binding<String?>,
        defaultTitle: String? = "Default",
        restingTitle: String? = nil,
        presentation: AgentPickerSection.Presentation = .inline
    ) -> Self {
        section(AgentPickerSection(
            title: title,
            items: items,
            defaultTitle: defaultTitle,
            restingTitle: restingTitle,
            selection: selection,
            presentation: presentation
        ))
    }

    public func models(
        _ options: [AgentModelOption],
        selection: Binding<String?>,
        title: String? = nil,
        defaultTitle: String? = "Default model",
        restingTitle: String? = nil,
        presentation: AgentPickerSection.Presentation = .inline
    ) -> Self {
        section(
            title: title,
            items: .models(options),
            selection: selection,
            defaultTitle: defaultTitle,
            restingTitle: restingTitle,
            presentation: presentation
        )
    }

    public func thinkingLevels(
        _ levels: [AgentReasoningOption],
        selection: Binding<String?>,
        title: String? = nil,
        defaultTitle: String? = "Auto",
        restingTitle: String? = nil,
        presentation: AgentPickerSection.Presentation = .inline
    ) -> Self {
        section(
            title: title,
            items: .levels(levels),
            selection: selection,
            defaultTitle: defaultTitle,
            restingTitle: restingTitle,
            presentation: presentation
        )
    }

    // MARK: Output

    /// The finished control.
    public func picker() -> AgentOptionMenu {
        AgentOptionMenu(
            label: label,
            sections: sections,
            style: style,
            accessibilityName: accessibilityName
        )
    }

    /// The rows alone, for dropping into a menu the host already owns.
    @ViewBuilder
    public func rows() -> some View {
        ForEach(sections) { section in
            if let title = section.title {
                Section(title) {
                    AgentPickerRows(section, showsSubtitles: style.showsSubtitles)
                }
            } else {
                AgentPickerRows(section, showsSubtitles: style.showsSubtitles)
            }
        }
    }
}

// MARK: - Chrome

extension View {
    /// `BorderlessButtonMenuStyle` is macOS-only; an iOS menu already renders as
    /// a plain tappable label.
    @ViewBuilder
    func agentPickerChrome(borderless: Bool) -> some View {
        #if os(macOS)
        if borderless {
            menuStyle(.borderlessButton)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
