import Foundation
import RxAgentCore

/// A named, self-contained bundle of instructions and the tools those
/// instructions talk about.
///
/// The body is an ``AgentContext``, so a skill can carry tools — the property
/// that makes skills composable rather than just named prompt fragments:
///
/// ```swift
/// extension Skill {
///     static let calendaring = Skill(
///         name: "Calendaring",
///         description: "Read and modify the user's calendar."
///     ) {
///         "Work meetings start five minutes after the hour unless stated otherwise."
///         QueryCalendarEventsTool()
///         AddCalendarEventTool()
///     }
/// }
/// ```
public struct Skill: Sendable, Identifiable {
    public let id: String
    public let name: String
    /// When to use this skill. Shown to the agent so it can decide.
    public let description: String
    public let body: AgentContext

    public init(
        id: String? = nil,
        name: String,
        description: String,
        @AgentContextBuilder body: () -> AgentContext
    ) {
        self.id = id ?? Skill.slug(name)
        self.name = name
        self.description = description
        self.body = body()
    }

    public init(
        id: String? = nil,
        name: String,
        description: String,
        instructions: String
    ) {
        self.id = id ?? Skill.slug(name)
        self.name = name
        self.description = description
        self.body = AgentContext(segments: [.text(instructions)])
    }

    public var tools: [AnyAgentTool] { body.tools }

    func render() -> String {
        var section = "## Skill: \(name)\n\(description)"
        let bodyText = body.renderText()
        if !bodyText.isEmpty {
            section += "\n\n\(bodyText)"
        }
        let toolNames = tools.map(\.name)
        if !toolNames.isEmpty {
            section += "\n\nTools provided by this skill: \(toolNames.joined(separator: ", "))"
        }
        return section
    }

    static func slug(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}

extension Skill: Equatable {
    public static func == (lhs: Skill, rhs: Skill) -> Bool { lhs.id == rhs.id }
}

extension Skill: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Builder

@resultBuilder
public enum SkillsBuilder {
    public static func buildBlock(_ skills: [Skill]...) -> [Skill] { skills.flatMap(\.self) }
    public static func buildExpression(_ skill: Skill) -> [Skill] { [skill] }
    public static func buildExpression(_ skill: Skill?) -> [Skill] { skill.map { [$0] } ?? [] }
    public static func buildExpression(_ skills: [Skill]) -> [Skill] { skills }
    public static func buildOptional(_ skills: [Skill]?) -> [Skill] { skills ?? [] }
    public static func buildEither(first skills: [Skill]) -> [Skill] { skills }
    public static func buildEither(second skills: [Skill]) -> [Skill] { skills }
    public static func buildArray(_ skills: [[Skill]]) -> [Skill] { skills.flatMap(\.self) }
}
