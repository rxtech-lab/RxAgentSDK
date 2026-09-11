#if os(macOS)
import Foundation
import RxAgentCore

/// Maps ACP's generic tool-call vocabulary onto the Claude tool names the SDK's
/// renderers and permission rules already understand.
///
/// This is *semantic* normalization — it renames a concept, it doesn't fake a
/// wire format. ACP reports a file edit as a `diff` content entry with old and
/// new text; turning that into `Edit`/`Write`/`MultiEdit` with `file_path` /
/// `old_string` / `new_string` is what lets one diff renderer serve all three
/// providers.
public enum ACPToolNormalizer {

    public struct NormalizedToolCall: Sendable, Equatable {
        public let name: String
        public let input: [String: JSONValue]
    }

    public struct DiffEntry: Sendable, Equatable {
        public let path: String
        public let oldText: String?
        public let newText: String
    }

    /// Extra mappings from an ACP `kind` to a tool name, applied before the
    /// built-in rules.
    public static func normalize(
        kind: String?,
        title: String,
        update: [String: JSONValue],
        rawInput: [String: JSONValue],
        customMapping: [String: String] = [:]
    ) -> NormalizedToolCall {
        let normalizedKind = (kind ?? "").lowercased()

        if let mapped = customMapping[normalizedKind] {
            return NormalizedToolCall(name: mapped, input: rawInput)
        }

        let diffs = diffEntries(in: update)
        if !diffs.isEmpty {
            return fromDiffs(diffs)
        }

        switch normalizedKind {
        case "edit":
            return NormalizedToolCall(name: "Edit", input: rawInput)
        case "read":
            return NormalizedToolCall(name: "Read", input: rawInput)
        case "execute":
            var input = rawInput
            if input["command"] == nil { input["command"] = .string(title) }
            return NormalizedToolCall(name: "Bash", input: input)
        case "search":
            return NormalizedToolCall(name: "Grep", input: rawInput)
        case "think":
            return NormalizedToolCall(name: "Think", input: rawInput)
        case "fetch":
            return NormalizedToolCall(name: "WebFetch", input: rawInput)
        default:
            // An MCP-provided tool keeps its own name.
            let name = update["title"]?.stringValue ?? title
            return NormalizedToolCall(name: name.isEmpty ? "Tool" : name, input: rawInput)
        }
    }

    private static func fromDiffs(_ diffs: [DiffEntry]) -> NormalizedToolCall {
        if diffs.count == 1 {
            let only = diffs[0]
            let oldText = only.oldText ?? ""
            // No prior content means the file is being created.
            if oldText.isEmpty {
                return NormalizedToolCall(name: "Write", input: [
                    "file_path": .string(only.path),
                    "content": .string(only.newText),
                ])
            }
            return NormalizedToolCall(name: "Edit", input: [
                "file_path": .string(only.path),
                "old_string": .string(oldText),
                "new_string": .string(only.newText),
            ])
        }

        let primaryPath = diffs[0].path
        let edits: [JSONValue] = diffs.filter { $0.path == primaryPath }.map { diff in
            .object([
                "old_string": .string(diff.oldText ?? ""),
                "new_string": .string(diff.newText),
            ])
        }
        return NormalizedToolCall(name: "MultiEdit", input: [
            "file_path": .string(primaryPath),
            "edits": .array(edits),
        ])
    }

    /// Pull `{type: "diff", path, oldText, newText}` entries out of a
    /// `tool_call` or `tool_call_update` payload.
    public static func diffEntries(in update: [String: JSONValue]) -> [DiffEntry] {
        let containers = [update["content"], update["rawOutput"], update["output"]]
        for container in containers {
            guard let entries = container?.arrayValue else { continue }
            let diffs = entries.compactMap { entry -> DiffEntry? in
                // The diff can be the entry itself or nested under `content`.
                let candidate = entry["type"]?.stringValue == "diff" ? entry : (entry["content"] ?? .null)
                guard candidate["type"]?.stringValue == "diff",
                      let path = candidate["path"]?.stringValue,
                      let newText = candidate["newText"]?.stringValue
                else { return nil }
                return DiffEntry(
                    path: path,
                    oldText: candidate["oldText"]?.stringValue,
                    newText: newText
                )
            }
            if !diffs.isEmpty { return diffs }
        }
        return []
    }

    /// Flatten ACP content blocks into display text.
    public static func text(from content: JSONValue?) -> String {
        guard let content else { return "" }
        if let text = content.stringValue { return text }
        if let entries = content.arrayValue {
            return entries.compactMap { entry -> String? in
                if let text = entry["text"]?.stringValue { return text }
                if let nested = entry["content"]?["text"]?.stringValue { return nested }
                return nil
            }.joined(separator: "\n")
        }
        if let text = content["text"]?.stringValue { return text }
        return ""
    }
}
#endif
