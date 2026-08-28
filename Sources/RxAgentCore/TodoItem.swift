import Foundation

public struct TodoItem: Identifiable, Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Codable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public let id: Int
    public let content: String
    public let activeForm: String
    public let status: Status

    public init(id: Int, content: String, activeForm: String, status: Status) {
        self.id = id
        self.content = content
        self.activeForm = activeForm
        self.status = status
    }
}

// MARK: - Extraction

public enum TodoExtractor {
    /// Parse a raw `TodoWrite` tool input into typed items.
    public static func parse(todoWriteInput input: [String: JSONValue]) -> [TodoItem] {
        guard let array = input["todos"]?.arrayValue else { return [] }
        return array.enumerated().map { index, value in
            let content = value["content"]?.stringValue ?? ""
            let activeForm = value["activeForm"]?.stringValue ?? content
            let rawStatus = value["status"]?.stringValue ?? ""
            return TodoItem(
                id: index,
                content: content,
                activeForm: activeForm,
                status: TodoItem.Status(rawValue: rawStatus) ?? .pending
            )
        }
    }

    /// Parse Codex app-server `turn/plan/updated` params into the same shape.
    public static func parse(codexPlanUpdate params: [String: JSONValue]) -> [TodoItem]? {
        guard let array = params["plan"]?.arrayValue else { return nil }
        return array.enumerated().map { index, value in
            let step = value["step"]?.stringValue ?? ""
            return TodoItem(
                id: index,
                content: step,
                activeForm: step,
                status: codexStatus(value["status"]?.stringValue ?? "")
            )
        }
    }

    /// Parse an ACP `session/update` `plan` payload.
    public static func parse(acpPlan params: [String: JSONValue]) -> [TodoItem]? {
        guard let array = params["entries"]?.arrayValue ?? params["plan"]?.arrayValue else {
            return nil
        }
        return array.enumerated().map { index, value in
            let content = value["content"]?.stringValue ?? value["step"]?.stringValue ?? ""
            return TodoItem(
                id: index,
                content: content,
                activeForm: content,
                status: codexStatus(value["status"]?.stringValue ?? "")
            )
        }
    }

    private static func codexStatus(_ raw: String) -> TodoItem.Status {
        switch raw {
        case "completed": .completed
        case "inProgress", "in_progress": .inProgress
        default: .pending
        }
    }
}
