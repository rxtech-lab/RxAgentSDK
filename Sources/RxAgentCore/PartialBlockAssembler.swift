import Foundation

/// Turns Claude's `--include-partial-messages` `stream_event` frames into typed
/// ``AgentEvent`` values.
///
/// Claude streams a tool call's arguments as a sequence of `input_json_delta`
/// fragments that are only valid JSON once concatenated. This type owns that
/// accumulation so no consumer ever sees a half-parsed object: partial JSON is
/// buffered internally and surfaces exactly once, as ``AgentEvent/toolCallInput(id:input:)``,
/// at `content_block_stop`.
///
/// In RxCode this state lived in `AppState.handlePartialEvent`, mutating shared
/// `SessionStreamState`, which meant it could not be tested without standing up
/// the whole app. Here it's a `nonisolated` value type you can drive from a
/// literal array of frames.
public struct PartialBlockAssembler: Sendable {
    private var activeToolID: String?
    private var activeToolName: String?
    private var toolInputBuffer: String = ""
    private var activeBlock: BlockRef?

    public init() {}

    /// Feed one decoded frame. Returns zero or more events.
    ///
    /// Accepts either a bare event object or the `{"type":"stream_event","event":{…}}`
    /// envelope the CLI wraps them in.
    public mutating func consume(_ frame: JSONValue) -> [AgentEvent] {
        let event: JSONValue = {
            if frame["type"]?.stringValue == "stream_event", let nested = frame["event"] {
                return nested
            }
            return frame
        }()

        guard let eventType = event["type"]?.stringValue else { return [] }

        switch eventType {
        case "content_block_start":
            return handleBlockStart(event)
        case "content_block_delta":
            return handleBlockDelta(event)
        case "content_block_stop":
            return handleBlockStop()
        default:
            return []
        }
    }

    /// Convenience for NDJSON input.
    public mutating func consume(line: String) -> [AgentEvent] {
        guard let value = JSONValue(jsonString: line) else { return [] }
        return consume(value)
    }

    /// Close out any block left open by a cancel or an abrupt process exit.
    /// Emits a best-effort `toolCallInput` if the buffer happens to be valid JSON.
    public mutating func flush() -> [AgentEvent] {
        var events: [AgentEvent] = []
        if let toolID = activeToolID {
            events.append(.toolCallInput(id: toolID, input: parseBufferedInput()))
            events.append(.blockEnded(.toolUse(id: toolID, name: activeToolName ?? "")))
        } else if let block = activeBlock {
            events.append(.blockEnded(block))
        }
        activeToolID = nil
        activeToolName = nil
        toolInputBuffer = ""
        activeBlock = nil
        return events
    }

    // MARK: - Frame handlers

    private mutating func handleBlockStart(_ event: JSONValue) -> [AgentEvent] {
        guard let block = event["content_block"],
              let blockType = block["type"]?.stringValue
        else { return [] }

        switch blockType {
        case "tool_use":
            guard let id = block["id"]?.stringValue,
                  let name = block["name"]?.stringValue
            else { return [] }
            activeToolID = id
            activeToolName = name
            toolInputBuffer = ""
            let ref = BlockRef.toolUse(id: id, name: name)
            activeBlock = ref
            return [.blockStarted(ref), .toolCallStarted(id: id, name: name)]

        case "text":
            activeToolID = nil
            toolInputBuffer = ""
            activeBlock = .text
            return [.blockStarted(.text)]

        case "thinking":
            activeToolID = nil
            toolInputBuffer = ""
            activeBlock = .thinking
            return [.blockStarted(.thinking)]

        default:
            return []
        }
    }

    private mutating func handleBlockDelta(_ event: JSONValue) -> [AgentEvent] {
        guard let delta = event["delta"],
              let deltaType = delta["type"]?.stringValue
        else { return [] }

        switch deltaType {
        case "text_delta":
            guard let text = delta["text"]?.stringValue, !text.isEmpty else { return [] }
            return [.textDelta(text)]

        case "thinking_delta":
            // The CLI uses `thinking` here, but tolerate `text` too.
            let text = delta["thinking"]?.stringValue ?? delta["text"]?.stringValue ?? ""
            guard !text.isEmpty else { return [] }
            return [.thinkingDelta(text)]

        case "input_json_delta":
            // Accumulate silently. The complete object surfaces at block stop.
            if let partial = delta["partial_json"]?.stringValue {
                toolInputBuffer += partial
            }
            return []

        default:
            return []
        }
    }

    private mutating func handleBlockStop() -> [AgentEvent] {
        defer {
            activeToolID = nil
            activeToolName = nil
            toolInputBuffer = ""
            activeBlock = nil
        }

        if let toolID = activeToolID {
            let name = activeToolName ?? ""
            return [
                .toolCallInput(id: toolID, input: parseBufferedInput()),
                .blockEnded(.toolUse(id: toolID, name: name)),
            ]
        }
        if let block = activeBlock {
            return [.blockEnded(block)]
        }
        return []
    }

    /// An empty buffer means a zero-argument tool, which is legitimate — return
    /// `[:]` rather than nothing so the call is still marked complete. RxCode
    /// bailed here, leaving such calls permanently "pending" in the UI.
    private func parseBufferedInput() -> [String: JSONValue] {
        let trimmed = toolInputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        guard let value = JSONValue(jsonString: trimmed), let object = value.objectValue else {
            return [:]
        }
        return object
    }
}
