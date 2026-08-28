#if os(macOS)
import Foundation
import RxAgentCore

/// Serves Claude Code's `PreToolUse` HTTP hook, so tool calls can be approved
/// or rejected before they run.
///
/// The design inverts RxCode's: there, the server parked a `CheckedContinuation`
/// and waited for SwiftUI to call back into it, which welded the transport to
/// the UI. Here the server simply awaits ``PermissionResolving/resolve(_:)`` and
/// whoever supplies the resolver owns the waiting. That's the whole reason this
/// is extractable.
public actor ApprovalServer {
    public static let shared = ApprovalServer()

    /// Tool names the hook intercepts. Everything else runs unimpeded.
    public static let defaultMatcher =
        "^(Bash|Edit|Write|MultiEdit|AskUserQuestion|ExitPlanMode|exit_plan_mode|mcp__.*)$"

    private let server = LoopbackHTTPServer()
    /// Unguessable path segment so another local process can't drive approvals.
    /// RxCode read this from the keychain; a per-process UUID has the same
    /// property with no storage and no dependency.
    private let secret = UUID().uuidString
    private var resolvers: [String: any PermissionResolving] = [:]
    private var modes: [String: PermissionMode] = [:]
    private var isRunning = false

    public init() {}

    /// The bound port, once started.
    public var port: UInt16? {
        get async { await server.port }
    }

    // MARK: - Lifecycle

    @discardableResult
    public func start() async throws -> UInt16 {
        if let port = await server.port { return port }
        try await server.start(portRange: 19836...19846) { [weak self] request in
            guard let self else { return .notFound }
            return await self.handle(request)
        }
        isRunning = true
        guard let port = await server.port else {
            throw AgentError.protocolViolation("approval server failed to bind")
        }
        return port
    }

    public func stop() async {
        await server.stop()
        isRunning = false
    }

    /// Register the resolver for a turn and get back the hook settings JSON the
    /// CLI should be launched with.
    ///
    /// `runToken` scopes the hook URL to one CLI launch, so a new spawn can't
    /// invalidate a still-running agent's hook.
    public func register(
        runToken: String,
        resolver: any PermissionResolving,
        mode: PermissionMode
    ) async throws -> String {
        let port = try await start()
        resolvers[runToken] = resolver
        modes[runToken] = mode
        return hookSettingsJSON(port: port, runToken: runToken)
    }

    public func unregister(runToken: String) {
        resolvers.removeValue(forKey: runToken)
        modes.removeValue(forKey: runToken)
    }

    func hookSettingsJSON(port: UInt16, runToken: String) -> String {
        let url = "http://127.0.0.1:\(port)/hook/pre-tool-use/\(secret)/\(runToken)"
        let settings: [String: Any] = [
            "hooks": [
                "PreToolUse": [[
                    "matcher": Self.defaultMatcher,
                    "hooks": [["type": "http", "url": url, "timeout": 300]],
                ]],
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted]))
            ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Hook handling

    private func handle(_ request: LoopbackHTTPServer.Request) async -> LoopbackHTTPServer.Response {
        // /hook/pre-tool-use/<secret>/<runToken>
        let components = request.path.split(separator: "/").map(String.init)
        guard components.count == 4,
              components[0] == "hook",
              components[1] == "pre-tool-use",
              components[2] == secret
        else { return .notFound }

        let runToken = components[3]
        guard let resolver = resolvers[runToken] else {
            // A hook for a turn we no longer track: let it through rather than
            // deadlocking an agent that outlived our bookkeeping.
            return .json(["hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
            ]])
        }

        guard let payload = JSONValue(jsonString: request.bodyString) else {
            return .json(["hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
            ]])
        }

        let toolName = payload["tool_name"]?.stringValue ?? "unknown"
        let toolInput = payload["tool_input"]?.objectValue ?? [:]

        let permissionRequest = PermissionRequest(
            id: payload["tool_use_id"]?.stringValue ?? UUID().uuidString,
            toolName: toolName,
            toolInput: toolInput,
            mode: modes[runToken] ?? .default,
            clientID: .claudeCode
        )

        // This await is the point of the whole server: the socket stays open
        // until a decision arrives (the CLI allows 300s).
        let decision = await resolver.resolve(permissionRequest)
        return .json(string: Self.hookResponse(for: decision))
    }

    /// Claude's hook response shape.
    ///
    /// `updatedInput` is how an `AskUserQuestion` answer gets injected back into
    /// the tool call before it runs.
    static func hookResponse(for decision: PermissionDecision) -> String {
        var output: [String: Any] = ["hookEventName": "PreToolUse"]

        switch decision {
        case .allow, .allowSessionTool, .allowAlwaysCommand, .allowAndSetMode:
            output["permissionDecision"] = "allow"
        case .allowWithInput(let updated):
            output["permissionDecision"] = "allow"
            output["updatedInput"] = updated.anyValue
        case .deny:
            output["permissionDecision"] = "deny"
            output["permissionDecisionReason"] = "The user declined this tool call."
        case .denyWithReason(let reason):
            output["permissionDecision"] = "deny"
            output["permissionDecisionReason"] = reason
        }

        let body: [String: Any] = ["hookSpecificOutput": output]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
