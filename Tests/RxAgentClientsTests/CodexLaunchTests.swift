#if os(macOS)
import Foundation
import Testing
import RxAgentCore
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

    @Test("Resume replaces stale developer instructions with the current host policy")
    func resumeRefreshesContext() {
        let client = CodexClient()
        let context = "Use lyric tools and native web search. Cite source URLs."
        let request = AgentSendRequest(threadID: AgentThreadID(), resumeSessionID: "old-native-session",
                                       prompt: "Search again", workingDirectory: URL(filePath: "/tmp/lyrics"),
                                       contextText: context)
        let params = client.resumeParams(request, threadID: "old-native-session")
        #expect(params["threadId"]?.stringValue == "old-native-session")
        #expect(params["cwd"]?.stringValue == "/tmp/lyrics")
        #expect(params["developerInstructions"]?.stringValue == context)
        #expect(params["sandbox"]?.stringValue == "workspace-write")
        #expect(params["approvalPolicy"]?.stringValue == "untrusted")
    }

    @Test("Resumed context reaches the model as developer instructions, not user text")
    func resumedContextPriority() throws {
        let client = CodexClient()
        let context = "Native web research is available."
        let request = AgentSendRequest(threadID: AgentThreadID(), resumeSessionID: "old", prompt: "Search",
                                       workingDirectory: URL(filePath: "/tmp"), contextText: context)
        let params = client.contextUpdateParams(request, threadID: "old")
        let item = try #require(params["items"]?.arrayValue?.first)
        #expect(params["threadId"]?.stringValue == "old")
        #expect(item["role"]?.stringValue == "developer")
        #expect(item["content"]?.arrayValue?.first?["text"]?.stringValue?.hasSuffix(context) == true)
        #expect(client.turnParams(request, threadID: "old")["input"]?.arrayValue?.first?["text"]?.stringValue == "Search")
    }

    @Test("Resume explicitly clears a removed host context")
    func resumeClearsContext() {
        let request = AgentSendRequest(threadID: AgentThreadID(), prompt: "Continue",
                                       workingDirectory: URL(filePath: "/tmp"))
        #expect(CodexClient().resumeParams(request, threadID: "old")["developerInstructions"]?.stringValue == "")
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
