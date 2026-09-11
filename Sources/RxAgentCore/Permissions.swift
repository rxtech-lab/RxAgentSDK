import Foundation

// MARK: - Permission Mode

/// Mirrors the Claude Code CLI's `--permission-mode` values. Codex and ACP map
/// onto these in their own vocabularies (approval policy / sandbox mode).
///
/// See https://code.claude.com/docs/en/permission-modes for semantics.
public enum PermissionMode: String, CaseIterable, Sendable, Codable {
    case `default`
    case acceptEdits
    case plan
    case auto
    case bypassPermissions

    public var displayName: String {
        switch self {
        case .default: "Ask"
        case .acceptEdits: "Accept Edits"
        case .plan: "Plan"
        case .auto: "Auto"
        case .bypassPermissions: "Bypass"
        }
    }

    public var systemImage: String {
        switch self {
        case .default: "bolt.shield"
        case .acceptEdits: "checkmark.shield"
        case .plan: "eye"
        case .auto: "wand.and.sparkles"
        case .bypassPermissions: "bolt.shield.fill"
        }
    }

    /// When true, skip writing the PreToolUse hook settings and skip the
    /// `--allowedTools` pre-approval list — bypass disables the whole pipeline.
    public var skipsHookPipeline: Bool { self == .bypassPermissions }
}

// MARK: - Tool Category

public enum ToolCategory: Sendable, Equatable {
    case readOnly
    case fileModification
    case execution
    case mcp
    case unknown

    public init(toolName: String) {
        switch toolName.lowercased() {
        case "read", "glob", "grep", "list", "ls", "search":
            self = .readOnly
        case "edit", "write", "multiedit", "multi_edit":
            self = .fileModification
        case "bash", "execute":
            self = .execution
        default:
            let normalized = toolName.lowercased()
            self = normalized.hasPrefix("mcp__") ? .mcp : .unknown
        }
    }

    /// Read-only and execution calls collapse into a grouped summary row in the
    /// transcript instead of each getting a full card.
    public var isTransient: Bool { self == .readOnly || self == .execution }

    public var systemImage: String {
        switch self {
        case .readOnly: "doc.text"
        case .fileModification: "pencil"
        case .execution: "terminal"
        case .mcp: "puzzlepiece.extension"
        case .unknown: "wrench.and.screwdriver"
        }
    }
}

// MARK: - Permission Request

public struct PermissionRequest: Identifiable, Sendable, Equatable {
    public let id: String
    public let toolName: String
    public let toolInput: [String: JSONValue]
    /// The mode in effect when the request was raised. Snapshotted so a later
    /// picker change doesn't retroactively alter a pending prompt.
    public let mode: PermissionMode
    public let threadID: AgentThreadID?
    public let clientID: AgentClientID?

    public init(
        id: String,
        toolName: String,
        toolInput: [String: JSONValue],
        mode: PermissionMode,
        threadID: AgentThreadID? = nil,
        clientID: AgentClientID? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.toolInput = toolInput
        self.mode = mode
        self.threadID = threadID
        self.clientID = clientID
    }

    public var category: ToolCategory { ToolCategory(toolName: toolName) }

    /// The Bash command string, when this is a Bash call.
    public var command: String? { toolInput["command"]?.stringValue }
}

// MARK: - Permission Decision

public enum PermissionDecision: Sendable, Equatable {
    case allow
    case deny
    /// In-memory per-tool allow for the rest of this thread.
    case allowSessionTool
    /// Persistent allow for an exact Bash command string.
    case allowAlwaysCommand(command: String)
    /// Allow, and switch the thread's permission mode for all later calls.
    /// Used by the plan-card accept buttons.
    case allowAndSetMode(newMode: PermissionMode)
    /// Deny and feed `reason` back to the model so it can revise.
    case denyWithReason(reason: String)
    /// Allow, but hand the tool a modified input. This is how `AskUserQuestion`
    /// answers are injected back into the call.
    case allowWithInput(JSONValue)

    public var isAllowed: Bool {
        switch self {
        case .allow, .allowSessionTool, .allowAlwaysCommand, .allowAndSetMode, .allowWithInput:
            true
        case .deny, .denyWithReason:
            false
        }
    }

    public var reason: String? {
        if case .denyWithReason(let reason) = self { return reason }
        return nil
    }
}

// MARK: - Resolver

/// How an approval request gets answered.
///
/// This is the inversion of RxCode's design: there, `PermissionServer` parked a
/// `CheckedContinuation` and waited for SwiftUI to call back into it. Here the
/// server simply awaits `resolve(_:)`, and whoever supplies the resolver owns
/// the continuation. That keeps the transport layer free of UI coupling.
public protocol PermissionResolving: Sendable {
    func resolve(_ request: PermissionRequest) async -> PermissionDecision
}

/// Approves everything. Convenient for tests and headless runs; never a good
/// default for an interactive app.
public struct AllowAllPermissions: PermissionResolving {
    public init() {}
    public func resolve(_ request: PermissionRequest) async -> PermissionDecision { .allow }
}

/// Denies everything.
public struct DenyAllPermissions: PermissionResolving {
    public init() {}
    public func resolve(_ request: PermissionRequest) async -> PermissionDecision { .deny }
}

/// Auto-approves read-only tool calls (including provably read-only Bash) and
/// delegates everything else.
public struct ReadOnlyAutoApprovePermissions: PermissionResolving {
    private let fallback: any PermissionResolving

    public init(fallback: any PermissionResolving) {
        self.fallback = fallback
    }

    public func resolve(_ request: PermissionRequest) async -> PermissionDecision {
        if request.category == .readOnly { return .allow }
        if let command = request.command, BashSafety.isSafeReadOnly(command: command) {
            return .allow
        }
        return await fallback.resolve(request)
    }
}
