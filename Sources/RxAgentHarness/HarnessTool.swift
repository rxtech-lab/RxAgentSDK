import Foundation
import RxAgentCore

// MARK: - Tool events

/// Something a tool reports while it runs. Delivered to the host through
/// ``HarnessEvent/toolProgress(callID:event:)`` as it happens, not after.
public enum HarnessToolEvent: Sendable, Equatable {
    /// Terminal output, as the process writes it.
    case output(String, stream: OutputStream)
    /// A human-readable status line ("Searching 1,204 files…").
    case status(String)
    /// A file the tool changed, with a unified diff of the change.
    case fileChanged(path: String, diff: String)
    /// The tool replaced the session's todo list.
    case todos([TodoItem])
    /// A background shell started (`started == true`) or finished.
    case backgroundShell(id: String, command: String, started: Bool, exitCode: Int32?)

    public enum OutputStream: String, Sendable, Hashable { case stdout, stderr }
}

// MARK: - Output

public struct HarnessToolOutput: Sendable, Hashable {
    /// What the model reads back.
    public var text: String
    public var isError: Bool
    /// One line for a UI's collapsed tool row.
    public var title: String?
    /// Images the model should see (rendered screenshots, read image files).
    public var images: [HarnessImage]
    /// Structured detail for a UI. Never sent to the model.
    public var metadata: [String: JSONValue]

    public init(
        text: String,
        isError: Bool = false,
        title: String? = nil,
        images: [HarnessImage] = [],
        metadata: [String: JSONValue] = [:]
    ) {
        self.text = text
        self.isError = isError
        self.title = title
        self.images = images
        self.metadata = metadata
    }

    public static func error(_ message: String) -> HarnessToolOutput {
        HarnessToolOutput(text: message, isError: true)
    }
}

/// Thrown by a tool for a failure the model should read and recover from —
/// a missing file, an ambiguous edit. Any other thrown error is reported the
/// same way; this type just reads better at the throw site.
public struct HarnessToolError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// MARK: - Questions

public struct HarnessQuestion: Sendable, Hashable, Codable {
    public struct Option: Sendable, Hashable, Codable {
        public let label: String
        public let description: String?
        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    public let question: String
    public let header: String?
    public let options: [Option]
    public let multiple: Bool

    public init(question: String, header: String? = nil, options: [Option] = [], multiple: Bool = false) {
        self.question = question
        self.header = header
        self.options = options
        self.multiple = multiple
    }
}

/// Asks the user something mid-turn. `nil` means the user dismissed it.
public protocol HarnessQuestionHandler: Sendable {
    func ask(_ questions: [HarnessQuestion], sessionID: String) async -> [[String]]?
}

/// Routes questions through a ``PermissionResolving`` the way Claude Code's
/// `AskUserQuestion` does: the answers come back as `allowWithInput`, so a host
/// that already renders that tool's question card needs nothing new.
public struct ResolverQuestionHandler: HarnessQuestionHandler {
    let resolver: any PermissionResolving
    let mode: PermissionMode
    let threadID: AgentThreadID?

    public init(resolver: any PermissionResolving, mode: PermissionMode, threadID: AgentThreadID? = nil) {
        self.resolver = resolver
        self.mode = mode
        self.threadID = threadID
    }

    public func ask(_ questions: [HarnessQuestion], sessionID: String) async -> [[String]]? {
        let input: [String: JSONValue] = [
            "questions": .array(questions.map { question in
                [
                    "question": .string(question.question),
                    "header": .string(question.header ?? ""),
                    "multiSelect": .bool(question.multiple),
                    "options": .array(question.options.map {
                        ["label": .string($0.label), "description": .string($0.description ?? "")]
                    }),
                ]
            }),
        ]
        let decision = await resolver.resolve(PermissionRequest(
            id: UUID().uuidString,
            toolName: "AskUserQuestion",
            toolInput: input,
            mode: mode,
            threadID: threadID
        ))
        guard case .allowWithInput(let updated) = decision else {
            return decision.isAllowed ? questions.map { _ in [] } : nil
        }
        // Claude Code's shape: `answers` maps question text to the chosen label(s).
        let answers = updated["answers"]?.objectValue ?? [:]
        return questions.map { question in
            switch answers[question.question] {
            case .string(let value)?:
                value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            case .array(let values)?:
                values.compactMap(\.stringValue)
            default:
                []
            }
        }
    }
}

// MARK: - Context

/// Everything a tool may reach while it runs.
///
/// Events are `async`: `emit` suspends until the host's stream has accepted the
/// event, so a tool that streams output in a tight loop is naturally
/// back-pressured rather than buffering unboundedly.
public struct HarnessToolContext: Sendable {
    public let sessionID: String
    public let callID: String
    public let workingDirectory: URL
    public let terminals: HarnessTerminalManager
    let emitter: @Sendable (HarnessToolEvent) async -> Void
    let authorizer: @Sendable (HarnessPermissionAsk) async throws -> Void
    let questioner: (any HarnessQuestionHandler)?

    public init(
        sessionID: String,
        callID: String,
        workingDirectory: URL,
        terminals: HarnessTerminalManager,
        questioner: (any HarnessQuestionHandler)? = nil,
        emit: @escaping @Sendable (HarnessToolEvent) async -> Void = { _ in },
        authorize: @escaping @Sendable (HarnessPermissionAsk) async throws -> Void = { _ in }
    ) {
        self.sessionID = sessionID
        self.callID = callID
        self.workingDirectory = workingDirectory
        self.terminals = terminals
        self.questioner = questioner
        self.emitter = emit
        self.authorizer = authorize
    }

    public func emit(_ event: HarnessToolEvent) async {
        await emitter(event)
    }

    /// Ask for permission; returns normally when granted, throws
    /// ``HarnessPermissionDenied`` otherwise.
    public func authorize(
        _ permission: String,
        resources: [String],
        always: [String]? = nil,
        toolName: String,
        input: JSONValue,
        title: String
    ) async throws {
        try await authorizer(HarnessPermissionAsk(
            sessionID: sessionID,
            permission: permission,
            resources: resources,
            alwaysPatterns: always,
            toolName: toolName,
            toolCallID: callID,
            input: input,
            title: title
        ))
    }

    /// Ask for every path outside the working directory first, then for the
    /// tool's own permission. The two checks opencode performs for any
    /// path-taking tool.
    public func authorizePaths(
        _ urls: [URL],
        permission: String,
        toolName: String,
        input: JSONValue,
        title: String
    ) async throws {
        let external = urls.filter { !HarnessPaths.isInside($0, root: workingDirectory) }
        if !external.isEmpty {
            let directories = external.map { url in
                (url.hasDirectoryPath ? url : url.deletingLastPathComponent()).standardizedFileURL.path
            }
            try await authorize(
                HarnessPermissionKey.externalDirectory,
                resources: external.map(\.standardizedFileURL.path),
                always: directories.map { $0 + "/*" },
                toolName: toolName,
                input: input,
                title: "Access outside the project: \(external.map(\.path).joined(separator: ", "))"
            )
        }
        try await authorize(
            permission,
            resources: urls.map { HarnessPaths.relative($0, to: workingDirectory) },
            toolName: toolName,
            input: input,
            title: title
        )
    }

    public func ask(_ questions: [HarnessQuestion]) async -> [[String]]? {
        await questioner?.ask(questions, sessionID: sessionID)
    }

    /// A path from the model, resolved against the working directory.
    public func resolve(_ path: String) -> URL {
        HarnessPaths.resolve(path, against: workingDirectory)
    }
}

// MARK: - Tool protocol

/// A tool the harness can offer the model.
///
/// Conformers are values; anything stateful (a running shell, a file-time
/// cache) belongs in the context's ``HarnessTerminalManager`` or the tool's own
/// actor. `execute` is `async throws` and may emit as many
/// ``HarnessToolEvent``s as it likes through the context before returning.
public protocol HarnessTool: Sendable {
    var name: String { get }
    var description: String { get }
    /// JSON Schema of the input object.
    var parameters: JSONValue { get }
    /// Read-only tools may run concurrently when the model asks for several at once.
    var isReadOnly: Bool { get }

    func execute(_ input: JSONValue, context: HarnessToolContext) async throws -> HarnessToolOutput
}

public extension HarnessTool {
    var isReadOnly: Bool { false }
    var spec: HarnessToolSpec { HarnessToolSpec(name: name, description: description, parameters: parameters) }
}

/// A host tool (``AnyAgentTool``) offered through the harness.
///
/// Raises the `mcp` permission keyed by tool name, unless the tool declares
/// itself read-only.
public struct AgentToolAdapter: HarnessTool {
    public let tool: AnyAgentTool
    let threadID: AgentThreadID

    public init(_ tool: AnyAgentTool, threadID: AgentThreadID) {
        self.tool = tool
        self.threadID = threadID
    }

    public var name: String { tool.name }
    public var description: String { tool.description }
    public var parameters: JSONValue { tool.inputSchema }
    public var isReadOnly: Bool { tool.annotations.readOnlyHint == true }

    public func execute(_ input: JSONValue, context: HarnessToolContext) async throws -> HarnessToolOutput {
        if !isReadOnly {
            try await context.authorize(
                HarnessPermissionKey.mcp,
                resources: [tool.name],
                toolName: tool.name,
                input: input,
                title: "Run \(tool.annotations.title ?? tool.name)"
            )
        }
        let result = await tool.call(input, context: AgentToolContext(
            threadID: threadID,
            workingDirectory: context.workingDirectory
        ))
        return HarnessToolOutput(text: result.content, isError: result.isError)
    }
}

// MARK: - Schema helpers

/// Small builders so tool schemas read like the opencode definitions they
/// mirror instead of nested dictionary literals.
public enum Schema {
    public static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": false,
        ]
    }

    public static func string(_ description: String, enum values: [String]? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let values { fields["enum"] = .array(values.map(JSONValue.string)) }
        return .object(fields)
    }

    public static func integer(_ description: String) -> JSONValue {
        ["type": "integer", "description": .string(description)]
    }

    public static func number(_ description: String) -> JSONValue {
        ["type": "number", "description": .string(description)]
    }

    public static func boolean(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }

    public static func array(_ items: JSONValue, description: String) -> JSONValue {
        ["type": "array", "items": items, "description": .string(description)]
    }
}

// MARK: - Paths

public enum HarnessPaths {
    public static func resolve(_ path: String, against root: URL) -> URL {
        var expanded = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if expanded.hasPrefix("~") { expanded = (expanded as NSString).expandingTildeInPath }
        if expanded.hasPrefix("/") { return URL(filePath: expanded).standardizedFileURL }
        return root.appending(path: expanded).standardizedFileURL
    }

    public static func isInside(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    /// Relative to `root` when inside it, absolute otherwise. What permission
    /// patterns like `src/*.swift` are matched against.
    public static func relative(_ url: URL, to root: URL) -> String {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        return path
    }
}
