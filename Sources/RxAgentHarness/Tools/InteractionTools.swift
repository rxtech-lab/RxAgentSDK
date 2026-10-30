import Foundation
import RxAgentCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - todowrite

public struct TodoWriteTool: HarnessTool {
    public init() {}
    public let name = "todowrite"

    public var description: String {
        """
        Create and update a todo list for the current session. The user sees it as your working plan.

        Use it proactively when a task has 3 or more distinct steps, or when the user gives several tasks or asks for a todo list. Skip it for a single simple task or a purely conversational request. When in doubt, use it.

        - Send the full list on every call; it replaces the previous one.
        - Mark items `in_progress` when you start them and `completed` as soon as they're actually done.
        - Only call it when the list changes.
        """
    }

    public var parameters: JSONValue {
        Schema.object([
            "todos": Schema.array(
                Schema.object([
                    "content": Schema.string("Brief description of the task"),
                    "status": Schema.string(
                        "Current status of the task: pending, in_progress, completed, cancelled",
                        enum: ["pending", "in_progress", "completed", "cancelled"]
                    ),
                ], required: ["content", "status"]),
                description: "The updated todo list"
            ),
        ], required: ["todos"])
    }

    public func execute(_ input: JSONValue, context: HarnessToolContext) async throws -> HarnessToolOutput {
        guard let raw = input["todos"]?.arrayValue else { throw HarnessToolError("`todos` must be an array.") }
        let todos = Self.parse(raw)
        await context.emit(.todos(todos))
        let open = todos.filter { $0.status != .completed }.count
        return HarnessToolOutput(
            text: "Todo list updated (\(todos.count) items, \(open) open).",
            title: "\(todos.count - open)/\(todos.count) done"
        )
    }

    /// Cancelled items are dropped: `TodoItem` has no such state, and showing a
    /// cancelled task as pending would be wrong.
    static func parse(_ raw: [JSONValue]) -> [TodoItem] {
        raw.enumerated().compactMap { index, item -> TodoItem? in
            guard let content = item["content"]?.stringValue else { return nil }
            let status: TodoItem.Status
            switch item["status"]?.stringValue {
            case "in_progress": status = .inProgress
            case "completed": status = .completed
            case "cancelled": return nil
            default: status = .pending
            }
            return TodoItem(id: index, content: content, activeForm: content, status: status)
        }
    }
}

// MARK: - webfetch

public struct WebFetchTool: HarnessTool {
    public static let maxBytes = 5 * 1024 * 1024
    public static let maxCharacters = 100_000

    public init() {}
    public let name = "webfetch"
    public var isReadOnly: Bool { true }

    public var description: String {
        """
        Fetch content from an HTTP or HTTPS URL and return it as text, markdown, or HTML. Markdown is the default.
        - The URL must be fully formed. HTTP URLs are upgraded to HTTPS.
        - This tool is read-only and does not modify any files.
        - Results may be summarized if the content is very large.
        """
    }

    public var parameters: JSONValue {
        Schema.object([
            "url": Schema.string("The HTTP or HTTPS URL to fetch content from"),
            "format": Schema.string("The format to return the content in. Defaults to markdown.", enum: ["text", "markdown", "html"]),
            "timeout": Schema.number("Optional timeout in seconds (maximum: 120)"),
        ], required: ["url"])
    }

    public func execute(_ input: JSONValue, context: HarnessToolContext) async throws -> HarnessToolOutput {
        guard var raw = input["url"]?.stringValue else { throw HarnessToolError("`url` is required.") }
        if raw.hasPrefix("http://") { raw = "https://" + raw.dropFirst(7) }
        guard let url = URL(string: raw), url.scheme == "https", url.host != nil else {
            throw HarnessToolError("Invalid URL: \(raw)")
        }
        try await context.authorize(
            HarnessPermissionKey.webfetch, resources: [url.absoluteString],
            always: ["\(url.scheme ?? "https")://\(url.host ?? "")/*"],
            toolName: name, input: input, title: "Fetch \(url.absoluteString)"
        )
        let timeout = min(120, max(1, input["timeout"]?.numberValue ?? 30))
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Mozilla/5.0 (Macintosh) RxAgentHarness", forHTTPHeaderField: "User-Agent")
        request.setValue("text/markdown;q=1.0, text/html;q=0.9, text/plain;q=0.8, */*;q=0.1", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw HarnessToolError("Request failed with HTTP \(http.statusCode).")
        }
        guard data.count <= Self.maxBytes else { throw HarnessToolError("Response too large (exceeds 5 MB).") }
        let body = String(decoding: data, as: UTF8.self)
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        let format = input["format"]?.stringValue ?? "markdown"
        var text = body
        if contentType.contains("html") && format != "html" {
            text = HTMLText.convert(body, markdown: format == "markdown")
        }
        if text.count > Self.maxCharacters {
            text = String(text.prefix(Self.maxCharacters)) + "\n\n…(truncated)"
        }
        return HarnessToolOutput(text: text, title: url.absoluteString)
    }
}

/// A deliberately small HTML → text/markdown pass: enough for documentation
/// pages and READMEs, which is what agents fetch.
enum HTMLText {
    static func convert(_ html: String, markdown: Bool) -> String {
        var text = html
        for tag in ["script", "style", "noscript", "svg", "head"] {
            text = text.replacing(try! Regex("(?is)<\(tag)[^>]*>.*?</\(tag)>"), with: "")
        }
        if markdown {
            for level in 1...6 {
                text = text.replacing(try! Regex("(?i)<h\(level)[^>]*>"), with: "\n\n" + String(repeating: "#", count: level) + " ")
            }
            text = text.replacing(try! Regex("(?i)<li[^>]*>"), with: "\n- ")
            text = text.replacing(try! Regex("(?i)<(pre|code)[^>]*>"), with: "`")
            text = text.replacing(try! Regex("(?i)</(pre|code)>"), with: "`")
        }
        text = text.replacing(try! Regex("(?i)<br\\s*/?>"), with: "\n")
        text = text.replacing(try! Regex("(?i)</(p|div|section|article|tr|h[1-6]|ul|ol|table)>"), with: "\n\n")
        text = text.replacing(try! Regex("<[^>]+>"), with: "")
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        text = text.replacing(try! Regex("[ \\t]+"), with: " ")
        text = text.replacing(try! Regex("\\n\\s*\\n\\s*\\n+"), with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - question

public struct QuestionTool: HarnessTool {
    public init() {}
    public let name = "question"
    public var isReadOnly: Bool { true }

    public var description: String {
        """
        Use this tool when you need to ask the user questions during execution. This allows you to:
        1. Gather user preferences or requirements
        2. Clarify ambiguous instructions
        3. Get decisions on implementation choices as you work
        4. Offer choices to the user about what direction to take.

        Usage notes:
        - Offer 2-4 short options per question; the user can always type their own answer.
        - Set multiple to true to allow selecting more than one option.
        - If you recommend an option, list it first and add "(Recommended)" to its label.
        """
    }

    public var parameters: JSONValue {
        Schema.object([
            "questions": Schema.array(
                Schema.object([
                    "question": Schema.string("The complete question to ask"),
                    "header": Schema.string("Very short label (max 30 chars)"),
                    "options": Schema.array(
                        Schema.object([
                            "label": Schema.string("Display text (1-5 words)"),
                            "description": Schema.string("Explanation of the choice"),
                        ], required: ["label"]),
                        description: "Available choices"
                    ),
                    "multiple": Schema.boolean("Allow selecting multiple choices"),
                ], required: ["question"]),
                description: "Questions to ask"
            ),
        ], required: ["questions"])
    }

    public func execute(_ input: JSONValue, context: HarnessToolContext) async throws -> HarnessToolOutput {
        let questions = (input["questions"]?.arrayValue ?? []).compactMap { item -> HarnessQuestion? in
            guard let text = item["question"]?.stringValue else { return nil }
            return HarnessQuestion(
                question: text,
                header: item["header"]?.stringValue,
                options: (item["options"]?.arrayValue ?? []).compactMap { option in
                    option["label"]?.stringValue.map { HarnessQuestion.Option(label: $0, description: option["description"]?.stringValue) }
                },
                multiple: item["multiple"]?.boolValue ?? false
            )
        }
        guard !questions.isEmpty else { throw HarnessToolError("`questions` must contain at least one question.") }
        guard let answers = await context.ask(questions) else {
            return .error("The user dismissed the question without answering. Continue with your best judgment or stop and explain.")
        }
        let lines = zip(questions, answers).map { question, answer in
            "\"\(question.question)\" = \"\(answer.isEmpty ? "Unanswered" : answer.joined(separator: ", "))\""
        }
        return HarnessToolOutput(
            text: "User has answered your questions: " + lines.joined(separator: ", ")
                + ". You can now continue with the user's answers in mind.",
            title: "Asked \(questions.count) question\(questions.count == 1 ? "" : "s")"
        )
    }
}

// MARK: - Default set

public enum HarnessToolset {
    /// The opencode tool surface. `question` is included only when the host
    /// can answer it; shell tools only where processes can be spawned.
    public static func standard(includeQuestion: Bool = true, includeWeb: Bool = true) -> [any HarnessTool] {
        var tools: [any HarnessTool] = [ReadTool(), GlobTool(), GrepTool(), EditTool(), WriteTool(), PatchTool(), TodoWriteTool()]
        if HarnessTerminalManager.isSupported {
            tools.insert(contentsOf: [ShellTool(), ShellOutputTool(), ShellKillTool()] as [any HarnessTool], at: 0)
        }
        if includeWeb { tools.append(WebFetchTool()) }
        if includeQuestion { tools.append(QuestionTool()) }
        return tools
    }
}
