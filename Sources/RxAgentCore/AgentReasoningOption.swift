import Foundation

// MARK: - Reasoning Levels

/// One reasoning-effort setting a client will accept.
///
/// Every current coding agent exposes *some* dial for how hard the model
/// thinks, and no two spell it the same way: Claude Code takes `--effort`,
/// Codex takes a `model_reasoning_effort` config key, an OpenAI-compatible
/// endpoint takes a `reasoning_effort` body field, and an ACP agent takes
/// whatever its author decided. The names of the levels differ too — Codex has
/// a `minimal` that Claude does not, Claude has an `xhigh` and a `max` that
/// Codex does not.
///
/// So the SDK does not model reasoning as a fixed enum. A client *advertises*
/// the levels it accepts through ``AgentClient/availableReasoningLevels()``,
/// and ``id`` is the literal string handed back to that agent in
/// ``AgentSendRequest/effort``. A host adding its own provider supplies its own
/// list; nothing here needs to know the vocabulary in advance.
public struct AgentReasoningOption: Sendable, Hashable, Identifiable, Codable {
    /// The wire value. Passed through to the agent verbatim.
    public let id: String
    public let displayName: String
    /// One line for a picker's subtitle — when to reach for this level.
    public let levelDescription: String?

    public init(id: String, displayName: String, levelDescription: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.levelDescription = levelDescription
    }
}

// MARK: - Provider defaults

public extension [AgentReasoningOption] {

    /// Titlecases each wire value into a display name.
    ///
    /// The shortcut for a custom provider whose level names read well as-is:
    /// `reasoningLevels: .levels("low", "medium", "high")`.
    static func levels(_ ids: String...) -> [AgentReasoningOption] {
        levels(ids)
    }

    static func levels(_ ids: [String]) -> [AgentReasoningOption] {
        ids.map { id in
            AgentReasoningOption(
                id: id,
                displayName: id.replacingOccurrences(of: "_", with: " ").capitalized
            )
        }
    }

    /// Wire values decorated from the built-in vocabularies where they match,
    /// titlecased where they don't.
    ///
    /// For a host that *discovers* its levels — `codex debug models` reports
    /// them per model, a gateway reports them per endpoint — so a rediscovered
    /// list still reads like the curated one, and an unrecognized level still
    /// shows up rather than being dropped.
    static func describing(
        _ ids: [String],
        knownIn vocabularies: [[AgentReasoningOption]] = [
            .claudeCodeEfforts, .codexEfforts, .openAIReasoningEfforts,
        ]
    ) -> [AgentReasoningOption] {
        ids.map { id in
            for vocabulary in vocabularies {
                if let known = vocabulary.first(where: { $0.id == id }) { return known }
            }
            return AgentReasoningOption(
                id: id,
                displayName: id.replacingOccurrences(of: "_", with: " ").capitalized
            )
        }
    }

    /// `claude --effort`. The set Claude Code accepts for models that support
    /// an effort setting; `xhigh` is the CLI's own default.
    static let claudeCodeEfforts: [AgentReasoningOption] = [
        AgentReasoningOption(
            id: "low",
            displayName: "Low",
            levelDescription: "Fastest and cheapest. Mechanical edits and small questions."
        ),
        AgentReasoningOption(
            id: "medium",
            displayName: "Medium",
            levelDescription: "Everyday work where quality is holding up fine."
        ),
        AgentReasoningOption(
            id: "high",
            displayName: "High",
            levelDescription: "Intelligence-sensitive work. A good quality/cost balance."
        ),
        AgentReasoningOption(
            id: "xhigh",
            displayName: "Extra High",
            levelDescription: "Best for most coding and agentic tasks."
        ),
        AgentReasoningOption(
            id: "max",
            displayName: "Max",
            levelDescription: "When correctness matters more than cost."
        ),
    ]

    /// Codex's `model_reasoning_effort` config key.
    static let codexEfforts: [AgentReasoningOption] = [
        AgentReasoningOption(
            id: "minimal",
            displayName: "Minimal",
            levelDescription: "Barely reasons. Lowest latency."
        ),
        AgentReasoningOption(
            id: "low",
            displayName: "Low",
            levelDescription: "Quick passes over small, well-specified changes."
        ),
        AgentReasoningOption(
            id: "medium",
            displayName: "Medium",
            levelDescription: "Codex's default balance of speed and depth."
        ),
        AgentReasoningOption(
            id: "high",
            displayName: "High",
            levelDescription: "Multi-step work worth waiting for."
        ),
    ]

    /// The `reasoning_effort` values an OpenAI-compatible reasoning endpoint
    /// typically accepts. A gateway offering a different vocabulary should be
    /// configured with its own list instead.
    static let openAIReasoningEfforts: [AgentReasoningOption] = [
        AgentReasoningOption(id: "minimal", displayName: "Minimal"),
        AgentReasoningOption(id: "low", displayName: "Low"),
        AgentReasoningOption(id: "medium", displayName: "Medium"),
        AgentReasoningOption(id: "high", displayName: "High"),
    ]
}
