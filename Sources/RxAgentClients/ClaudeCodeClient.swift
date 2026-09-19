#if os(macOS)
import Foundation
import RxAgentBridge
import RxAgentCore
import RxAgentProcess

/// Drives the `claude` CLI in streaming stream-json mode.
public struct ClaudeCodeClient: AgentClient {
    public let id: AgentClientID
    public let displayName: String
    public var provider: AgentProvider { .claudeCode }
    public let capabilities: AgentCapabilities

    /// Tools pre-approved via `--allowedTools`, so internal agent mechanics
    /// (Read/Grep/Task) don't each cost an approval round trip.
    @available(*, deprecated, message: "Use [String].claudeReadOnlyTools() or .claudeDefaultTools()")
    public static let defaultSafeTools = [
        "Read", "Glob", "Grep", "LS",
        "TodoRead", "TodoWrite",
        "Agent", "Task", "TaskOutput",
        "Notebook", "NotebookEdit",
        "WebSearch", "WebFetch",
    ]

    let binaryPath: String?
    let extraArguments: [String]
    let environmentOverrides: [String: String]
    let preapprovedTools: [String]
    let reasoningLevels: [AgentReasoningOption]

    private let runtime: ClaudeRuntime

    public init(
        id: AgentClientID = .claudeCode,
        displayName: String = "Claude Code",
        binaryPath: String? = nil,
        extraArguments: [String] = [],
        environment: [String: String] = [:],
        preapprovedTools: [String] = .claudeDefaultTools(),
        reasoningLevels: [AgentReasoningOption] = .claudeCodeEfforts,
        capabilities: AgentCapabilities = .claudeCodeDefaults
    ) {
        self.id = id
        self.displayName = displayName
        self.binaryPath = binaryPath
        self.extraArguments = extraArguments
        self.environmentOverrides = environment
        self.preapprovedTools = preapprovedTools
        self.reasoningLevels = reasoningLevels
        self.capabilities = capabilities
        self.runtime = ClaudeRuntime()
    }

    // MARK: - Availability

    public func isAvailable() async -> Bool {
        await resolveBinary() != nil
    }

    func resolveBinary() async -> String? {
        if let binaryPath { return binaryPath }
        return await ShellEnvironment.shared.findBinary(named: "claude")
    }

    public func availableModels() async -> [AgentModelOption] {
        [
            AgentModelOption(id: "opus", displayName: "Opus"),
            AgentModelOption(id: "sonnet", displayName: "Sonnet"),
            AgentModelOption(id: "haiku", displayName: "Haiku"),
        ]
    }

    /// What `--effort` accepts. Narrow this at `init` when the deployment pins a
    /// model that supports fewer levels — an older Opus takes `low`/`medium`/
    /// `high` only, and the CLI rejects a level its model does not know.
    public func availableReasoningLevels() async -> [AgentReasoningOption] {
        reasoningLevels
    }

    /// Warm the PATH cache so the first turn doesn't pay a login-shell round trip.
    public func prewarm() async {
        await ShellEnvironment.shared.prewarm()
    }

    // MARK: - Send

    public func send(_ request: AgentSendRequest) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task {
                await run(request, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: AgentSendRequest,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async {
        continuation.yield(.turnStarted(turnID: request.turnID))

        guard let binary = await resolveBinary() else {
            continuation.yield(.failed(.binaryNotFound(name: "claude")))
            continuation.finish()
            return
        }

        // Approval hooks and MCP servers both need files on disk for this turn.
        let session: ClaudeTurnFiles
        do {
            session = try ClaudeTurnFiles(request: request, preapprovedTools: preapprovedTools)
            try await session.stageHooks(request: request)
        } catch {
            continuation.yield(.failed(.protocolViolation("could not stage turn config: \(error)")))
            continuation.finish()
            return
        }
        defer { session.cleanUp() }

        let arguments = buildArguments(request: request, files: session) + extraArguments
        let environment = await ShellEnvironment.shared.environment(overrides: environmentOverrides)

        let process: ManagedProcess
        do {
            process = try ManagedProcess.launch(
                executable: binary,
                arguments: arguments,
                environment: environment,
                workingDirectory: request.workingDirectory.path
            )
        } catch {
            continuation.yield(.failed(.protocolViolation(String(describing: error))))
            continuation.finish()
            return
        }

        await runtime.register(turnID: request.turnID, process: process)

        // The prompt is *not* an argument. With `--input-format stream-json` it
        // goes over stdin as a JSON user message, so stdin has to stay open.
        do {
            try process.write(jsonLine: [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": userMessageContent(request),
                ],
            ])
        } catch {
            continuation.yield(.failed(.processExited(
                code: -1,
                stderr: await process.collectedStderr()
            )))
            await runtime.remove(turnID: request.turnID)
            await process.terminate()
            continuation.finish()
            return
        }

        var decoder = ClaudeWireDecoder()
        var sawResult = false

        for await line in process.stdoutLines() {
            if Task.isCancelled { break }
            for event in decoder.decode(line: line) {
                if case .turnEnded(let result) = event, !result.isBackgroundFollowUp {
                    sawResult = true
                    // Closing stdin lets the CLI flush and exit cleanly.
                    process.closeStdin()
                }
                continuation.yield(event)
            }
        }

        for event in decoder.finish() { continuation.yield(event) }

        if Task.isCancelled {
            continuation.yield(.failed(.cancelled))
        } else if !sawResult {
            // stdout closed without a result frame: the CLI died mid-turn.
            let stderr = await process.collectedStderr()
            let code = await process.waitForExit()
            continuation.yield(.failed(.processExited(code: code, stderr: stderr)))
        }

        await runtime.remove(turnID: request.turnID)
        await process.terminate()
        continuation.finish()
    }

    // MARK: - Prompt & arguments

    /// Claude takes context through `--append-system-prompt`, so the prompt
    /// itself stays clean.
    private func composePrompt(_ request: AgentSendRequest) -> String {
        var prompt = request.prompt
        let files = request.attachments.compactMap { attachment -> String? in
            guard case .file(let url) = attachment.kind else { return nil }
            return url.path
        }
        if !files.isEmpty {
            prompt += "\n\nAttached files:\n" + files.map { "- \($0)" }.joined(separator: "\n")
        }
        return prompt
    }

    func userMessageContent(_ request: AgentSendRequest) -> [[String: Any]] {
        var content: [[String: Any]] = [["type": "text", "text": composePrompt(request)]]
        for attachment in request.attachments {
            switch attachment.kind {
            case .image(let data, let mimeType):
                content.append(["type": "image", "source": [
                    "type": "base64", "media_type": mimeType,
                    "data": data.base64EncodedString(),
                ]])
            case .text(let text):
                content.append(["type": "text", "text": text])
            case .file:
                break // File paths are already included by composePrompt.
            }
        }
        return content
    }

    func buildArguments(request: AgentSendRequest, files: ClaudeTurnFiles) -> [String] {
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
        ]

        if request.permissionMode != .default {
            arguments += ["--permission-mode", request.permissionMode.rawValue]
        }

        if !request.permissionMode.skipsHookPipeline {
            let allowed = Self.allowedToolArgument(for: request, preapproved: preapprovedTools)
            if !allowed.isEmpty {
                arguments += ["--allowedTools", allowed.joined(separator: ",")]
            }
        }

        let disallowed = Self.disallowedToolArgument(for: request)
        if !disallowed.isEmpty {
            arguments += ["--disallowedTools", disallowed.joined(separator: ",")]
        }

        if let hookSettingsPath = files.hookSettingsPath {
            arguments += ["--settings", hookSettingsPath]
        }

        if let mcpConfigPath = files.mcpConfigPath {
            arguments += ["--strict-mcp-config", "--mcp-config", mcpConfigPath]
        }

        // The CLI honours exactly one `--append-system-prompt`, so every section
        // has to be joined into a single value.
        if !request.contextText.isEmpty {
            arguments += ["--append-system-prompt", request.contextText]
        }

        if let resumeSessionID = request.resumeSessionID {
            arguments += ["--resume", resumeSessionID]
        }
        if let model = request.model {
            arguments += ["--model", model]
        }
        if let effort = request.effort {
            arguments += ["--effort", effort]
        }

        return arguments
    }

    /// What `--allowedTools` should say this turn.
    ///
    /// Without a turn allowlist this is just the client's pre-approved set —
    /// internal mechanics that shouldn't each cost an approval round trip.
    ///
    /// **With** one, the pre-approved set is dropped. An allowlist means the
    /// host has enumerated the entire surface it wants reachable; silently
    /// re-adding `Read`, `Bash` and friends underneath it would defeat the
    /// point for an app whose agent has no business touching the filesystem.
    /// Each name is expanded into the namespaced spellings the CLI will
    /// actually see (see ``MCPToolName``), since the host declares bare names.
    public static func allowedToolArgument(
        for request: AgentSendRequest,
        preapproved: [String]
    ) -> [String] {
        guard let allowed = request.allowedTools else { return preapproved }

        let servers = request.mcpServerNames
        var result: [String] = []
        for name in allowed where !request.disallowedTools.contains(name) {
            for spelling in MCPToolName.spellings(of: name, servers: servers)
            where !result.contains(spelling) {
                result.append(spelling)
            }
        }
        return result
    }

    public static func disallowedToolArgument(for request: AgentSendRequest) -> [String] {
        let servers = request.mcpServerNames
        var result: [String] = []
        for name in request.disallowedTools {
            for spelling in MCPToolName.spellings(of: name, servers: servers)
            where !result.contains(spelling) {
                result.append(spelling)
            }
        }
        return result
    }

    // MARK: - Lifecycle

    public func cancel(turn: UUID) async {
        await runtime.cancel(turnID: turn)
    }

    public func endSession(thread: AgentThreadID) async {
        // Claude holds no cross-turn process; each turn is its own child.
    }
}

/// Per-client mutable state. Kept off the `Sendable` struct so `AgentClient`
/// conformers stay value types.
actor ClaudeRuntime {
    private var processes: [UUID: ManagedProcess] = [:]

    func register(turnID: UUID, process: ManagedProcess) {
        processes[turnID] = process
    }

    func remove(turnID: UUID) {
        processes.removeValue(forKey: turnID)
    }

    func cancel(turnID: UUID) async {
        guard let process = processes.removeValue(forKey: turnID) else { return }
        await process.interrupt()
    }
}
#endif
