#if os(macOS)
import Foundation
import Testing
import RxAgentCore
@testable import RxAgentClients

// MARK: - Helpers

/// Drive a decoder against a live continuation and collect everything it emits.
private func collect(
    _ body: @escaping @Sendable (AsyncStream<AgentEvent>.Continuation) async -> Void
) async -> [AgentEvent] {
    var events: [AgentEvent] = []
    let stream = AsyncStream<AgentEvent> { continuation in
        Task {
            await body(continuation)
            continuation.finish()
        }
    }
    for await event in stream { events.append(event) }
    return events
}

private extension [AgentEvent] {
    var text: [String] { compactMap { if case .textDelta(let t) = $0 { t } else { nil } } }
    var thinking: [String] { compactMap { if case .thinkingDelta(let t) = $0 { t } else { nil } } }
    var toolStarts: [(String, String)] {
        compactMap { if case .toolCallStarted(let id, let name) = $0 { (id, name) } else { nil } }
    }
    var toolInputs: [(String, [String: JSONValue])] {
        compactMap { if case .toolCallInput(let id, let input) = $0 { (id, input) } else { nil } }
    }
    var toolResults: [(String, String, Bool)] {
        compactMap {
            if case .toolCallResult(let id, let c, let e) = $0 { (id, c, e) } else { nil }
        }
    }
}

// MARK: - Codex

/// Payloads copied from a real `codex app-server` session (codex-cli 0.144.2).
@Suite("CodexTurnDecoder")
struct CodexTurnDecoderTests {

    private func makeDecoder(
        _ continuation: AsyncStream<AgentEvent>.Continuation
    ) -> CodexTurnDecoder {
        CodexTurnDecoder(
            turnID: UUID(),
            continuation: continuation,
            permissions: AllowAllPermissions(),
            permissionMode: .default,
            clientID: .codex
        )
    }

    @Test("agentMessage deltas become text")
    func agentMessageDeltas() async {
        let events = await collect { continuation in
            let decoder = makeDecoder(continuation)
            for chunk in ["pine", "apple"] {
                await decoder.handleNotification(
                    method: "item/agentMessage/delta",
                    params: .object([
                        "threadId": .string("t1"),
                        "itemId": .string("msg_1"),
                        "delta": .string(chunk),
                    ])
                )
            }
            await decoder.finishTurn(threadID: "t1")
        }

        #expect(events.text == ["pine", "apple"])
        #expect(events.contains { if case .messageStarted = $0 { true } else { false } })
        #expect(events.contains { if case .turnEnded = $0 { true } else { false } })
    }

    @Test("Reasoning deltas become thinking")
    func reasoningDeltas() async {
        let events = await collect { continuation in
            let decoder = makeDecoder(continuation)
            await decoder.handleNotification(
                method: "item/reasoning/summaryTextDelta",
                params: .object(["delta": .string("considering options")])
            )
            await decoder.finishTurn(threadID: "t1")
        }
        #expect(events.thinking == ["considering options"])
    }

    /// Codex names items by kind, not by tool name.
    @Test("A commandExecution item maps to Bash with complete input")
    func commandExecutionItem() async {
        let events = await collect { continuation in
            let decoder = makeDecoder(continuation)
            await decoder.handleNotification(method: "item/started", params: .object([
                "item": .object([
                    "type": .string("commandExecution"),
                    "id": .string("item_1"),
                    "input": .object(["command": .string("git status")]),
                ]),
            ]))
            await decoder.handleNotification(method: "item/completed", params: .object([
                "item": .object([
                    "type": .string("commandExecution"),
                    "id": .string("item_1"),
                    "output": .string(" M main.swift"),
                ]),
            ]))
            await decoder.finishTurn(threadID: "t1")
        }

        #expect(events.toolStarts.count == 1)
        #expect(events.toolStarts[0].1 == "Bash")
        // Codex sends arguments complete; nothing to accumulate.
        #expect(events.toolInputs[0].1["command"]?.stringValue == "git status")
        #expect(events.toolResults[0].1 == " M main.swift")
        #expect(events.toolResults[0].2 == false)
    }

    @Test("A fileChange item maps to Edit")
    func fileChangeItem() async {
        let events = await collect { continuation in
            let decoder = makeDecoder(continuation)
            await decoder.handleNotification(method: "item/started", params: .object([
                "item": .object([
                    "type": .string("fileChange"),
                    "id": .string("item_2"),
                    "input": .object(["path": .string("/tmp/a.swift")]),
                ]),
            ]))
            await decoder.finishTurn(threadID: "t1")
        }
        #expect(events.toolStarts[0].1 == "Edit")
    }

    /// The agent's own message items must not surface as tool calls.
    @Test("userMessage and agentMessage items are not tool calls")
    func messageItemsAreNotTools() async {
        let events = await collect { continuation in
            let decoder = makeDecoder(continuation)
            for type in ["userMessage", "agentMessage"] {
                await decoder.handleNotification(method: "item/started", params: .object([
                    "item": .object(["type": .string(type), "id": .string("m")]),
                ]))
            }
            await decoder.finishTurn(threadID: "t1")
        }
        #expect(events.toolStarts.isEmpty)
    }

    @Test("An MCP item keeps its namespaced tool name")
    func mcpItem() async {
        let events = await collect { continuation in
            let decoder = makeDecoder(continuation)
            await decoder.handleNotification(method: "item/started", params: .object([
                "item": .object([
                    "type": .string("mcpToolCall"),
                    "id": .string("item_3"),
                    "serverName": .string("node_repl"),
                    "toolName": .string("run"),
                ]),
            ]))
            await decoder.finishTurn(threadID: "t1")
        }
        #expect(events.toolStarts[0].1 == "mcp__node_repl__run")
    }

    @Test("Plan updates become todos")
    func planUpdates() async {
        let events = await collect { continuation in
            let decoder = makeDecoder(continuation)
            await decoder.handleNotification(method: "turn/plan/updated", params: .object([
                "plan": .array([
                    .object(["step": .string("Read the file"), "status": .string("completed")]),
                    .object(["step": .string("Edit it"), "status": .string("inProgress")]),
                ]),
            ]))
            await decoder.finishTurn(threadID: "t1")
        }

        let todos = events.compactMap { if case .todos(let t) = $0 { t } else { nil } }
        #expect(todos.first?.count == 2)
        #expect(todos.first?[1].status == .inProgress)
    }

    /// Usage lives under `tokenUsage.total`; missing the nesting silently
    /// reports zero tokens.
    @Test("Token usage is read from the nested total object")
    func tokenUsageNesting() async {
        let events = await collect { continuation in
            let decoder = makeDecoder(continuation)
            await decoder.handleNotification(
                method: "thread/tokenUsage/updated",
                params: .object([
                    "threadId": .string("t1"),
                    "tokenUsage": .object([
                        "total": .object([
                            "totalTokens": .number(20424),
                            "inputTokens": .number(20418),
                            "cachedInputTokens": .number(9984),
                            "outputTokens": .number(6),
                        ]),
                    ]),
                ])
            )
            await decoder.finishTurn(threadID: "t1")
        }

        let usage = events.compactMap { if case .usage(let u) = $0 { u } else { nil } }
        #expect(usage.first?.inputTokens == 20418)
        #expect(usage.first?.outputTokens == 6)
        #expect(usage.first?.cacheReadTokens == 9984)
    }

    @Test("turn/failed surfaces the agent's message")
    func turnFailed() async {
        let events = await collect { continuation in
            let decoder = makeDecoder(continuation)
            await decoder.handleNotification(
                method: "turn/failed",
                params: .object(["message": .string("model unavailable")])
            )
            await decoder.finishTurn(threadID: "t1")
        }

        let failures = events.compactMap { if case .failed(let e) = $0 { e } else { nil } }
        #expect(failures.first?.description.contains("model unavailable") == true)
        #expect(!events.contains { if case .turnEnded = $0 { true } else { false } })
    }

    @Test("Approval requests are routed to the resolver")
    func approvalRequest() async {
        let events = await collect { continuation in
            let decoder = makeDecoder(continuation)
            let outcome = await decoder.handleServerRequest(
                method: "item/commandExecution/requestApproval",
                params: .object(["command": .string("rm -rf build"), "itemId": .string("i1")])
            )
            guard case .success(let value) = outcome else {
                Issue.record("expected success")
                return
            }
            #expect(value["decision"]?.stringValue == "accept")
            await decoder.finishTurn(threadID: "t1")
        }

        let requests = events.compactMap {
            if case .permissionRequested(let r) = $0 { r } else { nil }
        }
        #expect(requests.first?.toolName == "Bash")
        #expect(requests.first?.command == "rm -rf build")
    }

    @Test("Thread ids are read from the nested thread object")
    func threadIDParsing() {
        let result = JSONValue.object([
            "thread": .object(["id": .string("01a04357-a623"), "sessionId": .string("x")]),
        ])
        #expect(CodexClient.threadID(from: result) == "01a04357-a623")
        #expect(CodexClient.threadID(from: .object(["threadId": .string("abc")])) == "abc")
    }
}

// MARK: - ACP

@Suite("ACPToolNormalizer")
struct ACPToolNormalizerTests {

    @Test("A single diff with no prior content is a Write")
    func createFileIsWrite() {
        let update: [String: JSONValue] = ["content": .array([.object([
            "type": .string("diff"),
            "path": .string("/tmp/new.swift"),
            "oldText": .null,
            "newText": .string("let x = 1"),
        ])])]

        let normalized = ACPToolNormalizer.normalize(
            kind: "edit", title: "Create", update: update, rawInput: [:]
        )
        #expect(normalized.name == "Write")
        #expect(normalized.input["file_path"]?.stringValue == "/tmp/new.swift")
        #expect(normalized.input["content"]?.stringValue == "let x = 1")
    }

    @Test("A single diff with prior content is an Edit")
    func modifyFileIsEdit() {
        let update: [String: JSONValue] = ["content": .array([.object([
            "type": .string("diff"),
            "path": .string("/tmp/a.swift"),
            "oldText": .string("old"),
            "newText": .string("new"),
        ])])]

        let normalized = ACPToolNormalizer.normalize(
            kind: "edit", title: "Edit", update: update, rawInput: [:]
        )
        #expect(normalized.name == "Edit")
        #expect(normalized.input["old_string"]?.stringValue == "old")
        #expect(normalized.input["new_string"]?.stringValue == "new")
    }

    @Test("Several diffs on one file become a MultiEdit")
    func multipleDiffsAreMultiEdit() {
        let update: [String: JSONValue] = ["content": .array([
            .object([
                "type": .string("diff"), "path": .string("/tmp/a.swift"),
                "oldText": .string("a"), "newText": .string("b"),
            ]),
            .object([
                "type": .string("diff"), "path": .string("/tmp/a.swift"),
                "oldText": .string("c"), "newText": .string("d"),
            ]),
        ])]

        let normalized = ACPToolNormalizer.normalize(
            kind: "edit", title: "Edit", update: update, rawInput: [:]
        )
        #expect(normalized.name == "MultiEdit")
        #expect(normalized.input["edits"]?.arrayValue?.count == 2)
    }

    @Test("Kinds map to the Claude tool vocabulary")
    func kindMapping() {
        func name(_ kind: String, title: String = "") -> String {
            ACPToolNormalizer.normalize(kind: kind, title: title, update: [:], rawInput: [:]).name
        }
        #expect(name("read") == "Read")
        #expect(name("execute", title: "ls -la") == "Bash")
        #expect(name("search") == "Grep")
        #expect(name("fetch") == "WebFetch")
    }

    @Test("An execute call without an explicit command falls back to its title")
    func executeUsesTitleAsCommand() {
        let normalized = ACPToolNormalizer.normalize(
            kind: "execute", title: "npm test", update: [:], rawInput: [:]
        )
        #expect(normalized.input["command"]?.stringValue == "npm test")
    }

    @Test("A custom mapping wins over the built-in rules")
    func customMapping() {
        let normalized = ACPToolNormalizer.normalize(
            kind: "special", title: "", update: [:], rawInput: [:],
            customMapping: ["special": "MyTool"]
        )
        #expect(normalized.name == "MyTool")
    }

    @Test("Content blocks flatten to text")
    func textFlattening() {
        #expect(ACPToolNormalizer.text(from: .string("plain")) == "plain")
        #expect(ACPToolNormalizer.text(from: .array([
            .object(["type": .string("text"), "text": .string("one")]),
            .object(["type": .string("text"), "text": .string("two")]),
        ])) == "one\ntwo")
        #expect(ACPToolNormalizer.text(from: nil).isEmpty)
    }
}

@Suite("ACPUpdateDecoder")
struct ACPUpdateDecoderTests {

    private func session(
        _ continuation: AsyncStream<AgentEvent>.Continuation
    ) async -> ACPUpdateDecoder {
        let decoder = ACPUpdateDecoder(clientID: .acp("test"))
        await decoder.begin(
            turnID: UUID(),
            continuation: continuation,
            permissions: AllowAllPermissions(),
            permissionMode: .default
        )
        return decoder
    }

    private func update(_ fields: [String: JSONValue]) -> JSONValue {
        .object(["update": .object(fields)])
    }

    @Test("Message chunks become text deltas")
    func messageChunks() async {
        let events = await collect { continuation in
            let decoder = await session(continuation)
            await decoder.handleNotification(method: "session/update", params: update([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string("hello")]),
            ]))
            await decoder.finishTurn(sessionID: "s1", stopReason: "end_turn")
        }
        #expect(events.text == ["hello"])
    }

    @Test("Thought chunks become thinking deltas")
    func thoughtChunks() async {
        let events = await collect { continuation in
            let decoder = await session(continuation)
            await decoder.handleNotification(method: "session/update", params: update([
                "sessionUpdate": .string("agent_thought_chunk"),
                "content": .object(["type": .string("text"), "text": .string("hmm")]),
            ]))
            await decoder.finishTurn(sessionID: "s1", stopReason: nil)
        }
        #expect(events.thinking == ["hmm"])
    }

    @Test("A tool call carries a normalized name and input")
    func toolCall() async {
        let events = await collect { continuation in
            let decoder = await session(continuation)
            await decoder.handleNotification(method: "session/update", params: update([
                "sessionUpdate": .string("tool_call"),
                "toolCallId": .string("tc1"),
                "kind": .string("execute"),
                "title": .string("git status"),
                "rawInput": .object(["command": .string("git status")]),
            ]))
            await decoder.handleNotification(method: "session/update", params: update([
                "sessionUpdate": .string("tool_call_update"),
                "toolCallId": .string("tc1"),
                "status": .string("completed"),
                "content": .array([.object([
                    "type": .string("text"), "text": .string(" M main.swift"),
                ])]),
            ]))
            await decoder.finishTurn(sessionID: "s1", stopReason: "end_turn")
        }

        #expect(events.toolStarts[0] == ("tc1", "Bash"))
        #expect(events.toolInputs[0].1["command"]?.stringValue == "git status")
        #expect(events.toolResults[0].1 == " M main.swift")
    }

    /// Diffs frequently arrive only on the update, never on the initial call.
    @Test("A diff arriving late re-states the tool as an Edit")
    func lateDiffOpensToolCall() async {
        let events = await collect { continuation in
            let decoder = await session(continuation)
            await decoder.handleNotification(method: "session/update", params: update([
                "sessionUpdate": .string("tool_call_update"),
                "toolCallId": .string("tc2"),
                "status": .string("completed"),
                "content": .array([.object([
                    "type": .string("diff"),
                    "path": .string("/tmp/a.swift"),
                    "oldText": .string("old"),
                    "newText": .string("new"),
                ])]),
            ]))
            await decoder.finishTurn(sessionID: "s1", stopReason: nil)
        }

        #expect(events.toolStarts.contains { $0.1 == "Edit" })
        #expect(events.toolInputs[0].1["new_string"]?.stringValue == "new")
    }

    @Test("A failed tool call is reported as an error")
    func failedToolCall() async {
        let events = await collect { continuation in
            let decoder = await session(continuation)
            await decoder.handleNotification(method: "session/update", params: update([
                "sessionUpdate": .string("tool_call"),
                "toolCallId": .string("tc3"),
                "kind": .string("execute"),
                "title": .string("false"),
            ]))
            await decoder.handleNotification(method: "session/update", params: update([
                "sessionUpdate": .string("tool_call_update"),
                "toolCallId": .string("tc3"),
                "status": .string("failed"),
                "content": .array([.object([
                    "type": .string("text"), "text": .string("exit 1"),
                ])]),
            ]))
            await decoder.finishTurn(sessionID: "s1", stopReason: nil)
        }
        #expect(events.toolResults[0].2 == true)
    }

    @Test("Plans become todos")
    func plans() async {
        let events = await collect { continuation in
            let decoder = await session(continuation)
            await decoder.handleNotification(method: "session/update", params: update([
                "sessionUpdate": .string("plan"),
                "entries": .array([
                    .object(["content": .string("Step one"), "status": .string("completed")]),
                    .object(["content": .string("Step two"), "status": .string("pending")]),
                ]),
            ]))
            await decoder.finishTurn(sessionID: "s1", stopReason: nil)
        }

        let todos = events.compactMap { if case .todos(let t) = $0 { t } else { nil } }
        #expect(todos.first?.count == 2)
        #expect(todos.first?[0].status == .completed)
    }

    @Test("fs/read_text_file serves the agent a real file")
    func readTextFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "acp-read-\(UUID().uuidString).txt")
        try "line1\nline2\nline3".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        _ = await collect { continuation in
            let decoder = await session(continuation)
            let outcome = await decoder.handleServerRequest(
                method: "fs/read_text_file",
                params: .object(["path": .string(url.path)])
            )
            guard case .success(let value) = outcome else {
                Issue.record("expected success")
                return
            }
            #expect(value["content"]?.stringValue == "line1\nline2\nline3")

            let windowed = await decoder.handleServerRequest(
                method: "fs/read_text_file",
                params: .object([
                    "path": .string(url.path),
                    "line": .number(2),
                    "limit": .number(1),
                ])
            )
            guard case .success(let slice) = windowed else {
                Issue.record("expected success")
                return
            }
            #expect(slice["content"]?.stringValue == "line2")
        }
    }

    @Test("fs/write_text_file writes through")
    func writeTextFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "acp-write-\(UUID().uuidString)/nested.txt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        _ = await collect { continuation in
            let decoder = await session(continuation)
            let outcome = await decoder.handleServerRequest(
                method: "fs/write_text_file",
                params: .object(["path": .string(url.path), "content": .string("written")])
            )
            guard case .success = outcome else {
                Issue.record("expected success")
                return
            }
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "written")
    }

    /// The agent defines its own option ids; the decision has to be mapped
    /// back onto whichever ones it offered.
    @Test("A permission decision selects the matching agent option")
    func permissionMapsToOptionID() async {
        _ = await collect { continuation in
            let decoder = await session(continuation)
            let outcome = await decoder.handleServerRequest(
                method: "session/request_permission",
                params: .object([
                    "toolCall": .object([
                        "toolCallId": .string("tc9"),
                        "kind": .string("execute"),
                        "title": .string("rm -rf /"),
                    ]),
                    "options": .array([
                        .object(["optionId": .string("opt-yes"), "kind": .string("allow_once")]),
                        .object(["optionId": .string("opt-no"), "kind": .string("reject_once")]),
                    ]),
                ])
            )
            guard case .success(let value) = outcome else {
                Issue.record("expected success")
                return
            }
            #expect(value["outcome"]?["outcome"]?.stringValue == "selected")
            #expect(value["outcome"]?["optionId"]?.stringValue == "opt-yes")
        }
    }

    @Test("A refusal stop reason marks the turn as an error")
    func refusalStopReason() async {
        let events = await collect { continuation in
            let decoder = await session(continuation)
            await decoder.finishTurn(sessionID: "s1", stopReason: "refusal")
        }
        let ended = events.compactMap { if case .turnEnded(let r) = $0 { r } else { nil } }
        #expect(ended.first?.isError == true)
        #expect(ended.first?.nativeSessionID == "s1")
    }

    @Test("Unknown methods are reported as method-not-found")
    func unknownServerRequest() async {
        _ = await collect { continuation in
            let decoder = await session(continuation)
            let outcome = await decoder.handleServerRequest(method: "nope", params: .object([:]))
            guard case .failure(let error) = outcome else {
                Issue.record("expected failure")
                return
            }
            #expect(error.code == -32601)
        }
    }
}

@Suite("ACPRuntime capability parsing")
struct ACPRuntimeTests {

    /// Sending an unsupported transport makes conforming agents reject the
    /// whole `session/new`.
    @Test("Transport support is read from agentCapabilities")
    func transportSupport() {
        let result = JSONValue.object([
            "agentCapabilities": .object([
                "mcpCapabilities": .object([
                    "http": .bool(true),
                    "sse": .bool(false),
                ]),
            ]),
        ])
        #expect(ACPRuntime.supports(transport: "http", in: result))
        #expect(!ACPRuntime.supports(transport: "sse", in: result))
        #expect(!ACPRuntime.supports(transport: "http", in: .object([:])))
    }

    @Test("Model options are parsed from config options")
    func modelOptions() {
        let result = JSONValue.object(["configOptions": .array([
            .object([
                "value": .string("sonnet"),
                "name": .string("Sonnet"),
                "description": .string("Balanced"),
            ]),
            .object(["value": .string("opus"), "name": .string("Opus")]),
        ])])

        let options = try! #require(ACPRuntime.modelOptions(from: result))
        #expect(options.count == 2)
        #expect(options[0].id == "sonnet")
        #expect(options[0].modelDescription == "Balanced")
        #expect(ACPRuntime.modelOptions(from: .object([:])) == nil)
    }
}
#endif
