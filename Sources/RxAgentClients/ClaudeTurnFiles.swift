#if os(macOS)
import Foundation
import RxAgentBridge
import RxAgentCore

/// Config files the Claude CLI needs on disk for one turn.
///
/// The CLI takes hooks and MCP servers as file paths, not inline values, so each
/// turn stages a small temporary directory and removes it afterwards.
struct ClaudeTurnFiles {
    let hookSettingsPath: String?
    let mcpConfigPath: String?
    let runToken: String

    private let directory: URL?

    init(request: AgentSendRequest, preapprovedTools: [String]) throws {
        let runToken = UUID().uuidString
        self.runToken = runToken

        let needsHooks = !request.permissionMode.skipsHookPipeline
        let needsMCP = !request.mcpServers.isEmpty || request.toolServer != nil

        guard needsHooks || needsMCP else {
            self.directory = nil
            self.hookSettingsPath = nil
            self.mcpConfigPath = nil
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rxagent-claude-\(runToken)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory

        if needsMCP {
            let path = directory.appending(path: "mcp.json")
            let json = MCPConfigRenderer.claudeConfigJSON(
                servers: request.mcpServers,
                toolServer: request.toolServer
            )
            try json.write(to: path, atomically: true, encoding: .utf8)
            self.mcpConfigPath = path.path
        } else {
            self.mcpConfigPath = nil
        }

        // The hook settings file is written by `stageHooks`, which needs an
        // await to register the resolver — `init` can't do that, so the path is
        // reserved here and filled in before launch.
        self.hookSettingsPath = needsHooks
            ? directory.appending(path: "settings.json").path
            : nil
    }

    /// Register this turn's resolver with the approval server and write the hook
    /// settings file. No-op when hooks are disabled for this mode.
    func stageHooks(request: AgentSendRequest) async throws {
        guard let hookSettingsPath else { return }
        let settings = try await ApprovalServer.shared.register(
            runToken: runToken,
            resolver: request.permissions,
            mode: request.permissionMode
        )
        try settings.write(to: URL(filePath: hookSettingsPath), atomically: true, encoding: .utf8)
    }

    func cleanUp() {
        let runToken = runToken
        Task { await ApprovalServer.shared.unregister(runToken: runToken) }
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
#endif
