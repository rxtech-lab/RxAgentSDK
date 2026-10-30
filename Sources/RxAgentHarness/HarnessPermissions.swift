import Foundation
import RxAgentCore

// MARK: - Rules

/// What a permission rule does with a matching request. Same vocabulary as
/// opencode's `permission` config.
public enum HarnessPermissionAction: String, Sendable, Codable, CaseIterable, Hashable {
    case allow
    case ask
    case deny
}

/// Permission keys the bundled tools raise. A host tool may raise any string.
public enum HarnessPermissionKey {
    public static let read = "read"
    /// Every file modification: `write`, `edit`, `patch`.
    public static let edit = "edit"
    public static let glob = "glob"
    public static let grep = "grep"
    public static let bash = "bash"
    public static let todowrite = "todowrite"
    public static let webfetch = "webfetch"
    public static let question = "question"
    /// A tool touched a path outside the working directory.
    public static let externalDirectory = "external_directory"
    /// The same call, with identical input, repeated ``HarnessPermissionGate/doomLoopThreshold`` times.
    public static let doomLoop = "doom_loop"
    /// A host-supplied (MCP or Swift) tool.
    public static let mcp = "mcp"
}

/// One `permission → pattern → action` rule.
public struct HarnessPermissionRule: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    /// A ``HarnessPermissionKey`` or `*` for every permission.
    public var permission: String
    /// Wildcard pattern matched against the request's resource: a file path, a
    /// shell command, a URL. `*` matches everything.
    public var pattern: String
    public var action: HarnessPermissionAction

    public init(id: UUID = UUID(), permission: String, pattern: String = "*", action: HarnessPermissionAction) {
        self.id = id
        self.permission = permission
        self.pattern = pattern
        self.action = action
    }
}

/// An ordered rule list. **The last matching rule wins**, so a catch-all goes
/// first and specific exceptions after it — opencode's semantics exactly.
public struct HarnessPermissionRuleset: Sendable, Codable, Hashable {
    public var rules: [HarnessPermissionRule]

    public init(_ rules: [HarnessPermissionRule] = []) {
        self.rules = rules
    }

    /// opencode's defaults: most things allowed, secrets and leaving the
    /// project ask first. Shell commands and edits ask too, because unlike
    /// opencode's TUI the host here may be running unattended — a host that
    /// wants opencode's fully permissive behavior can append `bash → allow`.
    public static let defaults = HarnessPermissionRuleset([
        .init(permission: "*", action: .allow),
        .init(permission: HarnessPermissionKey.bash, action: .ask),
        .init(permission: HarnessPermissionKey.edit, action: .ask),
        .init(permission: HarnessPermissionKey.webfetch, action: .ask),
        .init(permission: HarnessPermissionKey.read, pattern: "*.env", action: .ask),
        .init(permission: HarnessPermissionKey.read, pattern: "*.env.*", action: .ask),
        .init(permission: HarnessPermissionKey.read, pattern: "*.env.example", action: .allow),
        .init(permission: HarnessPermissionKey.externalDirectory, action: .ask),
        .init(permission: HarnessPermissionKey.doomLoop, action: .ask),
    ])

    /// The action for one resource. Unmatched requests ask.
    public func evaluate(permission: String, resource: String) -> HarnessPermissionAction {
        var result: HarnessPermissionAction = .ask
        for rule in rules where Wildcard.matches(rule.permission, permission)
            && Wildcard.matches(Self.expandHome(rule.pattern), resource) {
            result = rule.action
        }
        return result
    }

    /// The strictest action across several resources — a compound shell
    /// command is only as allowed as its least allowed part.
    public func evaluate(permission: String, resources: [String]) -> HarnessPermissionAction {
        let actions = (resources.isEmpty ? ["*"] : resources).map { evaluate(permission: permission, resource: $0) }
        if actions.contains(.deny) { return .deny }
        if actions.contains(.ask) { return .ask }
        return .allow
    }

    public mutating func append(_ rule: HarnessPermissionRule) { rules.append(rule) }

    static func expandHome(_ pattern: String) -> String {
        let home = NSHomeDirectory()
        if pattern == "~" || pattern == "$HOME" { return home }
        if pattern.hasPrefix("~/") { return home + pattern.dropFirst(1) }
        if pattern.hasPrefix("$HOME/") { return home + pattern.dropFirst(5) }
        return pattern
    }
}

/// `*` matches any run of characters (including `/`), `?` exactly one.
public enum Wildcard {
    public static func matches(_ pattern: String, _ value: String) -> Bool {
        if pattern == "*" { return true }
        // `git status *` also covers a bare `git status`.
        if pattern.hasSuffix(" *"), value == String(pattern.dropLast(2)) { return true }
        let p = Array(pattern), v = Array(value)
        var pi = 0, vi = 0, star = -1, mark = 0
        while vi < v.count {
            if pi < p.count, p[pi] == "?" || p[pi] == v[vi] {
                pi += 1; vi += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = vi; pi += 1
            } else if star != -1 {
                pi = star + 1; mark += 1; vi = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

// MARK: - Asking

/// A request for approval, raised by a tool before it acts.
public struct HarnessPermissionAsk: Sendable, Hashable, Identifiable {
    public let id: String
    public let sessionID: String
    public let permission: String
    /// The concrete resources — paths, commands — this call touches.
    public let resources: [String]
    /// What an "always allow" answer adds for the rest of the session, e.g.
    /// `git status *` for `git status --porcelain`.
    public let alwaysPatterns: [String]
    public let toolName: String
    public let toolCallID: String?
    public let input: JSONValue
    /// One line for the approval UI.
    public let title: String

    public init(
        id: String = UUID().uuidString,
        sessionID: String,
        permission: String,
        resources: [String],
        alwaysPatterns: [String]? = nil,
        toolName: String,
        toolCallID: String? = nil,
        input: JSONValue = .object([:]),
        title: String
    ) {
        self.id = id
        self.sessionID = sessionID
        self.permission = permission
        self.resources = resources
        self.alwaysPatterns = alwaysPatterns ?? resources
        self.toolName = toolName
        self.toolCallID = toolCallID
        self.input = input
        self.title = title
    }
}

public enum HarnessPermissionReply: Sendable, Equatable {
    /// Approve this request only.
    case once
    /// Approve, and approve future requests matching ``HarnessPermissionAsk/alwaysPatterns`` this session.
    case always
    /// Deny. A message is handed to the model so it can change course.
    case reject(message: String?)
}

/// Answers ``HarnessPermissionAsk``s — usually by asking a human.
public protocol HarnessPermissionHandler: Sendable {
    func decide(_ ask: HarnessPermissionAsk) async -> HarnessPermissionReply
}

public struct AllowAllHarnessPermissions: HarnessPermissionHandler {
    public init() {}
    public func decide(_ ask: HarnessPermissionAsk) async -> HarnessPermissionReply { .once }
}

public struct RejectAllHarnessPermissions: HarnessPermissionHandler {
    public init() {}
    public func decide(_ ask: HarnessPermissionAsk) async -> HarnessPermissionReply { .reject(message: nil) }
}

/// A handler that is a closure. Convenient for tests and simple hosts.
public struct ClosureHarnessPermissionHandler: HarnessPermissionHandler {
    let body: @Sendable (HarnessPermissionAsk) async -> HarnessPermissionReply
    public init(_ body: @escaping @Sendable (HarnessPermissionAsk) async -> HarnessPermissionReply) {
        self.body = body
    }
    public func decide(_ ask: HarnessPermissionAsk) async -> HarnessPermissionReply { await body(ask) }
}

/// Adapts the SDK-wide ``PermissionResolving`` so a host's existing approval UI
/// answers harness requests too.
///
/// The request is phrased the way that UI already understands: tool names
/// Claude Code uses (`Bash`, `Edit`, `Read`, …) and their input shapes, so the
/// risk-aware approval sheet renders a command or a diff without knowing which
/// agent asked.
public struct ResolverHarnessPermissionHandler: HarnessPermissionHandler {
    let resolver: any PermissionResolving
    let mode: PermissionMode
    let threadID: AgentThreadID?
    let clientID: AgentClientID?

    public init(
        resolver: any PermissionResolving,
        mode: PermissionMode,
        threadID: AgentThreadID? = nil,
        clientID: AgentClientID? = nil
    ) {
        self.resolver = resolver
        self.mode = mode
        self.threadID = threadID
        self.clientID = clientID
    }

    public func decide(_ ask: HarnessPermissionAsk) async -> HarnessPermissionReply {
        let (toolName, input) = Self.presentation(for: ask)
        let decision = await resolver.resolve(PermissionRequest(
            id: ask.toolCallID ?? ask.id,
            toolName: toolName,
            toolInput: input,
            mode: mode,
            threadID: threadID,
            clientID: clientID
        ))
        switch decision {
        case .allow, .allowWithInput, .allowAndSetMode: return .once
        case .allowSessionTool, .allowAlwaysCommand: return .always
        case .deny: return .reject(message: nil)
        case .denyWithReason(let reason): return .reject(message: reason)
        }
    }

    static func presentation(for ask: HarnessPermissionAsk) -> (String, [String: JSONValue]) {
        var input = ask.input.objectValue ?? [:]
        switch ask.permission {
        case HarnessPermissionKey.bash:
            return ("Bash", input)
        case HarnessPermissionKey.edit:
            if input["file_path"] == nil, let path = input["filePath"] ?? input["path"] {
                input["file_path"] = path
            }
            if let old = input["oldString"] { input["old_string"] = old }
            if let new = input["newString"] { input["new_string"] = new }
            return (ask.toolName == "write" ? "Write" : "Edit", input)
        case HarnessPermissionKey.read:
            if input["file_path"] == nil, let path = input["path"] { input["file_path"] = path }
            return ("Read", input)
        case HarnessPermissionKey.webfetch:
            return ("WebFetch", input)
        case HarnessPermissionKey.externalDirectory, HarnessPermissionKey.doomLoop:
            input["reason"] = .string(ask.title)
            input["paths"] = .array(ask.resources.map(JSONValue.string))
            return (ask.toolName, input)
        default:
            return (ask.toolName, input)
        }
    }
}

// MARK: - Gate

public struct HarnessPermissionDenied: Error, Sendable, CustomStringConvertible {
    public let permission: String
    public let message: String?
    /// True when a rule denied it outright rather than a person rejecting it.
    public let byRule: Bool

    public var description: String {
        if let message, !message.isEmpty {
            return "The user rejected this action and said: \(message)"
        }
        return byRule
            ? "This action is blocked by the permission rules (\(permission)). Do not retry it; choose another approach."
            : "The user rejected this action. Do not retry it; ask the user how to proceed if you are unsure."
    }
}

/// Decides every permission request of one session: rules first, then the
/// host's handler for anything that asks.
///
/// "Always" answers are remembered here for the life of the gate, which the
/// harness keeps per session — so they persist across turns but not across a
/// relaunch, matching opencode.
public actor HarnessPermissionGate {
    public private(set) var ruleset: HarnessPermissionRuleset
    public private(set) var mode: PermissionMode
    private var approved: [String: [String]] = [:]
    private var recentCalls: [String] = []
    private var handler: any HarnessPermissionHandler

    public static let doomLoopThreshold = 3

    public init(
        ruleset: HarnessPermissionRuleset = .defaults,
        mode: PermissionMode = .default,
        handler: any HarnessPermissionHandler
    ) {
        self.ruleset = ruleset
        self.mode = mode
        self.handler = handler
    }

    public func setMode(_ mode: PermissionMode) { self.mode = mode }
    public func setRuleset(_ ruleset: HarnessPermissionRuleset) { self.ruleset = ruleset }
    public func setHandler(_ handler: any HarnessPermissionHandler) { self.handler = handler }

    /// Throws ``HarnessPermissionDenied`` unless the request may proceed.
    /// `onAsk` fires only when a human will actually be asked.
    public func authorize(
        _ ask: HarnessPermissionAsk,
        onAsk: @Sendable (HarnessPermissionAsk) async -> Void = { _ in },
        onReply: @Sendable (HarnessPermissionAsk, HarnessPermissionReply) async -> Void = { _, _ in }
    ) async throws {
        var action = ruleset.evaluate(permission: ask.permission, resources: ask.resources)
        if action == .deny {
            throw HarnessPermissionDenied(permission: ask.permission, message: nil, byRule: true)
        }
        action = applyMode(action, permission: ask.permission, resources: ask.resources)
        if action == .deny {
            throw HarnessPermissionDenied(
                permission: ask.permission,
                message: "Plan mode is active: only read-only tools may run. Describe the plan instead of acting.",
                byRule: true
            )
        }
        if action == .allow { return }
        if isApproved(ask) { return }

        await onAsk(ask)
        let reply = await handler.decide(ask)
        await onReply(ask, reply)
        switch reply {
        case .once:
            return
        case .always:
            approved[ask.permission, default: []].append(contentsOf: ask.alwaysPatterns)
        case .reject(let message):
            throw HarnessPermissionDenied(permission: ask.permission, message: message, byRule: false)
        }
    }

    /// Records a tool call and reports whether it is the Nth identical one in a row.
    public func recordCall(name: String, argumentsJSON: String) -> Bool {
        let signature = name + "\u{0}" + (JSONValue(jsonString: argumentsJSON)?.jsonString ?? argumentsJSON)
        recentCalls.append(signature)
        if recentCalls.count > Self.doomLoopThreshold { recentCalls.removeFirst(recentCalls.count - Self.doomLoopThreshold) }
        return recentCalls.count == Self.doomLoopThreshold && Set(recentCalls).count == 1
    }

    private func isApproved(_ ask: HarnessPermissionAsk) -> Bool {
        guard let patterns = approved[ask.permission], !ask.resources.isEmpty else { return false }
        return ask.resources.allSatisfy { resource in patterns.contains { Wildcard.matches($0, resource) } }
    }

    /// `PermissionMode` layered on top of the rules. Explicit denies already
    /// returned, so a mode can only loosen `ask` or tighten to read-only.
    private func applyMode(
        _ action: HarnessPermissionAction, permission: String, resources: [String]
    ) -> HarnessPermissionAction {
        // A provably read-only shell command (`ls`, `git status`, `rg …`) is
        // treated like the read tools it stands in for.
        let isReadOnlyShell = permission == HarnessPermissionKey.bash && !resources.isEmpty
            && resources.allSatisfy { BashSafety.isSafeReadOnly(command: $0) }
        switch mode {
        case .bypassPermissions, .auto:
            return .allow
        case .acceptEdits:
            if permission == HarnessPermissionKey.edit || isReadOnlyShell { return .allow }
            return action
        case .plan:
            if isReadOnlyShell { return .allow }
            let mutating = [HarnessPermissionKey.edit, HarnessPermissionKey.bash]
            return mutating.contains(permission) ? .deny : action
        case .default:
            return isReadOnlyShell ? .allow : action
        }
    }
}
