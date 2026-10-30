import Foundation
import RxAgentCore

/// Rough token counting. Four UTF-8 bytes per token is the usual estimate for
/// English and code; it only has to be good enough to decide *when* to compact,
/// and the server's measured prompt size replaces it whenever one is known.
public enum TokenEstimator {
    public static func estimate(_ text: String) -> Int {
        text.isEmpty ? 0 : max(1, text.utf8.count / 4)
    }

    public static let imageTokens = 1_500

    public static func estimate(_ message: HarnessMessage) -> Int {
        var total = 4 + estimate(HarnessCompactor.replayText(message))
        for call in message.toolCalls { total += estimate(call.name) + estimate(call.argumentsJSON) + 4 }
        total += message.images.count * imageTokens
        return total
    }

    public static func estimate(system: String, messages: some Sequence<HarnessMessage>, tools: [HarnessToolSpec]) -> Int {
        estimate(system)
            + messages.reduce(0) { $0 + estimate($1) }
            + tools.reduce(0) { $0 + estimate($1.name) + estimate($1.description) + estimate($1.parameters.jsonString) }
    }
}

/// When and how much to compact.
///
/// The constants are opencode's, with one change: opencode assumes windows of
/// 100k+ tokens, while a local model commonly runs with 8–32k. Every absolute
/// floor is therefore also capped at a share of the window, or a small model
/// would be "over the threshold" before the first message.
public struct HarnessCompactionPolicy: Sendable, Hashable {
    /// Compact automatically when the context nears the window.
    public var automatic: Bool
    /// Share of the window kept free for the reply and for the summary itself.
    public var reserveShare: Double
    public var reserveMinimum: Int
    /// Most recent tool output (in tokens) never pruned.
    public var pruneProtectTokens: Int
    /// Pruning only happens when it would free at least this much.
    public var pruneMinimumTokens: Int
    /// Characters kept from each end of a long tool result in a summary transcript.
    public var transcriptClip: Int

    public init(
        automatic: Bool = true,
        reserveShare: Double = 0.15,
        reserveMinimum: Int = 16_000,
        pruneProtectTokens: Int = 40_000,
        pruneMinimumTokens: Int = 20_000,
        transcriptClip: Int = 2_000
    ) {
        self.automatic = automatic
        self.reserveShare = reserveShare
        self.reserveMinimum = reserveMinimum
        self.pruneProtectTokens = pruneProtectTokens
        self.pruneMinimumTokens = pruneMinimumTokens
        self.transcriptClip = transcriptClip
    }

    public static let `default` = HarnessCompactionPolicy()

    /// Prompt size at which automatic compaction runs.
    public func threshold(contextWindow window: Int) -> Int {
        let reserve = max(Int(Double(window) * reserveShare), min(reserveMinimum, window / 4))
        return max(window / 2, window - reserve)
    }

    func protectTokens(window: Int?) -> Int {
        guard let window else { return pruneProtectTokens }
        return min(pruneProtectTokens, window / 4)
    }

    func minimumPrune(window: Int?) -> Int {
        guard let window else { return pruneMinimumTokens }
        return min(pruneMinimumTokens, window / 10)
    }
}

/// The two stages of opencode's compaction: prune old tool output (free,
/// lossless for the transcript), then summarize older turns with the model.
public struct HarnessCompactor: Sendable {
    public static let prunedPlaceholder = "[Old tool result content cleared]"

    public var policy: HarnessCompactionPolicy

    public init(policy: HarnessCompactionPolicy = .default) {
        self.policy = policy
    }

    /// What the model sees for `message`: pruned tool results become a
    /// placeholder. The stored text is kept for display.
    public static func replayText(_ message: HarnessMessage) -> String {
        message.isPruned ? prunedPlaceholder : message.text
    }

    // MARK: Prune

    /// Marks old tool results pruned, newest-protected-first. Never touches
    /// the current turn (everything after the latest user message). Returns
    /// how many results were pruned.
    @discardableResult
    public func prune(_ session: inout HarnessSession, contextWindow: Int?) -> Int {
        let start = session.compactedThrough
        guard start < session.messages.count else { return 0 }
        let lastUser = session.messages.lastIndex { $0.role == .user && !$0.text.hasPrefix("<system-reminder>") } ?? session.messages.count
        let protect = policy.protectTokens(window: contextWindow)

        var seen = 0
        var candidates: [Int] = []
        var freed = 0
        for index in stride(from: min(lastUser, session.messages.count) - 1, through: start, by: -1) {
            let message = session.messages[index]
            guard message.role == .tool, !message.isPruned else { continue }
            let tokens = TokenEstimator.estimate(message.text)
            seen += tokens
            if seen > protect {
                candidates.append(index)
                freed += tokens
            }
        }
        guard freed >= policy.minimumPrune(window: contextWindow), !candidates.isEmpty else { return 0 }
        for index in candidates { session.messages[index].isPruned = true }
        return candidates.count
    }

    // MARK: Summarize

    /// Index where the verbatim tail begins: the most recent user message, so a
    /// tool call is never separated from its result and the current request
    /// stays word for word.
    public static func keepBoundary(_ session: HarnessSession) -> Int? {
        let live = session.compactedThrough
        guard let index = session.messages.lastIndex(where: { $0.role == .user }), index > live else { return nil }
        return index
    }

    /// Summarizes everything before ``keepBoundary(_:)`` into the session's
    /// checkpoint. Returns false when there is nothing old enough to fold.
    public func summarize(
        _ session: inout HarnessSession,
        model: any HarnessModel,
        modelName: String,
        onUsage: (UsageInfo) -> Void = { _ in }
    ) async throws -> Bool {
        guard let boundary = Self.keepBoundary(session) else { return false }
        let folded = session.messages[session.compactedThrough ..< boundary]
        guard !folded.isEmpty else { return false }

        let transcript = transcript(of: folded)
        var prompt = ""
        if let previous = session.summary, !previous.isEmpty {
            prompt += "<conversation-checkpoint>\n\(previous)\n</conversation-checkpoint>\n\n"
        }
        prompt += "<conversation>\n\(transcript)\n</conversation>\n\n"
        prompt += Self.instructions(update: session.summary?.isEmpty == false)

        let request = HarnessModelRequest(
            model: modelName,
            system: "You are a helpful AI assistant tasked with summarizing conversations so another agent can resume the work.",
            messages: [.user(prompt)],
            tools: [],
            mode: .generation,
            temperature: 0.2
        )
        var text = ""
        for try await chunk in model.send(request) {
            switch chunk {
            case .textDelta(let delta): text += delta
            case .usage(let usage): onUsage(usage)
            default: break
            }
        }
        let summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            throw HarnessModelError.malformed("The model returned an empty summary.")
        }
        session.summary = summary
        session.compactedThrough = boundary
        session.lastPromptTokens = nil
        return true
    }

    func transcript(of messages: some Sequence<HarnessMessage>) -> String {
        let clip = policy.transcriptClip
        func clipped(_ text: String) -> String {
            guard text.count > clip * 2 else { return text }
            return text.prefix(clip) + "\n…\n" + text.suffix(clip)
        }
        return messages.map { message -> String in
            switch message.role {
            case .system: return "System: \(clipped(message.text))"
            case .user: return "User: \(clipped(message.text))"
            case .assistant:
                var line = "Assistant: \(clipped(message.text))"
                for call in message.toolCalls { line += "\n[called \(call.name) \(clipped(call.argumentsJSON))]" }
                return line
            case .tool:
                return "Tool result (\(message.toolName ?? "tool")): \(clipped(Self.replayText(message)))"
            }
        }
        .joined(separator: "\n\n")
    }

    /// opencode's summary instructions, verbatim apart from the framing.
    static func instructions(update: Bool) -> String {
        let template = """
        You MUST use this format for your response (you may omit sections that aren't applicable). Do not include the <template> tags in your response.
        <template>
        ## Objective
        - [one or two brief sentences describing what the user is trying to accomplish]

        ## Requirements
        - [constraints, preferences, requirements, and scope boundaries stated by the user, or "(none)"]

        ## Decisions
        - [decisions already made and why, or "(none)"]

        ## Work State
        Break the objective into smaller goals and report which are completed, which are being worked on, and which are blocked.
        ### Completed
        - [goals that have been completed; otherwise "(none)"]

        ### Active
        - [goals currently being worked on; otherwise "(none)"]

        ### Blocked
        - [anything blocking progress, and why; otherwise "(none)"]

        ## Next Move
        1. [ordered list of next actions, or "(none)"]

        ## Relevant Files
        List the files and directories, other than the current working directory, that another agent would need to open to continue this work. Include at most 15, most important first. Do not list every file that was read or changed. If none, write "(none)".
        - `[file or directory path]`: [brief reason it matters]

        ## Important Context
        - [facts the next agent cannot continue without and cannot easily find on its own; or "(none)"]
        </template>
        """
        let rules = """
        Rules:
        - Keep each section concise. Use terse, single-line bullets, not prose paragraphs or nested lists.
        - Prefer short references over detailed restatement. It is fine to leave out information the next agent can recover from the code or the files listed above.
        - Preserve exact file paths, symbols, commands, error strings, URLs, and identifiers.
        - Carry forward only user questions or requests that remain unanswered or require further action. Do not repeat ones that newer history has answered or resolved. Preserve exact wording when carrying one forward.
        - Preserve consequential workflow state, including whether changes are uncommitted, committed, pushed, under review, or merged.
        - Do not mention the summary process or that context was compacted.
        """
        let shared = [
            "Summarize only what the user and the assistant said and did. Leave out instructions and setup the assistant was given rather than told by the user: repository conventions, instruction files such as AGENTS.md, and environment details. The next agent receives current versions of all of these separately.",
            template,
            rules,
            "Do not continue the task or call tools.",
            "Return only the structured summary in the requested format. Do not include a preamble, explanation, or other commentary.",
        ]
        if !update {
            return (["You MUST summarize the conversation above into a structured summary that will be given to another agent to resume the work."] + shared)
                .joined(separator: "\n\n")
        }
        return ([
            "Update the existing checkpoint in the conversation above into one consolidated summary.",
            "Newer history always takes precedence over the existing checkpoint. Preserve previous information unless newer history clearly contradicts, supersedes, resolves, or makes it stale. If something is no longer relevant to continuing the work, you may remove it.",
            "Incorporate newer requirements, decisions, progress, and context. Reconcile Work State and Next Move: move completed work out of Active, remove resolved blockers and answered questions, and preserve unresolved or pending work.",
            "Return only the updated Markdown sections. Do not reproduce the `<conversation-checkpoint>` wrapper tags.",
        ] + shared).joined(separator: "\n\n")
    }
}
