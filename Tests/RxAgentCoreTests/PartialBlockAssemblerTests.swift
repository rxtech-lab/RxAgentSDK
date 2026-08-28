import Testing
@testable import RxAgentCore

/// Real Claude `--include-partial-messages` frame shapes.
private enum Frames {
    static let textStart = #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#
    static func textDelta(_ text: String) -> String {
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}}"#
    }

    static let thinkingStart = #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}}"#
    static func thinkingDelta(_ text: String) -> String {
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"\#(text)"}}}"#
    }

    static func toolStart(id: String, name: String) -> String {
        #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{}}}}"#
    }

    static func inputDelta(_ partial: String) -> String {
        let escaped = partial
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\#(escaped)"}}}"#
    }

    static let blockStop = #"{"type":"stream_event","event":{"type":"content_block_stop","index":1}}"#
}

@Suite("PartialBlockAssembler")
struct PartialBlockAssemblerTests {

    @Test("Text deltas pass through in order")
    func textDeltas() {
        var assembler = PartialBlockAssembler()
        var events: [AgentEvent] = []
        events += assembler.consume(line: Frames.textStart)
        events += assembler.consume(line: Frames.textDelta("Hello"))
        events += assembler.consume(line: Frames.textDelta(", world"))
        events += assembler.consume(line: Frames.blockStop)

        let text = events.compactMap { if case .textDelta(let t) = $0 { return t } else { return nil } }
        #expect(text == ["Hello", ", world"])
        #expect(events.contains { if case .blockStarted(.text) = $0 { true } else { false } })
        #expect(events.contains { if case .blockEnded(.text) = $0 { true } else { false } })
    }

    @Test("Thinking deltas are read from the `thinking` key")
    func thinkingDeltas() {
        var assembler = PartialBlockAssembler()
        var events: [AgentEvent] = []
        events += assembler.consume(line: Frames.thinkingStart)
        events += assembler.consume(line: Frames.thinkingDelta("weighing options"))
        events += assembler.consume(line: Frames.blockStop)

        let thinking = events.compactMap {
            if case .thinkingDelta(let t) = $0 { return t } else { return nil }
        }
        #expect(thinking == ["weighing options"])
    }

    /// The core guarantee: fragmented argument JSON never escapes as partials.
    @Test("Fragmented tool input surfaces exactly once, fully parsed")
    func toolInputAccumulation() {
        var assembler = PartialBlockAssembler()
        var events: [AgentEvent] = []
        events += assembler.consume(line: Frames.toolStart(id: "toolu_1", name: "Bash"))
        events += assembler.consume(line: Frames.inputDelta(#"{"comm"#))
        events += assembler.consume(line: Frames.inputDelta(#"and":"git st"#))
        events += assembler.consume(line: Frames.inputDelta(#"atus"}"#))
        events += assembler.consume(line: Frames.blockStop)

        let starts = events.compactMap {
            if case .toolCallStarted(let id, let name) = $0 { return (id, name) } else { return nil }
        }
        #expect(starts.count == 1)
        #expect(starts.first?.0 == "toolu_1")
        #expect(starts.first?.1 == "Bash")

        let inputs = events.compactMap {
            if case .toolCallInput(let id, let input) = $0 { return (id, input) } else { return nil }
        }
        #expect(inputs.count == 1, "input must surface exactly once")
        #expect(inputs.first?.1["command"]?.stringValue == "git status")
    }

    /// RxCode bailed on an empty buffer, leaving zero-argument calls stuck
    /// rendering as "pending" forever.
    @Test("A zero-argument tool still reports complete input")
    func zeroArgumentTool() {
        var assembler = PartialBlockAssembler()
        var events: [AgentEvent] = []
        events += assembler.consume(line: Frames.toolStart(id: "toolu_2", name: "TodoRead"))
        events += assembler.consume(line: Frames.blockStop)

        let inputs = events.compactMap {
            if case .toolCallInput(let id, let input) = $0 { return (id, input) } else { return nil }
        }
        #expect(inputs.count == 1)
        #expect(inputs.first?.1.isEmpty == true)
    }

    @Test("flush closes a tool block left open by a cancel")
    func flushClosesOpenToolBlock() {
        var assembler = PartialBlockAssembler()
        _ = assembler.consume(line: Frames.toolStart(id: "toolu_3", name: "Edit"))
        _ = assembler.consume(line: Frames.inputDelta(#"{"file_path":"/tmp/a.swift"}"#))

        let flushed = assembler.flush()
        let inputs = flushed.compactMap {
            if case .toolCallInput(let id, let input) = $0 { return (id, input) } else { return nil }
        }
        #expect(inputs.first?.1["file_path"]?.stringValue == "/tmp/a.swift")
        #expect(flushed.contains { if case .blockEnded = $0 { true } else { false } })

        // A second flush must be a no-op, not a duplicate emission.
        #expect(assembler.flush().isEmpty)
    }

    @Test("Malformed argument JSON degrades to empty input rather than crashing")
    func malformedInput() {
        var assembler = PartialBlockAssembler()
        _ = assembler.consume(line: Frames.toolStart(id: "toolu_4", name: "Bash"))
        _ = assembler.consume(line: Frames.inputDelta(#"{"command":"#))
        let events = assembler.consume(line: Frames.blockStop)

        let inputs = events.compactMap {
            if case .toolCallInput(_, let input) = $0 { return input } else { return nil }
        }
        #expect(inputs.count == 1)
        #expect(inputs.first?.isEmpty == true)
    }

    @Test("Unwrapped frames (no stream_event envelope) are accepted")
    func bareFrames() {
        var assembler = PartialBlockAssembler()
        let bare = #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}"#
        let events = assembler.consume(line: bare)
        #expect(events.count == 1)
        if case .textDelta(let text) = events[0] {
            #expect(text == "hi")
        } else {
            Issue.record("expected a textDelta")
        }
    }

    @Test("Unrelated frames are ignored")
    func ignoresUnknownFrames() {
        var assembler = PartialBlockAssembler()
        #expect(assembler.consume(line: #"{"type":"message_start"}"#).isEmpty)
        #expect(assembler.consume(line: "not json at all").isEmpty)
    }
}
