import Foundation
import RxAgentCore
import Testing

@testable import RxAgentLLM

@Suite("OpenAI message encoding")
struct OpenAIMessageEncodingTests {

    @Test("A plain message encodes content as a string")
    func plainContent() {
        let encoded = OpenAIMessage(role: "user", text: "hello").encoded()
        #expect(encoded["role"]?.stringValue == "user")
        #expect(encoded["content"]?.stringValue == "hello")
    }

    @Test("A cached message encodes as a one-part array carrying cache_control")
    func cacheControl() {
        // Anthropic-style cache breakpoints only exist on the parts form, so a
        // cached plain-text message has to be promoted to an array.
        let encoded = OpenAIMessage(role: "system", text: "rules", cacheControl: true).encoded()
        guard case .array(let parts)? = encoded["content"] else {
            Issue.record("expected an array content")
            return
        }
        #expect(parts.count == 1)
        #expect(parts[0]["text"]?.stringValue == "rules")
        #expect(parts[0]["cache_control"]?["type"]?.stringValue == "ephemeral")
    }

    @Test("Image parts encode as image_url entries")
    func imageParts() {
        let encoded = OpenAIMessage(
            role: "user",
            parts: [.text("Result of shot:"), .imageURL("data:image/png;base64,AAA")]
        ).encoded()

        guard case .array(let parts)? = encoded["content"] else {
            Issue.record("expected an array content")
            return
        }
        #expect(parts.count == 2)
        #expect(parts[0]["type"]?.stringValue == "text")
        #expect(parts[1]["type"]?.stringValue == "image_url")
        #expect(parts[1]["image_url"]?["url"]?.stringValue == "data:image/png;base64,AAA")
    }

    @Test("A tool message carries its call id and name")
    func toolMessage() {
        let encoded = OpenAIMessage(
            role: "tool",
            text: #"{"ok":true}"#,
            toolCallID: "call_1",
            name: "caption_export"
        ).encoded()

        #expect(encoded["role"]?.stringValue == "tool")
        #expect(encoded["tool_call_id"]?.stringValue == "call_1")
        #expect(encoded["name"]?.stringValue == "caption_export")
    }

    @Test("An assistant message carries tool_calls in the function shape")
    func assistantToolCalls() {
        let encoded = OpenAIMessage(
            role: "assistant",
            toolCalls: [OpenAIToolCall(id: "c1", name: "grep", argumentsJSON: #"{"q":"x"}"#)]
        ).encoded()

        guard case .array(let calls)? = encoded["tool_calls"] else {
            Issue.record("expected tool_calls")
            return
        }
        #expect(calls[0]["id"]?.stringValue == "c1")
        #expect(calls[0]["type"]?.stringValue == "function")
        #expect(calls[0]["function"]?["name"]?.stringValue == "grep")
        #expect(calls[0]["function"]?["arguments"]?.stringValue == #"{"q":"x"}"#)
    }
}

@Suite("OpenAI endpoint resolution")
struct OpenAIEndpointTests {

    @Test("A base URL gains the completions path")
    func appendsPath() {
        let url = OpenAIChatClient.completionsURL(for: URL(string: "https://api.example.com/v1")!)
        #expect(url.absoluteString == "https://api.example.com/v1/chat/completions")
    }

    @Test("A full completions URL is left alone")
    func leavesFullURL() {
        let original = URL(string: "https://api.example.com/v1/chat/completions")!
        #expect(OpenAIChatClient.completionsURL(for: original) == original)
    }
}

@Suite("OpenAI conversation seeding")
struct OpenAISeedTests {

    private func request(
        prompt: String = "do the thing",
        contextText: String = "you are a test",
        history: [AgentMessage] = []
    ) -> AgentSendRequest {
        AgentSendRequest(
            threadID: AgentThreadID(),
            prompt: prompt,
            workingDirectory: URL(filePath: "/tmp"),
            contextText: contextText,
            history: history
        )
    }

    @Test("The system prompt leads and is marked cacheable")
    func systemFirst() {
        let messages = OpenAIChatClient.seed(request())
        #expect(messages.first?.role == "system")
        #expect(messages.first?.cacheControl == true)
    }

    @Test("History is replayed between the system prompt and this turn")
    func replaysHistory() {
        let history = [
            AgentMessage.text("earlier question", role: .user),
            AgentMessage.text("earlier answer", role: .assistant),
        ]
        let messages = OpenAIChatClient.seed(request(history: history))

        #expect(messages.map(\.role) == ["system", "user", "assistant", "user"])
        #expect(messages[1].text == "earlier question")
        #expect(messages[2].text == "earlier answer")
        #expect(messages[3].text == "do the thing")
    }

    @Test("Historical tool calls are not replayed")
    func dropsHistoricalToolCalls() {
        // A replayed tool_call without its matching tool result is a malformed
        // conversation, and re-sending settled tool traffic costs more than the
        // prose summary of it is worth.
        let call = AgentToolCall(id: "c1", name: "grep", result: "found", hasCompleteInput: true)
        let message = AgentMessage(
            role: .assistant,
            blocks: [.toolCall(call), .text(id: UUID(), "I searched.")]
        )
        let messages = OpenAIChatClient.seed(request(history: [message]))

        #expect(messages.allSatisfy { $0.toolCalls.isEmpty })
        #expect(messages[1].text == "I searched.")
    }

    @Test("An assistant turn with no prose is skipped entirely")
    func skipsEmptyAssistantTurns() {
        let call = AgentToolCall(id: "c1", name: "grep", hasCompleteInput: true)
        let message = AgentMessage(role: .assistant, blocks: [.toolCall(call)])
        let messages = OpenAIChatClient.seed(request(history: [message]))
        #expect(messages.map(\.role) == ["system", "user"])
    }

    @Test("Image attachments promote the turn to the parts form")
    func attachmentsBecomeParts() {
        let request = AgentSendRequest(
            threadID: AgentThreadID(),
            prompt: "what is this?",
            attachments: [AgentAttachment(kind: .image(Data([0x1, 0x2]), mimeType: "image/png"))],
            workingDirectory: URL(filePath: "/tmp")
        )
        let messages = OpenAIChatClient.seed(request)
        guard let parts = messages.last?.parts else {
            Issue.record("expected parts")
            return
        }
        #expect(parts.count == 2)
        if case .imageURL(let url) = parts[1] {
            #expect(url.hasPrefix("data:image/png;base64,"))
        } else {
            Issue.record("expected an image part")
        }
    }
}

@Suite("MCP result decoding")
struct MCPResultDecodingTests {

    @Test("Text blocks are joined")
    func joinsText() {
        let result = JSONValue.object([
            "content": .array([
                .object(["type": .string("text"), "text": .string("one")]),
                .object(["type": .string("text"), "text": .string("two")]),
            ]),
        ])
        #expect(AgentToolSurface.outcome(from: result).text == "one\ntwo")
    }

    @Test("Structured content wins over the rendered text")
    func prefersStructured() {
        let result = JSONValue.object([
            "content": .array([.object(["type": .string("text"), "text": .string("3 items")])]),
            "structuredContent": .object(["count": .number(3)]),
        ])
        #expect(AgentToolSurface.outcome(from: result).text == #"{"count":3}"#)
    }

    @Test("Image blocks become data URLs")
    func extractsImages() {
        let result = JSONValue.object([
            "content": .array([
                .object([
                    "type": .string("image"),
                    "data": .string("QUJD"),
                    "mimeType": .string("image/jpeg"),
                ]),
            ]),
        ])
        let outcome = AgentToolSurface.outcome(from: result)
        #expect(outcome.images == ["data:image/jpeg;base64,QUJD"])
    }

    @Test("isError is carried through, with a non-empty body")
    func carriesError() {
        let outcome = AgentToolSurface.outcome(from: .object(["isError": .bool(true)]))
        #expect(outcome.isError)
        #expect(outcome.text == #"{"ok":false}"#)
    }
}

@Suite("MCP transport decoding")
struct MCPTransportDecodingTests {

    @Test("A bare JSON body decodes")
    func plainJSON() {
        let message = MCPHTTPClient.decodeMessage(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#)
        #expect(message?["result"]?["ok"]?.boolValue == true)
    }

    @Test("An SSE body decodes from its last data line")
    func serverSentEvents() {
        let body = """
        : keep-alive

        event: message
        data: {"jsonrpc":"2.0","id":1,"result":{"ok":true}}

        """
        let message = MCPHTTPClient.decodeMessage(body)
        #expect(message?["result"]?["ok"]?.boolValue == true)
    }
}

@Suite("Turn tool scoping")
struct ToolScopingTests {

    private func request(
        allowed: [String]? = nil,
        disallowed: [String] = []
    ) -> AgentSendRequest {
        AgentSendRequest(
            threadID: AgentThreadID(),
            prompt: "x",
            workingDirectory: URL(filePath: "/tmp"),
            allowedTools: allowed,
            disallowedTools: disallowed
        )
    }

    @Test("No allowlist permits everything")
    func noAllowlist() {
        #expect(request().permitsTool(named: "anything"))
    }

    @Test("An allowlist admits only what it names")
    func allowlist() {
        let request = request(allowed: ["caption_export"])
        #expect(request.permitsTool(named: "caption_export"))
        #expect(!request.permitsTool(named: "Bash"))
    }

    @Test("The denylist outranks the allowlist")
    func denyWins() {
        let request = request(allowed: ["delete_project"], disallowed: ["delete_project"])
        #expect(!request.permitsTool(named: "delete_project"))
    }
}
