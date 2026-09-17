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

    @Test("Loopback MCP traffic bypasses the system proxy")
    func loopbackBypassesProxy() {
        var fresh: [String: String] = [:]
        CodexClient.bypassProxyForLoopback(&fresh)
        #expect(fresh["NO_PROXY"] == "127.0.0.1,localhost,::1")
        #expect(fresh["no_proxy"] == fresh["NO_PROXY"])

        var existing = ["no_proxy": "corp.internal, localhost"]
        CodexClient.bypassProxyForLoopback(&existing)
        #expect(existing["NO_PROXY"] == "corp.internal,localhost,127.0.0.1,::1")
        #expect(existing["no_proxy"] == existing["NO_PROXY"])
    }
}
#endif
