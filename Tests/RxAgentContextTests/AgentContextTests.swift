import Foundation
import Testing
import RxAgentCore
@testable import RxAgentContext

@Suite("AgentContext")
struct AgentContextTests {

    @Test("Strings become prose sections joined by blank lines")
    func rendersText() {
        let context = AgentContext {
            "Prefer server actions."
            "Never use cd in the Bash tool."
        }
        #expect(context.renderText() == "Prefer server actions.\n\nNever use cd in the Bash tool.")
    }

    /// The single-builder shape: an instruction and the tool it describes are
    /// added together by one condition.
    @Test("Instructions and tools are elements of the same builder")
    func toolsAndInstructionsCompose() {
        let editing = true
        let context = AgentContext {
            "You are editing a Swift package."
            if editing {
                "Match the surrounding code style."
                GrepTool()
            }
        }

        #expect(context.tools.map(\.name) == ["grep_workspace"])
        let text = context.renderText()
        #expect(text.contains("editing a Swift package"))
        #expect(text.contains("Match the surrounding code style"))
        // Tools are advertised over MCP with real schemas, not described in prose.
        #expect(!text.contains("grep_workspace"))
    }

    @Test("A false condition contributes nothing")
    func conditionalExclusion() {
        let editing = false
        let context = AgentContext {
            "Base instructions."
            if editing { GrepTool() }
        }
        #expect(context.tools.isEmpty)
        #expect(context.renderText() == "Base instructions.")
    }

    @Test("Headings render as markdown")
    func headings() {
        let context = AgentContext {
            AgentContext.heading("Conventions")
            "Two-space indents."
        }
        #expect(context.renderText() == "## Conventions\n\nTwo-space indents.")
    }

    @Test("File segments are read at render time and fenced")
    func fileSegment() throws {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "rxagent-context-\(UUID().uuidString).swift")
        try "let answer = 42".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let context = AgentContext { AgentContext.file(url, label: "Answer.swift") }
        let text = context.renderText()
        #expect(text.contains("### Answer.swift"))
        #expect(text.contains("```swift"))
        #expect(text.contains("let answer = 42"))
    }

    @Test("A missing file degrades to a note instead of throwing")
    func missingFile() {
        let url = URL(filePath: "/definitely/not/here.swift")
        let text = AgentContext { AgentContext.file(url) }.renderText()
        #expect(text.contains("could not read"))
    }

    @Test("Nested contexts flatten")
    func nesting() {
        let shared = AgentContext { "Shared rule." }
        let context = AgentContext {
            "Top rule."
            shared
            GrepTool()
        }
        #expect(context.renderText() == "Top rule.\n\nShared rule.")
        #expect(context.tools.count == 1)
    }

    @Test("Duplicate tool names are de-duplicated, first wins")
    func deduplicatesTools() {
        let context = AgentContext {
            GrepTool()
            GrepTool()
        }
        #expect(context.tools.count == 1)
    }

    @Test("Loops build context")
    func arrayBuilding() {
        let rules = ["One.", "Two.", "Three."]
        let context = AgentContext {
            for rule in rules { rule }
        }
        #expect(context.renderText() == "One.\n\nTwo.\n\nThree.")
    }

    @Test("Exports to FoundationModels Instructions")
    func exportsInstructions() {
        // Instructions is opaque, so there is nothing to assert about its
        // contents — only that the one-way bridge is callable.
        let context = AgentContext { "Be concise." }
        _ = context.instructions()
    }
}

@Suite("Skill")
struct SkillTests {

    @Test("A skill carries both instructions and tools")
    func skillBundlesToolsAndInstructions() {
        let skill = Skill(name: "Code Review", description: "Use when reviewing a diff.") {
            "Cite file:line. Focus on correctness."
            GrepTool()
        }

        #expect(skill.id == "code-review")
        #expect(skill.tools.map(\.name) == ["grep_workspace"])

        let rendered = skill.render()
        #expect(rendered.hasPrefix("## Skill: Code Review"))
        #expect(rendered.contains("Use when reviewing a diff."))
        #expect(rendered.contains("Cite file:line."))
        #expect(rendered.contains("Tools provided by this skill: grep_workspace"))
    }

    @Test("Skills nested in a context contribute their tools")
    func skillToolsReachThroughContext() {
        let skill = Skill(name: "Search", description: "Find things.") { GrepTool() }
        let context = AgentContext {
            "Base."
            skill
        }

        #expect(context.tools.map(\.name) == ["grep_workspace"])
        #expect(context.skills.count == 1)
        #expect(context.renderText().contains("## Skill: Search"))
    }

    @Test("Skills compose")
    func nestedSkills() {
        let conventions = Skill(name: "Conventions", description: "House style.") {
            "Two-space indents."
        }
        let review = Skill(name: "Review", description: "Review a diff.") {
            "Be specific."
            conventions
        }
        #expect(review.render().contains("Two-space indents."))
    }

    @Test("A plain-instructions skill needs no builder")
    func instructionsInitializer() {
        let skill = Skill(
            name: "Terse",
            description: "Keep answers short.",
            instructions: "Answer in one sentence."
        )
        #expect(skill.render().contains("Answer in one sentence."))
        #expect(skill.tools.isEmpty)
    }
}

// MARK: - Session state

private struct ActiveSkillsKey: AgentStateKey {
    static let defaultValue: [String] = []
}

@Suite("AgentStateValues")
struct AgentStateValuesTests {

    @Test("Reads the default before anything is written")
    func defaultValue() {
        let state = AgentStateValues()
        #expect(state[ActiveSkillsKey.self].isEmpty)
    }

    @Test("Round-trips a written value")
    func roundTrip() {
        var state = AgentStateValues()
        state[ActiveSkillsKey.self] = ["calendaring"]
        #expect(state[ActiveSkillsKey.self] == ["calendaring"])
    }
}
