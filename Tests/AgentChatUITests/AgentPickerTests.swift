import RxAgentCore
import SwiftUI
import Testing
import ViewInspector
@testable import AgentChatUI

@MainActor
@Suite("Agent pickers")
struct AgentPickerTests {

    /// Rows are `Button`s rather than a `Picker`'s: they have to survive being
    /// dropped into a host's own menu beside unrelated rows.
    private func rowTitles(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Button.self).map { button in
            let label = try button.labelView()
            if let text = try? label.text().string() { return text }
            return try label.label().title().text().string()
        }
    }

    // MARK: Reasoning

    /// A client with no reasoning dial must produce no control at all: an empty
    /// menu in the header reads as broken, not absent.
    @Test("No levels means no control")
    func emptyLevelsDrawNothing() throws {
        var selection: String?
        let picker = AgentReasoningPicker(
            levels: [],
            selection: Binding(get: { selection }, set: { selection = $0 })
        )
        #expect(throws: (any Error).self) {
            try picker.inspect().find(ViewType.Menu.self)
        }
    }

    @Test("Every level plus the agent's own default is offered")
    func offersEveryLevelAndTheDefault() throws {
        var selection: String? = "high"
        let picker = AgentReasoningPicker(
            levels: .codexEfforts,
            selection: Binding(get: { selection }, set: { selection = $0 })
        )
        #expect(try rowTitles(picker) == ["Auto", "Minimal", "Low", "Medium", "High"])
    }

    @Test("The control names the selected level, or the default when none is set")
    func reasoningLabel() throws {
        var selection: String? = "xhigh"
        let chosen = AgentReasoningPicker(
            levels: .claudeCodeEfforts,
            selection: Binding(get: { selection }, set: { selection = $0 })
        )
        #expect(try chosen.inspect().find(ViewType.Menu.self)
            .labelView().find(ViewType.Text.self).string() == "Extra High")

        var none: String?
        let unset = AgentReasoningPicker(
            levels: .claudeCodeEfforts,
            selection: Binding(get: { none }, set: { none = $0 }),
            defaultLabel: "Auto"
        )
        #expect(try unset.inspect().find(ViewType.Menu.self)
            .labelView().find(ViewType.Text.self).string() == "Auto")
    }

    /// A chip standing on its own has to name the axis at rest ("Thinking"),
    /// while the row inside it says what clearing actually does.
    @Test("The control's resting text and the clearing row can differ")
    func restingTextDiffersFromTheRow() throws {
        var selection: String?
        let picker = AgentReasoningPicker(
            levels: .codexEfforts,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            defaultLabel: "Thinking",
            defaultRowTitle: "Engine default"
        )

        #expect(try picker.inspect().find(ViewType.Menu.self)
            .labelView().find(ViewType.Text.self).string() == "Thinking")
        #expect(try rowTitles(picker).first == "Engine default")

        // Once a level is picked, the control names the level rather than the axis.
        selection = "high"
        #expect(try picker.inspect().find(ViewType.Menu.self)
            .labelView().find(ViewType.Text.self).string() == "High")
    }

    // MARK: Models

    @Test("The model picker offers the catalogue plus a default row")
    func modelRows() throws {
        var selection: String? = "sonnet"
        let picker = AgentModelPicker(
            models: [
                AgentModelOption(id: "opus", displayName: "Opus"),
                AgentModelOption(id: "sonnet", displayName: "Sonnet"),
            ],
            selection: Binding(get: { selection }, set: { selection = $0 })
        )
        #expect(try rowTitles(picker) == ["Default model", "Opus", "Sonnet"])
    }

    @Test("A client publishing no catalogue draws no model control")
    func emptyCatalogueDrawsNothing() throws {
        var selection: String?
        let picker = AgentModelPicker(
            models: [],
            selection: Binding(get: { selection }, set: { selection = $0 })
        )
        #expect(throws: (any Error).self) {
            try picker.inspect().find(ViewType.Menu.self)
        }
    }

    // MARK: Rows on their own

    @Test("Rows can be embedded without a menu, and write the selection")
    func embeddedRows() throws {
        var selection: String? = "medium"
        let rows = AgentPickerRows(
            items: .levels(.codexEfforts),
            selection: Binding(get: { selection }, set: { selection = $0 }),
            defaultTitle: "Engine default"
        )
        #expect(try rowTitles(rows) == ["Engine default", "Minimal", "Low", "Medium", "High"])

        // Picking a row writes the wire value back; the default row clears it.
        try rows.inspect().findAll(ViewType.Button.self)[2].tap()
        #expect(selection == "low")
        try rows.inspect().findAll(ViewType.Button.self)[0].tap()
        #expect(selection == nil)
    }

    @Test("A section with no default row offers only its items")
    func noDefaultRow() throws {
        var selection: String? = "low"
        let rows = AgentPickerRows(
            items: .levels(.codexEfforts),
            selection: Binding(get: { selection }, set: { selection = $0 }),
            defaultTitle: nil
        )
        #expect(try rowTitles(rows) == ["Minimal", "Low", "Medium", "High"])
    }

    @Test("Subtitles join the row title when the style asks for them")
    func subtitles() throws {
        var selection: String?
        let rows = AgentPickerRows(
            items: [AgentPickerItem(id: "low", title: "Low", subtitle: "Fast and cheap")],
            selection: Binding(get: { selection }, set: { selection = $0 }),
            defaultTitle: nil,
            showsSubtitles: true
        )
        #expect(try rowTitles(rows) == ["Low — Fast and cheap"])
    }

    // MARK: Builder

    @Test("The builder puts both axes under one control")
    func builderComposesSections() throws {
        var model: String? = "gpt-5"
        var effort: String? = "high"
        let picker = AgentPickerBuilder(style: .chip(icon: "sparkles"))
            .models(
                [AgentModelOption(id: "gpt-5", displayName: "GPT-5")],
                selection: Binding(get: { model }, set: { model = $0 }),
                title: "Model"
            )
            .thinkingLevels(
                .codexEfforts,
                selection: Binding(get: { effort }, set: { effort = $0 }),
                title: "Thinking",
                defaultTitle: "Engine default"
            )
            .picker()

        #expect(try rowTitles(picker) == [
            "Default model", "GPT-5",
            "Engine default", "Minimal", "Low", "Medium", "High",
        ])
    }

    /// The automatic label is what makes one control legible: it has to name
    /// every axis, not just the first.
    @Test("The automatic label joins each section's selection")
    func builderAutomaticLabel() throws {
        var model: String? = "gpt-5"
        var effort: String? = "high"
        let picker = AgentPickerBuilder()
            .models(
                [AgentModelOption(id: "gpt-5", displayName: "GPT-5")],
                selection: Binding(get: { model }, set: { model = $0 })
            )
            .thinkingLevels(
                .codexEfforts,
                selection: Binding(get: { effort }, set: { effort = $0 })
            )
            .picker()

        #expect(try picker.inspect().find(ViewType.Menu.self)
            .labelView().find(ViewType.Text.self).string() == "GPT-5 · High")
    }

    @Test("A host-supplied label replaces the automatic one")
    func builderCustomLabel() throws {
        var effort: String?
        let picker = AgentPickerBuilder()
            .label("Codex · GPT-5.6-Sol")
            .thinkingLevels(
                .codexEfforts,
                selection: Binding(get: { effort }, set: { effort = $0 })
            )
            .picker()

        #expect(try picker.inspect().find(ViewType.Menu.self)
            .labelView().find(ViewType.Text.self).string() == "Codex · GPT-5.6-Sol")
    }

    @Test("A builder with nothing to offer draws nothing")
    func builderEmptyDrawsNothing() throws {
        var effort: String?
        let picker = AgentPickerBuilder()
            .thinkingLevels([], selection: Binding(get: { effort }, set: { effort = $0 }))
            .picker()
        #expect(throws: (any Error).self) {
            try picker.inspect().find(ViewType.Menu.self)
        }
    }
}

@Suite("Discovered reasoning levels")
struct DescribedLevelTests {

    /// A CLI reports levels as bare strings. Known ones should come back with
    /// the curated copy, unknown ones should still show up.
    @Test("Known ids keep their descriptions, unknown ids are titlecased")
    func describing() {
        let levels = [AgentReasoningOption].describing(["low", "xhigh", "ultra"])
        #expect(levels.map(\.id) == ["low", "xhigh", "ultra"])
        #expect(levels.map(\.displayName) == ["Low", "Extra High", "Ultra"])
        #expect(levels[1].levelDescription != nil)
        #expect(levels[2].levelDescription == nil)
    }
}
