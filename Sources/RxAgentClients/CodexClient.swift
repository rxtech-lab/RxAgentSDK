#if os(macOS)
import Foundation
import RxAgentBridge
import RxAgentCore
import RxAgentProcess

// MARK: - Policy

public enum CodexApprovalPolicy: String, Sendable {
    case untrusted
    case onRequest = "on-request"
    case never
}

public enum CodexSandboxMode: String, Sendable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"
}

/// Drives `codex app-server --listen stdio://` over JSON-RPC.
public struct CodexClient: AgentClient {
    public let id: AgentClientID
    public let displayName: String
    public var provider: AgentProvider { .codex }
    public let capabilities: AgentCapabilities

    let binaryPath: String?
    let approvalPolicy: CodexApprovalPolicy
    let sandbox: CodexSandboxMode
    /// TOML `key=value` entries. Each is passed with its own `-c` flag.
    let configOverrides: [String]
    let environmentOverrides: [String: String]
    let reasoningLevels: [AgentReasoningOption]

    private let runtime: CodexRuntime

    public init(
        id: AgentClientID = .codex,
        displayName: String = "Codex",
        binaryPath: String? = nil,
        approvalPolicy: CodexApprovalPolicy = .onRequest,
        sandbox: CodexSandboxMode = .workspaceWrite,
        configOverrides: [String] = [],
        environment: [String: String] = [:],
        reasoningLevels: [AgentReasoningOption] = .codexEfforts,
        capabilities: AgentCapabilities = .codexDefaults
    ) {
        self.id = id
        self.displayName = displayName
        self.binaryPath = binaryPath
        self.approvalPolicy = approvalPolicy
        self.sandbox = sandbox
        self.configOverrides = configOverrides
        self.environmentOverrides = environment
        self.reasoningLevels = reasoningLevels
        self.capabilities = capabilities
        self.runtime = CodexRuntime()
    }

    public func isAvailable() async -> Bool { await resolveBinary() != nil }

    func resolveBinary() async -> String? {
        if let binaryPath { return binaryPath }
        return await ShellEnvironment.shared.findBinary(named: "codex")
    }

    public func availableModels() async -> [AgentModelOption] {
        [
            AgentModelOption(id: "gpt-5-codex", displayName: "GPT-5 Codex"),
            AgentModelOption(id: "gpt-5", displayName: "GPT-5"),
        ]
    }

    /// What `model_reasoning_effort` accepts.
    public func availableReasoningLevels() async -> [AgentReasoningOption] {
        reasoningLevels
    }

    // MARK: - Send

    public func send(_ request: AgentSendRequest) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task { await run(request, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: AgentSendRequest,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async {
        continuation.yield(.turnStarted(turnID: request.turnID))

        guard let binary = await resolveBinary() else {
            continuation.yield(.failed(.binaryNotFound(name: "codex")))
            continuation.finish()
            return
        }
        // A stop that lands before the child exists has nothing to signal, so
        // every await up to registration has to check for it — otherwise the
        // turn launches anyway and runs unseen.
        guard !Task.isCancelled else { return finishCancelled(continuation) }

        let mcp = MCPConfigRenderer.codexConfiguration(
            servers: request.mcpServers,
            toolServer: request.toolServer
        )

        let arguments = launchArguments(mcpOverrides: mcp.overrides, effort: request.effort)

        // `mcp.environment` carries the bearer tokens the `-c` overrides name via
        // `bearer_token_env_var`; without merging it in, an authenticated HTTP
        // MCP server gets a config pointing at a variable that does not exist.
        var environment = await ShellEnvironment.shared.environment()
        environment.merge(environmentOverrides) { _, new in new }
        environment.merge(mcp.environment) { _, new in new }
        Self.bypassProxyForLoopback(&environment)
        guard !Task.isCancelled else { return finishCancelled(continuation) }
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

        guard await runtime.register(turnID: request.turnID, process: process),
              !Task.isCancelled
        else {
            await process.terminate()
            _ = await process.waitForExit()
            return finishCancelled(continuation)
        }
        defer { Task { await runtime.remove(turnID: request.turnID) } }

        let decoder = CodexTurnDecoder(
            turnID: request.turnID,
            continuation: continuation,
            permissions: request.permissions,
            permissionMode: request.permissionMode,
            clientID: id
        )

        let connection = JSONRPCConnection(process: process)
        await connection.start(
            onRequest: { method, params in
                await decoder.handleServerRequest(method: method, params: params)
            },
            onNotification: { method, params in
                await decoder.handleNotification(method: method, params: params)
            }
        )

        do {
            _ = try await connection.request("initialize", params: .object([
                "clientInfo": .object([
                    "name": .string("RxAgentSDK"),
                    "title": .string("RxAgentSDK"),
                    "version": .string("1.0.0"),
                ]),
                "capabilities": .object([:]),
            ]))
            try await connection.notify("initialized", params: .object([:]))

            // Resume the thread this client created earlier, or start a new one.
            let threadID: String
            if let resumeID = request.resumeSessionID {
                let result = try await connection.request("thread/resume", params: .object([
                    "threadId": .string(resumeID),
                    "cwd": .string(request.workingDirectory.path),
                ]))
                threadID = Self.threadID(from: result) ?? resumeID
            } else {
                let result = try await connection.request("thread/start", params: startParams(request))
                threadID = Self.threadID(from: result) ?? UUID().uuidString
            }

            await decoder.recordThreadID(threadID)
            continuation.yield(.sessionStarted(SessionStarted(
                nativeSessionID: threadID,
                model: request.model
            )))

            // `turn/start` returns as soon as the turn is *accepted* — its
            // result carries `status: inProgress`. The turn's content and its
            // completion both arrive later as notifications.
            _ = try await connection.request("turn/start", params: turnParams(request, threadID: threadID))

            // If the child dies mid-turn no completion notification will ever
            // arrive, so a watcher unblocks the wait on process exit.
            //
            // Deliberately not a task group: leaving a group's scope awaits
            // *every* child, and `waitForExit()` doesn't observe cancellation —
            // so a group would keep waiting for a process that is still alive
            // and idle, which is precisely the normal case here.
            let exitWatcher = Task {
                _ = await process.waitForExit()
                await decoder.signalTurnEnd()
            }
            await decoder.waitForTurnEnd()
            exitWatcher.cancel()

            if Task.isCancelled {
                continuation.yield(.failed(.cancelled))
            } else {
                await decoder.finishTurn(threadID: threadID)
            }
        } catch {
            if Task.isCancelled {
                continuation.yield(.failed(.cancelled))
            } else {
                let stderr = await process.collectedStderr()
                continuation.yield(.failed(
                    stderr.isEmpty
                        ? .protocolViolation(String(describing: error))
                        : .processExited(code: -1, stderr: stderr)
                ))
            }
        }

        await connection.close()
        process.closeStdin()
        await process.terminate()
        // terminate only sends a signal. Do not let the next turn resume while
        // this process still owns the native thread's persistence writer.
        _ = await process.waitForExit()
        continuation.finish()
    }

    /// Keeps the local tool server's `127.0.0.1` URL off any HTTP proxy.
    ///
    /// Codex's MCP client (reqwest) honours the macOS *system* proxy but not its
    /// exception list, so with Surge/ClashX enabled the loopback request goes to
    /// the proxy, which answers `503 Connection Closed` and the tool server never
    /// connects. `NO_PROXY` is the one knob reqwest checks for system proxies too.
    /// Existing entries are kept; both spellings are set because tools disagree
    /// on which one they read.
    static func bypassProxyForLoopback(_ environment: inout [String: String]) {
        let loopback = ["127.0.0.1", "localhost", "::1"]
        let existing = (environment["NO_PROXY"] ?? environment["no_proxy"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let merged = (existing + loopback.filter { !existing.contains($0) })
            .joined(separator: ",")
        environment["NO_PROXY"] = merged
        environment["no_proxy"] = merged
    }

    private func finishCancelled(_ continuation: AsyncStream<AgentEvent>.Continuation) {
        continuation.yield(.failed(.cancelled))
        continuation.finish()
    }

    // MARK: - Params

    /// Codex has no per-turn reasoning field: effort is a config key, and the
    /// child process is spawned per turn, so the turn's choice rides in on `-c`.
    ///
    /// A `configOverrides` entry that already pins `model_reasoning_effort`
    /// wins — a deployment that hard-codes the key meant it, and appending a
    /// second `-c` for the same key would leave which one applies up to the
    /// CLI's merge order.
    func launchArguments(mcpOverrides: [String] = [], effort: String? = nil) -> [String] {
        var arguments = ["app-server", "--listen", "stdio://"]
            + mcpOverrides
            + configOverrides.flatMap { ["-c", $0] }
        if let effort, !effort.isEmpty, !pinsReasoningEffort {
            arguments += ["-c", "model_reasoning_effort=\"\(effort)\""]
        }
        return arguments
    }

    private var pinsReasoningEffort: Bool {
        configOverrides.contains { override in
            override.split(separator: "=", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces) == "model_reasoning_effort"
        }
    }

    private func startParams(_ request: AgentSendRequest) -> JSONValue {
        var params: [String: JSONValue] = [
            "cwd": .string(request.workingDirectory.path),
            "approvalPolicy": .string(effectiveApprovalPolicy(request).rawValue),
            "sandbox": .string(effectiveSandbox(request).rawValue),
        ]
        // Codex has no `--append-system-prompt`; context rides on the thread as
        // developer instructions instead.
        var instructions: [String] = []
        if !request.contextText.isEmpty { instructions.append(request.contextText) }
        if request.planMode { instructions.append(Self.planModeInstructions) }
        if !instructions.isEmpty {
            params["developerInstructions"] = .string(instructions.joined(separator: "\n\n"))
        }
        return .object(params)
    }

    func turnParams(_ request: AgentSendRequest, threadID: String) -> JSONValue {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "cwd": .string(request.workingDirectory.path),
            "input": .array([.object([
                "type": .string("text"),
                "text": .string(composePrompt(request)),
            ])] + request.attachments.map { attachment in
                switch attachment.kind {
                case .image(let data, let mimeType):
                    .object(["type": .string("image"),
                             "url": .string("data:\(mimeType);base64,\(data.base64EncodedString())")])
                case .file(let url):
                    .object(["type": .string("text"), "text": .string("Attached file: \(url.path)")])
                case .text(let text):
                    .object(["type": .string("text"), "text": .string(text)])
                }
            }),
            "approvalPolicy": .string(effectiveApprovalPolicy(request).rawValue),
            "sandboxPolicy": sandboxPolicy(request),
        ]
        if let model = request.model { params["model"] = .string(model) }
        return .object(params)
    }

    /// On a resumed thread the developer instructions were set at `thread/start`,
    /// so context has to travel with the prompt.
    private func composePrompt(_ request: AgentSendRequest) -> String {
        var parts: [String] = []
        if request.resumeSessionID != nil, !request.contextText.isEmpty {
            parts.append(request.contextText)
        }
        parts.append(request.prompt)
        return parts.joined(separator: "\n\n")
    }

    private func effectiveApprovalPolicy(_ request: AgentSendRequest) -> CodexApprovalPolicy {
        if request.planMode { return .onRequest }
        return switch request.permissionMode {
        case .default, .plan: .untrusted
        case .acceptEdits, .auto: .onRequest
        case .bypassPermissions: .never
        }
    }

    private func effectiveSandbox(_ request: AgentSendRequest) -> CodexSandboxMode {
        if request.planMode { return .readOnly }
        return request.permissionMode == .bypassPermissions ? .dangerFullAccess : sandbox
    }

    private func sandboxPolicy(_ request: AgentSendRequest) -> JSONValue {
        switch effectiveSandbox(request) {
        case .readOnly:
            .object(["type": .string("readOnly"), "networkAccess": .bool(false)])
        case .dangerFullAccess:
            .object(["type": .string("dangerFullAccess")])
        case .workspaceWrite:
            .object(["type": .string("workspaceWrite")])
        }
    }

    static let planModeInstructions = """
    Plan mode is enabled. Produce a clear, step-by-step plan using the update_plan tool. \
    Do not modify files; do not run commands that mutate state. Read-only inspection is \
    allowed. End with a concise summary of the proposed plan and wait for the user to \
    disable plan mode before making changes.
    """

    static func threadID(from value: JSONValue) -> String? {
        if let object = value.objectValue {
            for key in ["threadId", "thread_id", "id"] {
                if let id = object[key]?.stringValue { return id }
            }
            if let nested = object["thread"]?.objectValue {
                for key in ["threadId", "thread_id", "id"] {
                    if let id = nested[key]?.stringValue { return id }
                }
            }
        }
        return value.stringValue
    }

    // MARK: - Lifecycle

    public func cancel(turn: UUID) async {
        await runtime.cancel(turnID: turn)
    }

    public func endSession(thread: AgentThreadID) async {}
}

actor CodexRuntime {
    private var processes: [UUID: ManagedProcess] = [:]
    /// Turns stopped before their child registered. Without these a cancel
    /// that arrives during launch finds nothing to signal and is simply lost.
    private var cancelled: Set<UUID> = []

    /// Returns false when the turn was already cancelled; the caller must then
    /// tear the process down itself.
    func register(turnID: UUID, process: ManagedProcess) -> Bool {
        if cancelled.remove(turnID) != nil { return false }
        processes[turnID] = process
        return true
    }

    func remove(turnID: UUID) {
        processes.removeValue(forKey: turnID)
        cancelled.remove(turnID)
    }

    /// Interrupts the turn's child and waits for it to actually exit, so the
    /// caller knows the next turn can safely resume the same native thread.
    func cancel(turnID: UUID) async {
        guard let process = processes.removeValue(forKey: turnID) else {
            cancelled.insert(turnID)
            return
        }
        await process.interrupt()
        _ = await process.waitForExit()
    }
}
#endif
