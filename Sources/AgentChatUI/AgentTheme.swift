import AgentMarkdownUI
import RxAgentUISupport
import SwiftUI

/// Colors, fonts and metrics for the chat surface.
///
/// Deliberately small and brand-neutral: the point is that a host app can
/// restyle the chat without forking any views.
public struct AgentTheme: Sendable {
    public var userBubble: Color
    public var userText: Color
    public var assistantText: Color
    public var secondaryText: Color
    public var toolChrome: Color
    public var toolBorder: Color
    public var accent: Color
    public var danger: Color
    public var background: Color
    /// Ground behind the transcript itself.
    ///
    /// Separate from ``background`` and **clear by default**: the list already
    /// sits on top of that one, so painting it again buys nothing and costs a
    /// host the ability to put a material, an image, or the window's own
    /// vibrancy behind the conversation. Set it only when the transcript wants
    /// a different ground from the rest of the surface.
    public var listBackground: Color
    public var monoFont: Font
    public var markdown: MarkdownStyle
    public var cornerRadius: CGFloat
    public var rowPadding: EdgeInsets
    /// How tall the composer's field is: it rests at the lower bound and grows
    /// with the draft to the upper bound, then scrolls.
    public var composerLines: ClosedRange<Int>

    public init(
        userBubble: Color,
        userText: Color,
        assistantText: Color,
        secondaryText: Color,
        toolChrome: Color,
        toolBorder: Color,
        accent: Color,
        danger: Color,
        background: Color,
        monoFont: Font,
        markdown: MarkdownStyle,
        cornerRadius: CGFloat,
        rowPadding: EdgeInsets,
        listBackground: Color = .clear,
        composerLines: ClosedRange<Int> = 5 ... 12
    ) {
        self.userBubble = userBubble
        self.userText = userText
        self.assistantText = assistantText
        self.secondaryText = secondaryText
        self.toolChrome = toolChrome
        self.toolBorder = toolBorder
        self.accent = accent
        self.danger = danger
        self.background = background
        self.monoFont = monoFont
        self.markdown = markdown
        self.cornerRadius = cornerRadius
        self.rowPadding = rowPadding
        self.listBackground = listBackground
        self.composerLines = composerLines
    }

    public static let standard: AgentTheme = {
        var markdown = MarkdownStyle()
        markdown.bodyFontSize = 14
        return AgentTheme(
            userBubble: Color(light: .hex(0xEEF2FF), dark: .hex(0x27314F)),
            userText: Color(light: .hex(0x111827), dark: .hex(0xF3F4F6)),
            assistantText: Color(light: .hex(0x111827), dark: .hex(0xE5E7EB)),
            secondaryText: Color(light: .hex(0x6B7280), dark: .hex(0x9CA3AF)),
            toolChrome: Color(light: .hex(0xF6F7F9), dark: .hex(0x1C1F26)),
            toolBorder: Color(light: .hex(0xE3E6EB), dark: .hex(0x2E333D)),
            accent: Color(light: .hex(0x2563EB), dark: .hex(0x60A5FA)),
            danger: Color(light: .hex(0xB91C1C), dark: .hex(0xF87171)),
            background: Color(light: .hex(0xFFFFFF), dark: .hex(0x101317)),
            monoFont: .system(size: 12, design: .monospaced),
            markdown: markdown,
            cornerRadius: 10,
            rowPadding: EdgeInsets(top: 8, leading: 20, bottom: 20, trailing: 20)
        )
    }()

    public static let compact: AgentTheme = {
        var theme = AgentTheme.standard
        theme.markdown.bodyFontSize = 13
        theme.markdown.blockSpacing = 8
        theme.cornerRadius = 8
        theme.rowPadding = EdgeInsets(top: 4, leading: 12, bottom: 12, trailing: 12)
        return theme
    }()
}

extension EnvironmentValues {
    @Entry public var agentTheme: AgentTheme = .standard
}

public extension View {
    func agentTheme(_ theme: AgentTheme) -> some View {
        environment(\.agentTheme, theme)
    }
}


// MARK: - Range clamping

extension ClosedRange where Bound == Int {
    /// `value`, brought inside the range.
    func clamping(_ value: Int) -> Int {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
