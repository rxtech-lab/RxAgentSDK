import Foundation
import FoundationModels
import RxAgentCore

// MARK: - Context

/// Declarative context handed to an agent before a turn: instructions, tools,
/// and skills, all as elements of a single builder.
///
/// That single-builder shape is the ergonomic worth copying from
/// `apple/foundation-models-utilities` — one `if` can add an instruction *and*
/// the tools that instruction talks about, and a skill can be a self-contained
/// bundle of both. FoundationModels expresses it with `DynamicInstructions`,
/// which is a 27.0 API; this reimplements the shape on 26.0 primitives.
///
/// Unlike `FoundationModels.Instructions`, this type keeps its raw text. It has
/// to: the SDK's whole job is serializing context down a pipe to a CLI, and
/// `Instructions` is opaque — there is no accessor to read text back out of it.
/// So this is the source of truth and ``instructions()`` is a one-way export.
public struct AgentContext: Sendable {
    public enum Segment: Sendable {
        case text(String)
        case heading(String)
        /// Read and fenced at render time, so edits between turns are picked up.
        case file(URL, label: String?)
        case tool(AnyAgentTool)
        case skill(Skill)
    }

    public private(set) var segments: [Segment]

    public init() { self.segments = [] }
    public init(segments: [Segment]) { self.segments = segments }
    public init(@AgentContextBuilder _ build: () -> AgentContext) { self = build() }

    public var isEmpty: Bool { segments.isEmpty }

    // MARK: Composition

    public func appending(_ other: AgentContext) -> AgentContext {
        AgentContext(segments: segments + other.segments)
    }

    public mutating func append(_ other: AgentContext) {
        segments.append(contentsOf: other.segments)
    }

    // MARK: Derived collections

    /// Every tool reachable from this context, including those nested in skills,
    /// de-duplicated by name (first declaration wins).
    public var tools: [AnyAgentTool] {
        var seen: Set<String> = []
        var result: [AnyAgentTool] = []
        for tool in collectTools() where seen.insert(tool.name).inserted {
            result.append(tool)
        }
        return result
    }

    private func collectTools() -> [AnyAgentTool] {
        segments.flatMap { segment -> [AnyAgentTool] in
            switch segment {
            case .tool(let tool): [tool]
            case .skill(let skill): skill.body.collectTools()
            default: []
            }
        }
    }

    public var skills: [Skill] {
        segments.compactMap { if case .skill(let skill) = $0 { skill } else { nil } }
    }

    // MARK: Rendering

    /// The load-bearing renderer: this string becomes Claude's
    /// `--append-system-prompt` and Codex/ACP's prompt prefix.
    ///
    /// Skills render name + description + body inline. That's the prompt-based
    /// strategy: it costs context but never touches the user's repository, which
    /// materializing `.claude/skills/<id>/SKILL.md` would.
    public func renderText() -> String {
        var parts: [String] = []
        for segment in segments {
            switch segment {
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { parts.append(trimmed) }

            case .heading(let heading):
                parts.append("## \(heading)")

            case .file(let url, let label):
                parts.append(renderFile(url, label: label))

            case .tool:
                // Tools are advertised over MCP, not described in prose — the
                // agent discovers them via `tools/list` with real schemas.
                continue

            case .skill(let skill):
                parts.append(skill.render())
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private func renderFile(_ url: URL, label: String?) -> String {
        let title = label ?? url.lastPathComponent
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return "### \(title)\n_(could not read \(url.path))_"
        }
        let language = url.pathExtension
        return "### \(title)\n```\(language)\n\(contents)\n```"
    }

    /// One-way bridge for callers who also drive a `LanguageModelSession`.
    ///
    /// Cannot round-trip — `Instructions` has no text accessor — so this is an
    /// export, not a representation.
    public func instructions() -> FoundationModels.Instructions {
        Instructions(renderText())
    }
}

// MARK: - Builder

@resultBuilder
public enum AgentContextBuilder {
    public static func buildExpression(_ text: String) -> AgentContext {
        AgentContext(segments: [.text(text)])
    }

    public static func buildExpression(_ context: AgentContext) -> AgentContext { context }

    public static func buildExpression(_ skill: Skill) -> AgentContext {
        AgentContext(segments: [.skill(skill)])
    }

    public static func buildExpression(_ tool: AnyAgentTool) -> AgentContext {
        AgentContext(segments: [.tool(tool)])
    }

    /// Lets a FoundationModels tool be written bare in the builder, next to the
    /// instructions that describe it.
    public static func buildExpression<T: FoundationModels.Tool>(
        _ tool: T
    ) -> AgentContext where T.Output: ConvertibleToGeneratedContent {
        AgentContext(segments: [.tool(.tool(tool))])
    }

    /// `Instructions` is opaque on macOS 26 — accepting it would silently drop
    /// the text. Reject it at compile time with an explanation instead.
    @available(*, unavailable, message: """
        FoundationModels.Instructions cannot be read back on macOS 26, so its text \
        cannot be sent to a CLI agent. Pass a String, Skill, Tool, or nested \
        AgentContext instead.
        """)
    public static func buildExpression(_ instructions: FoundationModels.Instructions) -> AgentContext {
        AgentContext()
    }

    public static func buildBlock(_ parts: AgentContext...) -> AgentContext {
        AgentContext(segments: parts.flatMap(\.segments))
    }

    public static func buildOptional(_ part: AgentContext?) -> AgentContext {
        part ?? AgentContext()
    }

    public static func buildEither(first part: AgentContext) -> AgentContext { part }
    public static func buildEither(second part: AgentContext) -> AgentContext { part }

    public static func buildArray(_ parts: [AgentContext]) -> AgentContext {
        AgentContext(segments: parts.flatMap(\.segments))
    }

    public static func buildLimitedAvailability(_ part: AgentContext) -> AgentContext { part }
}

// MARK: - Convenience segments

public extension AgentContext {
    /// Include a file's contents in the context, re-read each turn.
    static func file(_ url: URL, label: String? = nil) -> AgentContext {
        AgentContext(segments: [.file(url, label: label)])
    }

    static func heading(_ text: String) -> AgentContext {
        AgentContext(segments: [.heading(text)])
    }
}
