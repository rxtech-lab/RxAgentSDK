#if DEBUG
import RxAgentContext
import RxAgentCore
import SwiftUI

// MARK: - Harness

/// Drives an ``Agent`` backed by ``PreviewAgentClient``, so every chat surface
/// can be previewed with no CLI installed and no tokens spent.
struct AgentChatPreviewHarness: View {
    let agent: Agent
    var autoSend: String?

    init(script: AgentEventScript = .simpleAnswer, autoSend: String? = "Show me how it works") {
        self.agent = Agent(
            clients: [PreviewAgentClient(script: script)],
            workingDirectory: URL(filePath: NSTemporaryDirectory())
        )
        self.autoSend = autoSend
    }

    init(agent: Agent, autoSend: String? = nil) {
        self.agent = agent
        self.autoSend = autoSend
    }

    var body: some View {
        Color.clear
            .overlay { AgentChatView(agent: agent) }
            .task {
                guard let autoSend else { return }
                try? await Task.sleep(for: .milliseconds(400))
                agent.send(autoSend)
            }
    }
}

private func previewAgent(scripts: [(AgentClientID, String, AgentEventScript)]) -> Agent {
    Agent(
        clients: scripts.map { id, name, script in
            PreviewAgentClient(id: id, displayName: name, script: script)
        },
        workingDirectory: URL(filePath: NSTemporaryDirectory())
    )
}

// MARK: - Chat previews

#Preview("Chat / Simple answer") {
    AgentChatPreviewHarness(script: .simpleAnswer)
}

#Preview("Chat / Thinking") {
    AgentChatPreviewHarness(script: .thinking, autoSend: "Why is the spacer needed?")
}

#Preview("Chat / Tool use") {
    AgentChatPreviewHarness(script: .toolUse, autoSend: "Clean up the greeting")
}

#Preview("Chat / Streaming markdown") {
    AgentChatPreviewHarness(script: .longMarkdown, autoSend: "Explain the dynamic spacing")
}

#Preview("Chat / Todos") {
    AgentChatPreviewHarness(script: .todos, autoSend: "Plan the port")
}

#Preview("Chat / Failure") {
    AgentChatPreviewHarness(script: .failure, autoSend: "Go")
}

/// Three clients so the picker, selection, and handoff summary are all live.
#Preview("Chat / Client switcher") {
    AgentChatPreviewHarness(
        agent: previewAgent(scripts: [
            ("claude-code", "Claude Code", .toolUse),
            ("codex", "Codex", .simpleAnswer),
            ("acp:gemini", "Gemini (ACP)", .thinking),
        ]),
        autoSend: "Who is answering?"
    )
}

#Preview("Chat / Compact + dark") {
    AgentChatPreviewHarness(script: .toolUse, autoSend: "Show a tool call")
        .agentTheme(.compact)
        .preferredColorScheme(.dark)
}

/// A tight viewport makes the reserved tail spacer obvious: the prompt pins to
/// the top and the answer grows into the space below it.
#Preview("Chat / Pinned turn (small viewport)") {
    AgentChatPreviewHarness(script: .longMarkdown, autoSend: "Explain the spacing")
}

// MARK: - Component previews

private func sampleCall(
    _ name: String,
    input: [String: JSONValue],
    result: String? = nil,
    isError: Bool = false
) -> AgentToolCall {
    AgentToolCall(
        id: UUID().uuidString,
        name: name,
        input: input,
        result: result,
        isError: isError,
        hasCompleteInput: true
    )
}

#Preview("ToolCallRow / All kinds") {
    ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            AgentToolCallRow(call: sampleCall(
                "Bash",
                input: ["command": .string("git status --short")],
                result: " M Sources/App/main.swift\n?? Notes.md"
            ))
            AgentToolCallRow(call: sampleCall(
                "Edit",
                input: [
                    "file_path": .string("/tmp/demo/main.swift"),
                    "old_string": .string("print(\"hi\")"),
                    "new_string": .string("print(\"hello, world\")"),
                ],
                result: "Applied 1 edit."
            ))
            AgentToolCallRow(call: sampleCall(
                "Write",
                input: [
                    "file_path": .string("/tmp/demo/New.swift"),
                    "content": .string("import Foundation\n\nlet answer = 42"),
                ],
                result: "Created."
            ))
            AgentToolCallRow(call: sampleCall(
                "Read",
                input: ["file_path": .string("/tmp/demo/README.md")],
                result: "# Demo\n\nA sample project."
            ))
            AgentToolCallRow(call: sampleCall(
                "TodoWrite",
                input: ["todos": .array([
                    .object([
                        "content": .string("Port the list"),
                        "activeForm": .string("Porting the list"),
                        "status": .string("completed"),
                    ]),
                    .object([
                        "content": .string("Wire the view"),
                        "activeForm": .string("Wiring the view"),
                        "status": .string("in_progress"),
                    ]),
                ])],
                result: "ok"
            ))
            AgentToolCallRow(call: sampleCall(
                "mcp__rxagent-tools__lucky_number",
                input: ["person": .string("Ada")],
                result: "Ada's lucky number is 4173."
            ))
            AgentToolCallRow(call: sampleCall(
                "Bash",
                input: ["command": .string("swift test")],
                result: "error: 1 test failed",
                isError: true
            ))
            // Still streaming its arguments.
            AgentToolCallRow(call: AgentToolCall(id: "pending", name: "Grep"))
        }
        .padding()
    }
}

#Preview("ToolCallRow / Dark") {
    ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            AgentToolCallRow(call: sampleCall(
                "Bash",
                input: ["command": .string("swift build")],
                result: "Build complete!"
            ))
            AgentToolCallRow(call: sampleCall(
                "MultiEdit",
                input: [
                    "file_path": .string("/tmp/demo/App.swift"),
                    "edits": .array([
                        .object([
                            "old_string": .string("let a = 1"),
                            "new_string": .string("let a = 2"),
                        ]),
                        .object([
                            "old_string": .string("let b = 3"),
                            "new_string": .string("let b = 4"),
                        ]),
                    ]),
                ],
                result: "Applied 2 edits."
            ))
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Permission sheet / Bash") {
    AgentPermissionSheet(
        request: PermissionRequest(
            id: "1",
            toolName: "Bash",
            toolInput: ["command": .string("rm -rf build/ && npm ci")],
            mode: .default
        )
    ) { _ in }
}

#Preview("Permission sheet / File edit") {
    AgentPermissionSheet(
        request: PermissionRequest(
            id: "2",
            toolName: "Write",
            toolInput: [
                "file_path": .string("/etc/hosts"),
                "content": .string("127.0.0.1 example.com"),
            ],
            mode: .acceptEdits
        )
    ) { _ in }
}

#Preview("Permission sheet / MCP tool") {
    AgentPermissionSheet(
        request: PermissionRequest(
            id: "3",
            toolName: "mcp__github__create_pull_request",
            toolInput: ["title": .string("Fix the spacer ratchet"), "base": .string("main")],
            mode: .default
        )
    ) { _ in }
}

#Preview("Composer") {
    @Previewable @State var text = "Explain the ratcheted turn height"
    return VStack(spacing: 0) {
        Divider()
        AgentComposer(
            text: $text,
            attachments: [.file(URL(filePath: "/tmp/demo/main.swift"))],
            isStreaming: false,
            onSend: {},
            onStop: {},
            onRemoveAttachment: { _ in }
        )
    }
}

#Preview("Composer / Streaming") {
    @Previewable @State var text = ""
    return AgentComposer(text: $text, isStreaming: true, onSend: {}, onStop: {})
}
#endif
