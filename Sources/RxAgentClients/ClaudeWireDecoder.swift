#if os(macOS)
import Foundation
import RxAgentCore

/// Decodes the Claude Code CLI's `--output-format stream-json` NDJSON into
/// ``AgentEvent``.
///
/// Top-level frames (`system`, `assistant`, `user`, `result`) are handled here;
/// the `stream_event` partial frames are delegated to ``PartialBlockAssembler``,
/// which owns the `input_json_delta` accumulation.
///
/// Pure and `nonisolated` so it can be tested against recorded NDJSON without
/// spawning anything.
struct ClaudeWireDecoder: Sendable {
    private var assembler = PartialBlockAssembler()
    private var capturedSessionID: String?
    /// Claude emits the full assistant message *again* as a non-partial frame
    /// after streaming it. Without this, every reply would render twice.
    private var isStreamingAssistant = false

    init() {}

    var sessionID: String? { capturedSessionID }

    /// How many user messages written to stdin the CLI has echoed back.
    private(set) var replayedUserMessages = 0

    mutating func decode(line: String) -> [AgentEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let frame = JSONValue(jsonString: trimmed) else { return [] }

        // Any frame can carry the session id; grab the first one we see.
        if capturedSessionID == nil,
           let sessionID = frame["session_id"]?.stringValue ?? frame["sessionId"]?.stringValue {
            capturedSessionID = sessionID
        }

        switch frame["type"]?.stringValue {
        case "system":
            return decodeSystem(frame)
        case "stream_event":
            isStreamingAssistant = true
            return assembler.consume(frame)
        case "assistant":
            return decodeAssistant(frame)
        case "user":
            return decodeUser(frame)
        case "result":
            return decodeResult(frame)
        default:
            return []
        }
    }

    mutating func finish() -> [AgentEvent] {
        assembler.flush()
    }

    // MARK: - system

    private mutating func decodeSystem(_ frame: JSONValue) -> [AgentEvent] {
        switch frame["subtype"]?.stringValue {
        case "init":
            guard let sessionID = capturedSessionID else { return [] }
            let tools = frame["tools"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return [.sessionStarted(SessionStarted(
                nativeSessionID: sessionID,
                model: frame["model"]?.stringValue,
                advertisedTools: tools
            ))]

        case "task_started", "task_updated", "task_completed", "task_failed":
            guard let taskID = frame["task_id"]?.stringValue else { return [] }
            let status: BackgroundTaskEvent.Status = switch frame["subtype"]?.stringValue {
            case "task_started": .started
            case "task_completed": .completed
            case "task_failed": .failed
            default: .updated
            }
            return [.backgroundTask(BackgroundTaskEvent(
                taskID: taskID,
                status: status,
                detail: frame["task_status"]?.stringValue
            ))]

        default:
            return []
        }
    }

    // MARK: - assistant

    /// The non-partial mirror of a streamed message. When partial frames are on
    /// (they always are here) the content has already been delivered, so only
    /// the usage totals and the message boundary are taken from it.
    private mutating func decodeAssistant(_ frame: JSONValue) -> [AgentEvent] {
        let message = frame["message"] ?? .object([:])
        let id = message["id"]?.stringValue
        let usage = decodeUsage(message["usage"])

        if isStreamingAssistant {
            isStreamingAssistant = false
            var events = assembler.flush()
            events.append(.messageEnded(id: id, usage: usage))
            if let usage { events.append(.usage(usage)) }
            return events
        }

        // No partial frames were seen — reconstruct from the complete message.
        var events: [AgentEvent] = [.messageStarted(role: .assistant, id: id)]
        for block in message["content"]?.arrayValue ?? [] {
            switch block["type"]?.stringValue {
            case "text":
                if let text = block["text"]?.stringValue, !text.isEmpty {
                    events.append(.blockStarted(.text))
                    events.append(.textDelta(text))
                    events.append(.blockEnded(.text))
                }
            case "thinking":
                if let text = block["thinking"]?.stringValue, !text.isEmpty {
                    events.append(.blockStarted(.thinking))
                    events.append(.thinkingDelta(text))
                    events.append(.blockEnded(.thinking))
                }
            case "tool_use":
                guard let toolID = block["id"]?.stringValue,
                      let name = block["name"]?.stringValue else { continue }
                events.append(.toolCallStarted(id: toolID, name: name))
                events.append(.toolCallInput(id: toolID, input: block["input"]?.objectValue ?? [:]))
            default:
                continue
            }
        }
        events.append(.messageEnded(id: id, usage: usage))
        if let usage { events.append(.usage(usage)) }
        return events
    }

    // MARK: - user (tool results)

    private mutating func decodeUser(_ frame: JSONValue) -> [AgentEvent] {
        // `--replay-user-messages` echoes each prompt back once the CLI has
        // taken it in. The transcript already has it; the count is what tells
        // the client whether a steer is still waiting to be read.
        if frame["isReplay"]?.boolValue == true {
            replayedUserMessages += 1
            return []
        }
        let content = frame["message"]?["content"]
        guard let blocks = content?.arrayValue else { return [] }

        var events: [AgentEvent] = []
        for block in blocks where block["type"]?.stringValue == "tool_result" {
            guard let toolUseID = block["tool_use_id"]?.stringValue else { continue }
            events.append(.toolCallResult(
                id: toolUseID,
                content: Self.flattenResultContent(block["content"]),
                isError: block["is_error"]?.boolValue ?? false
            ))
        }
        return events
    }

    /// A tool result's `content` is either a plain string or an array of typed
    /// blocks, depending on the tool.
    static func flattenResultContent(_ content: JSONValue?) -> String {
        guard let content else { return "" }
        if let text = content.stringValue { return text }
        guard let blocks = content.arrayValue else { return content.jsonString }
        return blocks.compactMap { block in
            block["text"]?.stringValue ?? block.stringValue
        }.joined(separator: "\n")
    }

    // MARK: - result

    private mutating func decodeResult(_ frame: JSONValue) -> [AgentEvent] {
        var events = assembler.flush()

        let usage = decodeUsage(frame["usage"])
        if let usage { events.append(.usage(usage)) }

        if let window = frame["context_window"],
           let used = window["used_tokens"]?.intValue ?? window["input_tokens"]?.intValue,
           let maximum = window["max_tokens"]?.intValue ?? window["context_window"]?.intValue {
            events.append(.contextWindow(ContextWindowInfo(usedTokens: used, maxTokens: maximum)))
        }

        // A `result` tagged as a task notification closes out a *background*
        // task; the foreground turn may still be streaming.
        let isBackground = frame["origin"]?["kind"]?.stringValue == "task-notification"

        var totalCost = usage
        if let cost = frame["total_cost_usd"]?.numberValue {
            totalCost = totalCost ?? UsageInfo()
            totalCost?.totalCostUSD = cost
        }

        events.append(.turnEnded(TurnResult(
            isError: frame["is_error"]?.boolValue ?? false,
            durationMS: frame["duration_ms"]?.intValue,
            usage: totalCost,
            nativeSessionID: capturedSessionID,
            isBackgroundFollowUp: isBackground
        )))
        return events
    }

    // MARK: - usage

    private func decodeUsage(_ value: JSONValue?) -> UsageInfo? {
        guard let value, !value.isNull else { return nil }
        return UsageInfo(
            inputTokens: value["input_tokens"]?.intValue ?? 0,
            outputTokens: value["output_tokens"]?.intValue ?? 0,
            cacheReadTokens: value["cache_read_input_tokens"]?.intValue ?? 0,
            cacheCreationTokens: value["cache_creation_input_tokens"]?.intValue ?? 0,
            totalCostUSD: value["total_cost_usd"]?.numberValue
        )
    }
}
#endif
