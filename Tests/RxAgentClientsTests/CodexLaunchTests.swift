#if os(macOS)
import Foundation
import Testing
@testable import RxAgentClients

@Suite("Codex launch arguments")
struct CodexLaunchTests {
    @Test("Configuration values are options, never app-server subcommands")
    func configOverrides() {
        let client = CodexClient(configOverrides: [
            "skip_git_repo_check=true", "model_reasoning_effort=\"low\"",
        ])
        #expect(client.launchArguments(mcpOverrides: [
            "-c", "mcp_servers.film.url=\"http://127.0.0.1:1234/mcp\"",
        ]) == [
            "app-server", "--listen", "stdio://",
            "-c", "mcp_servers.film.url=\"http://127.0.0.1:1234/mcp\"",
            "-c", "skip_git_repo_check=true",
            "-c", "model_reasoning_effort=\"low\"",
        ])
        #expect(CodexClient().launchArguments() == ["app-server", "--listen", "stdio://"])
    }
}
#endif
