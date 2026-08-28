#if os(macOS)
import Foundation
import RxAgentProcess
import RxAgentCore

/// Translates Codex app-server notifications into ``AgentEvent``.
///
/// RxCode's equivalent re-encoded every Codex notification into a *fake Claude
/// wire frame* so it could reuse Claude's parser — `claudeTextDelta`,
/// `claudeToolStart`, `claudeInputDelta` and friends. Nothing here does that:
/// Codex's own vocabulary maps directly onto the typed event model, which is
/// the entire reason the model is typed.
actor CodexTurnDecoder {
    private let turnID: UUID
    private let continuation: AsyncStream<AgentEvent>.Continuation
    private let permissions: any PermissionResolving
    private let permissionMode: PermissionMode
    private let clientID: AgentClientID

    private var threadID: String?
    private var messageOpen = false
    private var textBlockOpen = false
    private var thinkingBlockOpen = false
    private var finalUsage: UsageInfo?
    private var didFail = false
    private var failureMessage: String?
    private let startedAt = Date()

    /// `turn/start` returns as soon as the turn is *accepted* (its result says
    /// `status: inProgress`), not when it finishes. The real completion signal
    /// is the `turn/completed` / `turn/failed` notification, so the client waits
    /// on this instead of on the request.
    private var turnEndWaiters: [CheckedContinuation<Void, Never>] = []
    private var turnHasEnded = false

    init(
        turnID: UUID,
        continuation: AsyncStream<AgentEvent>.Continuation,
        permissions: any PermissionResolving,
        permissionMode: PermissionMode,
        clientID: AgentClientID
    ) {
        self.turnID = turnID
        self.continuation = continuation
        self.permissions = permissions
        self.permissionMode = permissionMode
        self.clientID = clientID
    }

    func recordThreadID(_ id: String) { threadID = id }

    // MARK: - Notifications

    func handleNotification(method: String, params: JSONValue) {
        switch method {
        case "item/agentMessage/delta", "item/agent_message/delta":
            guard let text = Self.firstString(params, ["delta", "text", "content"]) else { return }
            openTextBlock()
            continuation.yield(.textDelta(text))

        case "item/reasoning/textDelta",
             "item/reasoning/summaryTextDelta",
             "item/reasoning/summaryPartAdded":
            guard let text = Self.firstString(params, ["delta", "text", "content", "summary"]),
                  !text.isEmpty else { return }
            openThinkingBlock()
            continuation.yield(.thinkingDelta(text))

        case "item/started":
            guard let item = params["item"] ?? params["itemInfo"] else { return }
            emitToolStart(item)

        case "item/completed":
            guard let item = params["item"] ?? params["itemInfo"] else { return }
            emitToolCompletion(item)

        case "turn/plan/updated":
            guard let object = params.objectValue,
                  let items = TodoExtractor.parse(codexPlanUpdate: object) else { return }
            continuation.yield(.todos(items))

        case "thread/tokenUsage/updated":
            if let usage = Self.usage(from: params) {
                finalUsage = usage
                continuation.yield(.usage(usage))
            }
            if let window = Self.contextWindow(from: params) {
                continuation.yield(.contextWindow(window))
            }

        case "account/rateLimits/updated":
            if let message = Self.rateLimitSummary(from: params) {
                continuation.yield(.rateLimit(RateLimitInfo(message: message)))
            }

        case "turn/completed":
            if let usage = Self.usage(from: params) { finalUsage = usage }
            signalTurnEnd()

        case "turn/failed", "error":
            didFail = true
            failureMessage = Self.firstString(params, ["message", "error"])
                ?? params["error"]?["message"]?.stringValue
                ?? params["turn"]?["error"]?["message"]?.stringValue
            signalTurnEnd()

        default:
            break
        }
    }

    // MARK: - Turn completion

    /// Suspends until `turn/completed` / `turn/failed` arrives, or until
    /// ``signalTurnEnd()`` is called because the child process died.
    func waitForTurnEnd() async {
        if turnHasEnded { return }
        await withCheckedContinuation { continuation in
            turnEndWaiters.append(continuation)
        }
    }

    func signalTurnEnd() {
        guard !turnHasEnded else { return }
        turnHasEnded = true
        for waiter in turnEndWaiters { waiter.resume() }
        turnEndWaiters.removeAll()
    }

    // MARK: - Agent -> client requests

    func handleServerRequest(
        method: String,
        params: JSONValue
    ) async -> Result<JSONValue, JSONRPCConnection.JSONRPCError> {
        switch method {
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval",
             "request/approval":
            let decision = await resolveApproval(params)
            return .success(.object([
                "decision": .string(decision.isAllowed ? "accept" : "reject"),
            ]))

        case "userInput/request", "mcpServer/elicitation/request":
            let decision = await resolveApproval(params)
            return .success(.object([
                "action": .string(decision.isAllowed ? "accept" : "decline"),
            ]))

        default:
            return .failure(.methodNotFound)
        }
    }

    private func resolveApproval(_ params: JSONValue) async -> PermissionDecision {
        let command = Self.firstString(params, ["command", "cmd"])
        let toolName = command == nil ? "Edit" : "Bash"

        var input: [String: JSONValue] = params.objectValue ?? [:]
        if let command { input["command"] = .string(command) }

        let request = PermissionRequest(
            id: Self.firstString(params, ["itemId", "callId", "id"]) ?? UUID().uuidString,
            toolName: toolName,
            toolInput: input,
            mode: permissionMode,
            clientID: clientID
        )
        continuation.yield(.permissionRequested(request))
        return await permissions.resolve(request)
    }

    // MARK: - Turn end

    func finishTurn(threadID: String) {
        closeOpenBlocks()
        if messageOpen {
            continuation.yield(.messageEnded(id: nil, usage: finalUsage))
            messageOpen = false
        }
        if didFail {
            continuation.yield(.failed(.agentReported(failureMessage ?? "The Codex turn failed.")))
            return
        }
        continuation.yield(.turnEnded(TurnResult(
            isError: false,
            durationMS: Int(Date().timeIntervalSince(startedAt) * 1000),
            usage: finalUsage,
            nativeSessionID: threadID
        )))
    }

    // MARK: - Blocks

    private func openMessage() {
        guard !messageOpen else { return }
        messageOpen = true
        continuation.yield(.messageStarted(role: .assistant, id: nil))
    }

    private func openTextBlock() {
        openMessage()
        if thinkingBlockOpen {
            continuation.yield(.blockEnded(.thinking))
            thinkingBlockOpen = false
        }
        guard !textBlockOpen else { return }
        textBlockOpen = true
        continuation.yield(.blockStarted(.text))
    }

    private func openThinkingBlock() {
        openMessage()
        if textBlockOpen {
            continuation.yield(.blockEnded(.text))
            textBlockOpen = false
        }
        guard !thinkingBlockOpen else { return }
        thinkingBlockOpen = true
        continuation.yield(.blockStarted(.thinking))
    }

    private func closeOpenBlocks() {
        if textBlockOpen {
            continuation.yield(.blockEnded(.text))
            textBlockOpen = false
        }
        if thinkingBlockOpen {
            continuation.yield(.blockEnded(.thinking))
            thinkingBlockOpen = false
        }
    }

    // MARK: - Tool items

    private func emitToolStart(_ item: JSONValue) {
        guard let name = Self.toolName(from: item), name != "message" else { return }
        let id = Self.firstString(item, ["id", "itemId", "callId"]) ?? UUID().uuidString

        openMessage()
        closeOpenBlocks()

        continuation.yield(.toolCallStarted(id: id, name: name))
        // Codex delivers complete arguments up front — no accumulation needed.
        let input = item["input"]?.objectValue
            ?? item["arguments"]?.objectValue
            ?? item.objectValue
            ?? [:]
        continuation.yield(.toolCallInput(id: id, input: input))
    }

    private func emitToolCompletion(_ item: JSONValue) {
        guard let name = Self.toolName(from: item), name != "message" else { return }
        let id = Self.firstString(item, ["id", "itemId", "callId"]) ?? UUID().uuidString
        continuation.yield(.toolCallResult(
            id: id,
            content: Self.toolOutput(from: item),
            isError: Self.indicatesError(item["error"]) || item["isError"]?.boolValue == true
        ))
    }

    // MARK: - Parsing

    /// Codex names items by *kind* rather than tool name. Normalizing to the
    /// Claude vocabulary keeps one set of typed renderers in the chat UI.
    static func toolName(from item: JSONValue) -> String? {
        if let mcpName = mcpToolName(from: item) { return mcpName }

        if let type = firstString(item, ["type", "kind"]) {
            let normalized = type.lowercased()
            if normalized.contains("command") { return "Bash" }
            if normalized.contains("file") || normalized.contains("patch") { return "Edit" }
            if normalized.contains("message") { return "message" }
            if normalized.contains("reasoning") { return nil }
            return type
        }
        guard let name = firstString(item, ["name", "toolName"]) else { return nil }
        return name.lowercased().contains("message") ? "message" : name
    }

    private static func mcpToolName(from item: JSONValue) -> String? {
        let type = firstString(item, ["type", "kind"])?.lowercased()
        let looksLikeMCP = type?.contains("mcp") == true
            || item["serverName"] != nil
            || item["server_name"] != nil
            || item["server"] != nil
        guard looksLikeMCP else { return nil }

        let tool = firstString(item, ["toolName", "tool_name", "name"]).flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.lowercased() != "mcptoolcall" else { return nil }
            return trimmed
        }
        guard let tool else { return nil }
        guard let server = firstString(item, ["serverName", "server_name", "server"]) else {
            return "mcp__\(tool)"
        }
        return "mcp__\(server)__\(tool)"
    }

    static func toolOutput(from item: JSONValue) -> String {
        for key in ["output", "result", "summary", "message"] {
            guard let value = item[key], !value.isNull else { continue }
            return stringify(value)
        }
        if let error = item["error"], indicatesError(error) { return stringify(error) }
        return ""
    }

    private static func stringify(_ value: JSONValue) -> String {
        if let text = value.stringValue { return text }
        if let array = value.arrayValue {
            return array.map { $0["text"]?.stringValue ?? stringify($0) }.joined(separator: "\n")
        }
        if let object = value.objectValue {
            for key in ["text", "output", "content", "message"] {
                if let text = object[key]?.stringValue { return text }
            }
        }
        return value.jsonString
    }

    static func indicatesError(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .null: return false
        case .bool(let flag): return flag
        case .string(let text):
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !normalized.isEmpty && !["false", "null", "none"].contains(normalized)
        case .number(let number): return number != 0
        case .array(let values): return !values.isEmpty
        case .object(let object): return !object.isEmpty
        }
    }

    static func firstString(_ value: JSONValue, _ keys: [String]) -> String? {
        guard let object = value.objectValue else { return nil }
        for key in keys {
            if let text = object[key]?.stringValue { return text }
        }
        return nil
    }

    /// Codex reports usage as `params.tokenUsage.total.{inputTokens, …}` — the
    /// `total` nesting is easy to miss and silently yields zeros without it.
    static func usage(from params: JSONValue) -> UsageInfo? {
        let container = params["tokenUsage"] ?? params["token_usage"] ?? params["usage"] ?? params
        let source = container["total"] ?? container
        guard let object = source.objectValue else { return nil }

        let input = object["inputTokens"]?.intValue ?? object["input_tokens"]?.intValue
        let output = object["outputTokens"]?.intValue ?? object["output_tokens"]?.intValue
        let cached = object["cachedInputTokens"]?.intValue ?? object["cached_input_tokens"]?.intValue

        guard input != nil || output != nil else { return nil }
        return UsageInfo(
            inputTokens: input ?? 0,
            outputTokens: output ?? 0,
            cacheReadTokens: cached ?? 0
        )
    }

    static func contextWindow(from params: JSONValue) -> ContextWindowInfo? {
        let container = params["tokenUsage"] ?? params["usage"] ?? params
        for candidate in [container, container["total"] ?? .null] {
            guard let object = candidate.objectValue else { continue }
            let used = object["tokensUsed"]?.intValue
                ?? object["totalTokens"]?.intValue
                ?? object["tokens_used"]?.intValue
            let budget = object["tokenBudget"]?.intValue
                ?? object["contextWindow"]?.intValue
                ?? object["token_budget"]?.intValue
            if let used, let budget, budget > 0 {
                return ContextWindowInfo(usedTokens: used, maxTokens: budget)
            }
        }
        return nil
    }

    static func rateLimitSummary(from params: JSONValue) -> String? {
        guard let limits = params["rateLimits"] else { return nil }
        guard let percent = limits["primary"]?["usedPercent"]?.numberValue else { return nil }
        return "Rate limit \(Int(percent))% used."
    }
}
#endif
