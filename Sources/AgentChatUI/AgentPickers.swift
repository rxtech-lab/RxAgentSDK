import RxAgentContext
import RxAgentCore
import SwiftUI

/// Picks how hard the active client should think.
///
/// Renders **nothing** when `levels` is empty. That is the normal state for a
/// client with no reasoning dial (most ACP agents, a gateway fronting a
/// non-reasoning model), and an empty menu reads as a broken control rather
/// than an absent feature.
///
/// The selection is the client's own wire value — see ``AgentReasoningOption``
/// — with `nil` meaning "leave the agent on its default", which is a real
/// choice and therefore always offered as the first row.
///
/// A host that wants these rows inside its own menu, or beside its own, builds
/// the control with ``AgentPickerBuilder`` instead.
public struct AgentReasoningPicker: View {
    private let levels: [AgentReasoningOption]
    @Binding private var selection: String?
    private let defaultLabel: String
    private let defaultRowTitle: String?
    private let style: AgentPickerStyle

    /// - Parameters:
    ///   - defaultLabel: What the control reads while nothing is picked.
    ///   - defaultRowTitle: What the row that clears the pick says, when that
    ///     differs from `defaultLabel`. A chip standing on its own wants both:
    ///     "Thinking" names the axis on the control, while the row has to say
    ///     what clearing does — "Engine default", or what Settings would send.
    public init(
        levels: [AgentReasoningOption],
        selection: Binding<String?>,
        defaultLabel: String = "Auto",
        defaultRowTitle: String? = nil,
        style: AgentPickerStyle = .chip(icon: "brain")
    ) {
        self.levels = levels
        self._selection = selection
        self.defaultLabel = defaultLabel
        self.defaultRowTitle = defaultRowTitle
        self.style = style
    }

    /// Reads the levels and the selection straight off the agent.
    public init(
        agent: Agent,
        defaultLabel: String = "Auto",
        defaultRowTitle: String? = nil,
        style: AgentPickerStyle = .chip(icon: "brain")
    ) {
        self.init(
            levels: agent.availableReasoningLevels,
            selection: Binding(get: { agent.effort }, set: { agent.effort = $0 }),
            defaultLabel: defaultLabel,
            defaultRowTitle: defaultRowTitle,
            style: style
        )
    }

    public var body: some View {
        AgentPickerBuilder(style: style, accessibilityName: "Reasoning effort")
            .thinkingLevels(
                levels,
                selection: $selection,
                defaultTitle: defaultRowTitle ?? defaultLabel,
                restingTitle: defaultLabel
            )
            .picker()
            .accessibilityIdentifier("agent-reasoning-picker")
    }
}

/// Picks the model the active client runs on.
///
/// Same contract as ``AgentReasoningPicker``: empty list, no control. A client
/// that publishes no catalogue (`availableModels()` returning `[]`, as an
/// OpenAI-compatible endpoint configured with one model does) leaves nothing
/// behind.
public struct AgentModelPicker: View {
    private let models: [AgentModelOption]
    @Binding private var selection: String?
    private let defaultLabel: String
    private let defaultRowTitle: String?
    private let style: AgentPickerStyle

    public init(
        models: [AgentModelOption],
        selection: Binding<String?>,
        defaultLabel: String = "Default model",
        defaultRowTitle: String? = nil,
        style: AgentPickerStyle = .chip(icon: "sparkles")
    ) {
        self.models = models
        self._selection = selection
        self.defaultLabel = defaultLabel
        self.defaultRowTitle = defaultRowTitle
        self.style = style
    }

    /// Reads the catalogue and the selection straight off the agent.
    ///
    /// The list is whatever ``Agent/availableModels`` last reported, so a host
    /// showing this outside ``AgentChatView`` should call
    /// ``Agent/refreshClientOptions()`` when its surface appears.
    public init(
        agent: Agent,
        defaultLabel: String = "Default model",
        defaultRowTitle: String? = nil,
        style: AgentPickerStyle = .chip(icon: "sparkles")
    ) {
        self.init(
            models: agent.availableModels,
            selection: Binding(get: { agent.model }, set: { agent.model = $0 }),
            defaultLabel: defaultLabel,
            defaultRowTitle: defaultRowTitle,
            style: style
        )
    }

    public var body: some View {
        AgentPickerBuilder(style: style, accessibilityName: "Model")
            .models(
                models,
                selection: $selection,
                defaultTitle: defaultRowTitle ?? defaultLabel,
                restingTitle: defaultLabel
            )
            .picker()
            .accessibilityIdentifier("agent-model-picker")
    }
}

#Preview("Pickers") {
    @Previewable @State var model: String? = "sonnet"
    @Previewable @State var claude: String? = "xhigh"
    @Previewable @State var codex: String? = nil

    VStack(alignment: .leading, spacing: 16) {
        AgentModelPicker(
            models: [
                AgentModelOption(id: "opus", displayName: "Opus", modelDescription: "Most capable."),
                AgentModelOption(id: "sonnet", displayName: "Sonnet", modelDescription: "Balanced."),
            ],
            selection: $model
        )
        AgentReasoningPicker(levels: .claudeCodeEfforts, selection: $claude)
        AgentReasoningPicker(levels: .codexEfforts, selection: $codex)

        // One control over both axes, the way a host composes it.
        AgentPickerBuilder(style: .chip(icon: "sparkles"))
            .models(
                [AgentModelOption(id: "gpt-5", displayName: "GPT-5")],
                selection: $model,
                title: "Model"
            )
            .thinkingLevels(.codexEfforts, selection: $codex, title: "Thinking")
            .picker()

        // A client with no reasoning dial draws nothing at all.
        AgentReasoningPicker(levels: [], selection: $codex)
    }
    .padding()
}
