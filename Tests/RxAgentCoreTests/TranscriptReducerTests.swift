import Foundation
import Testing
@testable import RxAgentCore

@Suite("TranscriptReducer")
struct TranscriptReducerTests {

    private func reduce(_ events: [AgentEvent]) -> TranscriptReducer {
        var reducer = TranscriptReducer()
        for event in events { _ = reducer.apply(event) }
        return reducer
    }

    @Test("Successive text deltas coalesce into one block")
    func textCoalesces() {
        let reducer = reduce([
            .messageStarted(role: .assistant, id: "m1"),
            .blockStarted(.text),
            .textDelta("Hello"),
            .textDelta(", "),
            .textDelta("world"),
            .blockEnded(.text),
            .messageEnded(id: "m1", usage: nil),
        ])

        #expect(reducer.messages.count == 1)
        #expect(reducer.messages[0].blocks.count == 1)
        #expect(reducer.messages[0].plainText == "Hello, world")
        #expect(reducer.messages[0].isStreaming == false)
    }

    @Test("Text after a tool call starts a new block, not an append")
    func textAfterToolStartsNewBlock() {
        let reducer = reduce([
            .messageStarted(role: .assistant, id: "m1"),
            .blockStarted(.text),
            .textDelta("Checking."),
            .blockEnded(.text),
            .toolCallStarted(id: "t1", name: "Bash"),
            .toolCallInput(id: "t1", input: ["command": .string("ls")]),
            .toolCallResult(id: "t1", content: "a.swift", isError: false),
            .blockStarted(.text),
            .textDelta("Found one file."),
            .blockEnded(.text),
            .messageEnded(id: "m1", usage: nil),
        ])

        let blocks = reducer.messages[0].blocks
        #expect(blocks.count == 3)
        #expect(blocks[0].text == "Checking.")
        #expect(blocks[1].toolCall?.name == "Bash")
        #expect(blocks[2].text == "Found one file.")
    }

    @Test("A tool call accumulates input then result")
    func toolCallLifecycle() {
        let reducer = reduce([
            .messageStarted(role: .assistant, id: "m1"),
            .toolCallStarted(id: "t1", name: "Edit"),
            .toolCallInput(id: "t1", input: ["file_path": .string("/tmp/a.swift")]),
            .toolCallResult(id: "t1", content: "ok", isError: false),
            .messageEnded(id: "m1", usage: nil),
        ])

        let call = try! #require(reducer.messages[0].toolCalls.first)
        #expect(call.name == "Edit")
        #expect(call.input["file_path"]?.stringValue == "/tmp/a.swift")
        #expect(call.hasCompleteInput)
        #expect(call.result == "ok")
        #expect(call.isComplete)
        #expect(!call.isError)
    }

    /// Claude delivers tool results in a separate `user` frame that can land
    /// after the owning assistant message has already closed.
    @Test("A result arriving after the message closed still attaches")
    func lateToolResult() {
        let reducer = reduce([
            .messageStarted(role: .assistant, id: "m1"),
            .toolCallStarted(id: "t1", name: "Bash"),
            .toolCallInput(id: "t1", input: ["command": .string("ls")]),
            .messageEnded(id: "m1", usage: nil),
            .toolCallResult(id: "t1", content: "a.swift", isError: false),
        ])

        #expect(reducer.messages[0].toolCalls.first?.result == "a.swift")
    }

    @Test("A second assistant message opens after the first closes")
    func multipleAssistantMessages() {
        let reducer = reduce([
            .messageStarted(role: .assistant, id: "m1"),
            .textDelta("First."),
            .messageEnded(id: "m1", usage: nil),
            .messageStarted(role: .assistant, id: "m2"),
            .textDelta("Second."),
            .messageEnded(id: "m2", usage: nil),
        ])

        #expect(reducer.messages.count == 2)
        #expect(reducer.messages[0].plainText == "First.")
        #expect(reducer.messages[1].plainText == "Second.")
    }

    /// Not every client emits `messageStarted` before its first delta.
    @Test("A bare delta self-heals into a new assistant message")
    func deltaWithoutMessageStart() {
        let reducer = reduce([.textDelta("Surprise.")])
        #expect(reducer.messages.count == 1)
        #expect(reducer.messages[0].role == .assistant)
        #expect(reducer.messages[0].plainText == "Surprise.")
        #expect(reducer.messages[0].isStreaming)
    }

    @Test("turnEnded closes the streaming message")
    func turnEndClosesMessage() {
        let reducer = reduce([
            .messageStarted(role: .assistant, id: "m1"),
            .textDelta("Done."),
            .turnEnded(TurnResult(durationMS: 100, nativeSessionID: "sess-1")),
        ])

        #expect(reducer.messages[0].isStreaming == false)
        #expect(reducer.nativeSessionID == "sess-1")
    }

    /// A background-task result must not tear down the live foreground turn.
    @Test("A background follow-up result leaves the turn streaming")
    func backgroundFollowUpDoesNotCloseTurn() {
        let reducer = reduce([
            .messageStarted(role: .assistant, id: "m1"),
            .textDelta("Working…"),
            .turnEnded(TurnResult(isBackgroundFollowUp: true)),
        ])

        #expect(reducer.messages[0].isStreaming, "foreground turn should still be live")
    }

    @Test("failed records the error on the assistant message")
    func failureAttachesError() {
        let reducer = reduce([
            .messageStarted(role: .assistant, id: "m1"),
            .textDelta("Starting…"),
            .failed(.processExited(code: 1, stderr: "boom")),
        ])

        #expect(reducer.messages.count == 1)
        #expect(reducer.messages[0].error?.contains("exited with code 1") == true)
        #expect(reducer.messages[0].isStreaming == false)
    }

    @Test("failed with no active message still surfaces an error bubble")
    func failureWithNoMessage() {
        let reducer = reduce([.failed(.binaryNotFound(name: "claude"))])
        #expect(reducer.messages.count == 1)
        #expect(reducer.messages[0].error?.contains("claude") == true)
    }

    @Test("A TodoWrite result populates the todo list")
    func todoWriteDerivesTodos() {
        let reducer = reduce([
            .messageStarted(role: .assistant, id: "m1"),
            .toolCallStarted(id: "t1", name: "TodoWrite"),
            .toolCallInput(id: "t1", input: [
                "todos": .array([
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
                ]),
            ]),
            .toolCallResult(id: "t1", content: "ok", isError: false),
        ])

        #expect(reducer.todos.count == 2)
        #expect(reducer.todos[0].status == .completed)
        #expect(reducer.todos[1].status == .inProgress)
        #expect(reducer.todos[1].activeForm == "Wiring the view")
    }

    @Test("Background tasks are tracked so the watchdog can stand down")
    func backgroundTaskTracking() {
        var reducer = TranscriptReducer()
        _ = reducer.apply(.backgroundTask(BackgroundTaskEvent(taskID: "bg1", status: .started)))
        #expect(reducer.liveBackgroundTaskIDs == ["bg1"])
        _ = reducer.apply(.backgroundTask(BackgroundTaskEvent(taskID: "bg1", status: .completed)))
        #expect(reducer.liveBackgroundTaskIDs.isEmpty)
    }

    @Test("Usage replaces rather than accumulates, but keeps a known cost")
    func usageMerge() {
        let reducer = reduce([
            .usage(UsageInfo(inputTokens: 100, outputTokens: 10, totalCostUSD: 0.02)),
            .usage(UsageInfo(inputTokens: 100, outputTokens: 40)),
        ])

        // Providers report cumulative turn totals, so 40 replaces 10.
        #expect(reducer.usage?.outputTokens == 40)
        #expect(reducer.usage?.totalCostUSD == 0.02)
    }

    @Test("Changes report the affected index")
    func changeReporting() {
        var reducer = TranscriptReducer()
        let opened = reducer.apply(.messageStarted(role: .assistant, id: "m1"))
        #expect(opened == [.appended(messageIndex: 0)])

        let delta = reducer.apply(.textDelta("hi"))
        #expect(delta == [.updated(messageIndex: 0)])
    }

    @Test("reset clears everything")
    func resetClears() {
        var reducer = TranscriptReducer()
        _ = reducer.apply(.messageStarted(role: .assistant, id: "m1"))
        _ = reducer.apply(.textDelta("hi"))
        _ = reducer.apply(.todos([TodoItem(id: 0, content: "x", activeForm: "x", status: .pending)]))

        let changes = reducer.reset()
        #expect(changes == [.cleared])
        #expect(reducer.messages.isEmpty)
        #expect(reducer.todos.isEmpty)
        #expect(reducer.nativeSessionID == nil)
    }
}

// MARK: - End-to-end: raw Claude frames through both stages

@Suite("Assembler + reducer")
struct StreamingPipelineTests {

    /// The whole point of the redesign: raw wire frames in, transcript out,
    /// with no app state and no fake-frame synthesis in between.
    @Test("Raw Claude frames produce a correct transcript")
    func endToEnd() {
        let lines = [
            #"{"type":"content_block_start","content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Let me check."}}"#,
            #"{"type":"content_block_stop"}"#,
            #"{"type":"content_block_start","content_block":{"type":"tool_use","id":"t1","name":"Bash"}}"#,
            #"{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{\"comm"}}"#,
            #"{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"and\":\"ls\"}"}}"#,
            #"{"type":"content_block_stop"}"#,
        ]

        var assembler = PartialBlockAssembler()
        var reducer = TranscriptReducer()
        _ = reducer.apply(.messageStarted(role: .assistant, id: "m1"))

        for line in lines {
            for event in assembler.consume(line: line) {
                _ = reducer.apply(event)
            }
        }
        _ = reducer.apply(.toolCallResult(id: "t1", content: "a.swift", isError: false))
        _ = reducer.apply(.turnEnded(TurnResult()))

        #expect(reducer.messages.count == 1)
        let blocks = reducer.messages[0].blocks
        #expect(blocks.count == 2)
        #expect(blocks[0].text == "Let me check.")

        let call = try! #require(blocks[1].toolCall)
        #expect(call.name == "Bash")
        #expect(call.input["command"]?.stringValue == "ls")
        #expect(call.result == "a.swift")
        #expect(reducer.messages[0].isStreaming == false)
    }
}
