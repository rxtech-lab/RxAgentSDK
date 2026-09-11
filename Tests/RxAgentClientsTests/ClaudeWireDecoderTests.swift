#if os(macOS)
import Foundation
import Testing
import RxAgentCore
@testable import RxAgentClients

/// Frames shaped exactly as `claude -p --output-format stream-json --verbose
/// --include-partial-messages` emits them.
private enum Wire {
    static let systemInit = #"""
    {"type":"system","subtype":"init","session_id":"abc-123","model":"claude-opus-4","tools":["Read","Bash"],"cwd":"/tmp"}
    """#

    static let textStart = #"{"type":"stream_event","session_id":"abc-123","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#
    static func textDelta(_ text: String) -> String {
        #"{"type":"stream_event","session_id":"abc-123","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}}"#
    }
    static let blockStop = #"{"type":"stream_event","session_id":"abc-123","event":{"type":"content_block_stop","index":0}}"#

    static let toolStart = #"{"type":"stream_event","session_id":"abc-123","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}}}"#
    static let toolInputA = #"{"type":"stream_event","session_id":"abc-123","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"git "}}}"#
    static let toolInputB = #"{"type":"stream_event","session_id":"abc-123","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"status\"}"}}}"#

    static let assistantMirror = #"""
    {"type":"assistant","session_id":"abc-123","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"Checking."}],"usage":{"input_tokens":1200,"output_tokens":45,"cache_read_input_tokens":800}}}
    """#

    static let toolResult = #"""
    {"type":"user","session_id":"abc-123","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":" M main.swift"}],"is_error":false}]}}
    """#

    static let result = #"""
    {"type":"result","subtype":"success","session_id":"abc-123","is_error":false,"duration_ms":3400,"total_cost_usd":0.0241,"usage":{"input_tokens":1200,"output_tokens":45},"context_window":{"used_tokens":13000,"max_tokens":200000}}
    """#

    static let taskNotification = #"""
    {"type":"result","subtype":"success","session_id":"abc-123","is_error":false,"origin":{"kind":"task-notification"}}
    """#
}

@Suite("ClaudeWireDecoder")
struct ClaudeWireDecoderTests {

    @Test("system/init yields sessionStarted with model and tools")
    func systemInit() {
        var decoder = ClaudeWireDecoder()
        let events = decoder.decode(line: Wire.systemInit)

        #expect(events.count == 1)
        guard case .sessionStarted(let started) = events[0] else {
            Issue.record("expected sessionStarted")
            return
        }
        #expect(started.nativeSessionID == "abc-123")
        #expect(started.model == "claude-opus-4")
        #expect(started.advertisedTools == ["Read", "Bash"])
        #expect(decoder.sessionID == "abc-123")
    }

    @Test("Partial text frames are delegated to the assembler")
    func partialText() {
        var decoder = ClaudeWireDecoder()
        _ = decoder.decode(line: Wire.systemInit)
        var events: [AgentEvent] = []
        events += decoder.decode(line: Wire.textStart)
        events += decoder.decode(line: Wire.textDelta("Hello"))
        events += decoder.decode(line: Wire.blockStop)

        let text = events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }
        #expect(text == ["Hello"])
    }

    @Test("Fragmented tool input surfaces once, complete")
    func toolInput() {
        var decoder = ClaudeWireDecoder()
        _ = decoder.decode(line: Wire.systemInit)
        var events: [AgentEvent] = []
        events += decoder.decode(line: Wire.toolStart)
        events += decoder.decode(line: Wire.toolInputA)
        events += decoder.decode(line: Wire.toolInputB)
        events += decoder.decode(line: Wire.blockStop)

        let inputs = events.compactMap {
            if case .toolCallInput(let id, let input) = $0 { (id, input) } else { nil }
        }
        #expect(inputs.count == 1)
        #expect(inputs.first?.1["command"]?.stringValue == "git status")
    }

    /// Claude re-sends the whole assistant message as a non-partial frame after
    /// streaming it. Emitting its content again would duplicate every reply.
    @Test("The assistant mirror frame does not duplicate streamed text")
    func assistantMirrorDoesNotDuplicate() {
        var decoder = ClaudeWireDecoder()
        _ = decoder.decode(line: Wire.systemInit)
        _ = decoder.decode(line: Wire.textStart)
        _ = decoder.decode(line: Wire.textDelta("Checking."))
        _ = decoder.decode(line: Wire.blockStop)

        let events = decoder.decode(line: Wire.assistantMirror)
        let text = events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }
        #expect(text.isEmpty, "content already arrived via partial frames")
        #expect(events.contains { if case .messageEnded = $0 { true } else { false } })

        let usage = events.compactMap { if case .usage(let u) = $0 { u } else { nil } }
        #expect(usage.first?.outputTokens == 45)
        #expect(usage.first?.cacheReadTokens == 800)
    }

    /// With partials disabled the same frame is the *only* source of content.
    @Test("Without partial frames the assistant frame is expanded")
    func assistantWithoutPartials() {
        var decoder = ClaudeWireDecoder()
        _ = decoder.decode(line: Wire.systemInit)
        let events = decoder.decode(line: Wire.assistantMirror)

        let text = events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }
        #expect(text == ["Checking."])
        #expect(events.contains { if case .messageStarted = $0 { true } else { false } })
    }

    @Test("Tool results arrive on the user frame")
    func toolResults() {
        var decoder = ClaudeWireDecoder()
        let events = decoder.decode(line: Wire.toolResult)

        #expect(events.count == 1)
        guard case .toolCallResult(let id, let content, let isError) = events[0] else {
            Issue.record("expected toolCallResult")
            return
        }
        #expect(id == "toolu_1")
        #expect(content == " M main.swift")
        #expect(!isError)
    }

    @Test("A string tool result is accepted as well as a block array")
    func stringToolResult() {
        let line = #"""
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t9","content":"plain text","is_error":true}]}}
        """#
        var decoder = ClaudeWireDecoder()
        let events = decoder.decode(line: line)

        guard case .toolCallResult(_, let content, let isError) = events[0] else {
            Issue.record("expected toolCallResult")
            return
        }
        #expect(content == "plain text")
        #expect(isError)
    }

    @Test("result yields usage, context window and turnEnded")
    func resultFrame() {
        var decoder = ClaudeWireDecoder()
        _ = decoder.decode(line: Wire.systemInit)
        let events = decoder.decode(line: Wire.result)

        let window = events.compactMap { if case .contextWindow(let w) = $0 { w } else { nil } }
        #expect(window.first?.usedTokens == 13_000)
        #expect(window.first?.maxTokens == 200_000)

        let ended = events.compactMap { if case .turnEnded(let r) = $0 { r } else { nil } }
        #expect(ended.count == 1)
        #expect(ended.first?.durationMS == 3400)
        #expect(ended.first?.usage?.totalCostUSD == 0.0241)
        #expect(ended.first?.nativeSessionID == "abc-123")
        #expect(ended.first?.isBackgroundFollowUp == false)
    }

    /// A background task's result must not be mistaken for the turn ending.
    @Test("A task-notification result is flagged as a background follow-up")
    func taskNotificationResult() {
        var decoder = ClaudeWireDecoder()
        let events = decoder.decode(line: Wire.taskNotification)
        let ended = events.compactMap { if case .turnEnded(let r) = $0 { r } else { nil } }
        #expect(ended.first?.isBackgroundFollowUp == true)
    }

    @Test("Background task lifecycle frames map to backgroundTask events")
    func backgroundTasks() {
        var decoder = ClaudeWireDecoder()
        let started = decoder.decode(
            line: #"{"type":"system","subtype":"task_started","task_id":"bg1","session_id":"s"}"#
        )
        guard case .backgroundTask(let event) = started[0] else {
            Issue.record("expected backgroundTask")
            return
        }
        #expect(event.taskID == "bg1")
        #expect(event.status == .started)

        let completed = decoder.decode(
            line: #"{"type":"system","subtype":"task_completed","task_id":"bg1","session_id":"s"}"#
        )
        guard case .backgroundTask(let done) = completed[0] else {
            Issue.record("expected backgroundTask")
            return
        }
        #expect(done.status == .completed)
    }

    @Test("Unknown frames and garbage are ignored")
    func ignoresGarbage() {
        var decoder = ClaudeWireDecoder()
        #expect(decoder.decode(line: "").isEmpty)
        #expect(decoder.decode(line: "not json").isEmpty)
        #expect(decoder.decode(line: #"{"type":"something_new"}"#).isEmpty)
    }

    /// The full path a real turn takes, decoder straight into the reducer.
    @Test("A complete turn decodes into a correct transcript")
    func fullTurn() {
        var decoder = ClaudeWireDecoder()
        var reducer = TranscriptReducer()

        for line in [
            Wire.systemInit,
            Wire.textStart, Wire.textDelta("Checking."), Wire.blockStop,
            Wire.toolStart, Wire.toolInputA, Wire.toolInputB, Wire.blockStop,
            Wire.assistantMirror,
            Wire.toolResult,
            Wire.result,
        ] {
            for event in decoder.decode(line: line) {
                _ = reducer.apply(event)
            }
        }

        #expect(reducer.nativeSessionID == "abc-123")
        #expect(reducer.messages.count == 1)

        let message = reducer.messages[0]
        #expect(message.plainText == "Checking.")
        #expect(message.isStreaming == false)

        let call = try! #require(message.toolCalls.first)
        #expect(call.name == "Bash")
        #expect(call.input["command"]?.stringValue == "git status")
        #expect(call.result == " M main.swift")
        #expect(reducer.usage?.totalCostUSD == 0.0241)
    }
}
#endif

// MARK: - Tool scoping

#if os(macOS)
@Suite("Claude tool scoping arguments")
struct ClaudeToolScopingTests {

    private func request(
        allowed: [String]? = nil,
        disallowed: [String] = []
    ) -> AgentSendRequest {
        AgentSendRequest(
            threadID: AgentThreadID(),
            prompt: "x",
            workingDirectory: URL(filePath: "/tmp"),
            mcpServers: [.http(name: "film_workflow", url: URL(string: "http://127.0.0.1:1/mcp")!)],
            allowedTools: allowed,
            disallowedTools: disallowed
        )
    }

    @Test("With no turn allowlist the client's pre-approved set is used")
    func fallsBackToPreapproved() {
        let argument = ClaudeCodeClient.allowedToolArgument(
            for: request(),
            preapproved: ["Read", "Grep"]
        )
        #expect(argument == ["Read", "Grep"])
    }

    /// An allowlist means the host enumerated its whole surface. Re-adding
    /// `Read`/`Bash` underneath it would defeat the point for an app whose agent
    /// has no business touching the filesystem.
    @Test("A turn allowlist replaces the pre-approved set rather than extending it")
    func allowlistReplacesPreapproved() {
        let argument = ClaudeCodeClient.allowedToolArgument(
            for: request(allowed: ["caption_export"]),
            preapproved: ["Read", "Bash"]
        )
        #expect(!argument.contains("Read"))
        #expect(!argument.contains("Bash"))
        #expect(argument.contains("caption_export"))
        #expect(argument.contains("mcp__film_workflow__caption_export"))
    }

    @Test("A denied tool never reaches the allowlist")
    func denyBeatsAllow() {
        let argument = ClaudeCodeClient.allowedToolArgument(
            for: request(allowed: ["caption_export", "delete_project"],
                         disallowed: ["delete_project"]),
            preapproved: []
        )
        #expect(argument.contains("caption_export"))
        #expect(!argument.contains("delete_project"))
    }

    @Test("Denied tools are expanded into every namespaced spelling")
    func denylistExpansion() {
        let argument = ClaudeCodeClient.disallowedToolArgument(
            for: request(disallowed: ["delete_project"])
        )
        #expect(argument.contains("delete_project"))
        #expect(argument.contains("mcp__film_workflow__delete_project"))
    }
}
#endif
