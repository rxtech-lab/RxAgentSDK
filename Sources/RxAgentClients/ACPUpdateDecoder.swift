#if os(macOS)
import Foundation
import RxAgentCore
import RxAgentProcess

/// Translates ACP `session/update` notifications into ``AgentEvent`` and serves
/// the agent's callbacks into the client (filesystem access, permission prompts).
///
/// Long-lived: it outlives a single turn because the pooled ACP process does,
/// so ``begin(turnID:continuation:permissions:permissionMode:)`` re-points it at
/// each new turn's stream.
actor ACPUpdateDecoder {
    private let clientID: AgentClientID

    private var continuation: AsyncStream<AgentEvent>.Continuation?
    private var permissions: (any PermissionResolving)?
    private var permissionMode: PermissionMode = .default
    private var startedAt = Date()

    private var messageOpen = false
    private var textBlockOpen = false
    private var thinkingBlockOpen = false
    /// Tool calls seen this turn, so an update for an unseen id can open one.
    private var liveToolCalls: Set<String> = []

    init(clientID: AgentClientID) {
        self.clientID = clientID
    }

    /// Point the decoder at a new turn's stream.
    func begin(
        turnID: UUID,
        continuation: AsyncStream<AgentEvent>.Continuation,
        permissions: any PermissionResolving,
        permissionMode: PermissionMode
    ) {
        self.continuation = continuation
        self.permissions = permissions
        self.permissionMode = permissionMode
        self.startedAt = Date()
        messageOpen = false
        textBlockOpen = false
        thinkingBlockOpen = false
        liveToolCalls.removeAll()
    }

    // MARK: - Notifications

    func handleNotification(method: String, params: JSONValue) {
        guard method == "session/update" else { return }
        guard let update = params["update"]?.objectValue,
              let kind = update["sessionUpdate"]?.stringValue
        else { return }

        switch kind {
        case "agent_message_chunk":
            let text = ACPToolNormalizer.text(from: update["content"])
            guard !text.isEmpty else { return }
            openTextBlock()
            continuation?.yield(.textDelta(text))

        case "agent_thought_chunk":
            let text = ACPToolNormalizer.text(from: update["content"])
            guard !text.isEmpty else { return }
            openThinkingBlock()
            continuation?.yield(.thinkingDelta(text))

        case "plan":
            if let items = TodoExtractor.parse(acpPlan: update) {
                continuation?.yield(.todos(items))
            }

        case "tool_call":
            emitToolCall(update)

        case "tool_call_update":
            emitToolCallUpdate(update)

        default:
            break
        }
    }

    // MARK: - Tool calls

    private func emitToolCall(_ update: [String: JSONValue]) {
        guard let toolCallID = update["toolCallId"]?.stringValue else { return }
        openMessage()
        closeOpenBlocks()

        let normalized = ACPToolNormalizer.normalize(
            kind: update["kind"]?.stringValue,
            title: update["title"]?.stringValue ?? "",
            update: update,
            rawInput: update["rawInput"]?.objectValue ?? [:]
        )

        liveToolCalls.insert(toolCallID)
        continuation?.yield(.toolCallStarted(id: toolCallID, name: normalized.name))
        continuation?.yield(.toolCallInput(id: toolCallID, input: normalized.input))
    }

    private func emitToolCallUpdate(_ update: [String: JSONValue]) {
        guard let toolCallID = update["toolCallId"]?.stringValue else { return }

        // Diffs often arrive only on the *update*, not the initial call, so a
        // late diff re-states the tool identity and input.
        let diffs = ACPToolNormalizer.diffEntries(in: update)
        if !diffs.isEmpty {
            let normalized = ACPToolNormalizer.normalize(
                kind: update["kind"]?.stringValue,
                title: update["title"]?.stringValue ?? "",
                update: update,
                rawInput: update["rawInput"]?.objectValue ?? [:]
            )
            if liveToolCalls.insert(toolCallID).inserted {
                openMessage()
                closeOpenBlocks()
                continuation?.yield(.toolCallStarted(id: toolCallID, name: normalized.name))
            }
            continuation?.yield(.toolCallInput(id: toolCallID, input: normalized.input))
        }

        let status = update["status"]?.stringValue ?? ""
        guard status == "completed" || status == "failed" else { return }

        let content = ACPToolNormalizer.text(from: update["content"] ?? update["rawOutput"])
        continuation?.yield(.toolCallResult(
            id: toolCallID,
            content: content,
            isError: status == "failed"
        ))
    }

    // MARK: - Agent -> client requests

    func handleServerRequest(
        method: String,
        params: JSONValue
    ) async -> Result<JSONValue, JSONRPCConnection.JSONRPCError> {
        switch method {
        case "fs/read_text_file":
            return readTextFile(params)
        case "fs/write_text_file":
            return writeTextFile(params)
        case "session/request_permission":
            return await requestPermission(params)
        default:
            return .failure(.methodNotFound)
        }
    }

    private func readTextFile(
        _ params: JSONValue
    ) -> Result<JSONValue, JSONRPCConnection.JSONRPCError> {
        guard let path = params["path"]?.stringValue else {
            return .failure(.init(code: -32602, message: "missing path"))
        }
        do {
            var content = try String(contentsOfFile: path, encoding: .utf8)
            // Optional line window.
            if let line = params["line"]?.intValue {
                let lines = content.components(separatedBy: "\n")
                let start = max(0, line - 1)
                let limit = params["limit"]?.intValue ?? (lines.count - start)
                let end = min(lines.count, start + max(0, limit))
                content = start < end ? lines[start..<end].joined(separator: "\n") : ""
            }
            return .success(.object(["content": .string(content)]))
        } catch {
            return .failure(.init(code: -32603, message: "could not read \(path): \(error)"))
        }
    }

    private func writeTextFile(
        _ params: JSONValue
    ) -> Result<JSONValue, JSONRPCConnection.JSONRPCError> {
        guard let path = params["path"]?.stringValue,
              let content = params["content"]?.stringValue
        else {
            return .failure(.init(code: -32602, message: "missing path or content"))
        }
        do {
            let url = URL(filePath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
            return .success(.object([:]))
        } catch {
            return .failure(.init(code: -32603, message: "could not write \(path): \(error)"))
        }
    }

    /// ACP lets the agent define its own option list, so the SDK's allow/deny
    /// decision has to be mapped back onto whichever option ids it offered.
    private func requestPermission(
        _ params: JSONValue
    ) async -> Result<JSONValue, JSONRPCConnection.JSONRPCError> {
        let toolCall = params["toolCall"] ?? .object([:])
        let normalized = ACPToolNormalizer.normalize(
            kind: toolCall["kind"]?.stringValue,
            title: toolCall["title"]?.stringValue ?? "",
            update: toolCall.objectValue ?? [:],
            rawInput: toolCall["rawInput"]?.objectValue ?? [:]
        )

        let request = PermissionRequest(
            id: toolCall["toolCallId"]?.stringValue ?? UUID().uuidString,
            toolName: normalized.name,
            toolInput: normalized.input,
            mode: permissionMode,
            clientID: clientID
        )
        continuation?.yield(.permissionRequested(request))

        let decision = await permissions?.resolve(request) ?? .deny
        let options = params["options"]?.arrayValue ?? []
        let wanted = decision.isAllowed ? "allow_once" : "reject_once"

        let optionID = options.first { $0["kind"]?.stringValue == wanted }?["optionId"]?.stringValue
            ?? options.first { $0["kind"]?.stringValue?.hasPrefix(decision.isAllowed ? "allow" : "reject") == true }?["optionId"]?.stringValue
            ?? options.first?["optionId"]?.stringValue

        guard let optionID else {
            return .success(.object(["outcome": .object(["outcome": .string("cancelled")])]))
        }
        return .success(.object([
            "outcome": .object([
                "outcome": .string("selected"),
                "optionId": .string(optionID),
            ]),
        ]))
    }

    // MARK: - Turn end

    func finishTurn(sessionID: String, stopReason: String?) {
        closeOpenBlocks()
        if messageOpen {
            continuation?.yield(.messageEnded(id: nil, usage: nil))
            messageOpen = false
        }
        continuation?.yield(.turnEnded(TurnResult(
            isError: stopReason == "refusal",
            durationMS: Int(Date().timeIntervalSince(startedAt) * 1000),
            usage: nil,
            nativeSessionID: sessionID
        )))
        continuation = nil
    }

    // MARK: - Blocks

    private func openMessage() {
        guard !messageOpen else { return }
        messageOpen = true
        continuation?.yield(.messageStarted(role: .assistant, id: nil))
    }

    private func openTextBlock() {
        openMessage()
        if thinkingBlockOpen {
            continuation?.yield(.blockEnded(.thinking))
            thinkingBlockOpen = false
        }
        guard !textBlockOpen else { return }
        textBlockOpen = true
        continuation?.yield(.blockStarted(.text))
    }

    private func openThinkingBlock() {
        openMessage()
        if textBlockOpen {
            continuation?.yield(.blockEnded(.text))
            textBlockOpen = false
        }
        guard !thinkingBlockOpen else { return }
        thinkingBlockOpen = true
        continuation?.yield(.blockStarted(.thinking))
    }

    private func closeOpenBlocks() {
        if textBlockOpen {
            continuation?.yield(.blockEnded(.text))
            textBlockOpen = false
        }
        if thinkingBlockOpen {
            continuation?.yield(.blockEnded(.thinking))
            thinkingBlockOpen = false
        }
    }
}
#endif
