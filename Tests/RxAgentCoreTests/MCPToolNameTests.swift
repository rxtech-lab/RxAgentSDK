import Foundation
import Testing

@testable import RxAgentCore

@Suite("MCP tool naming")
struct MCPToolNameTests {

    @Test("A namespaced name reduces to its bare form")
    func stripsPrefix() {
        #expect(MCPToolName.bare("mcp__film_workflow__caption_export") == "caption_export")
        #expect(MCPToolName.server(of: "mcp__film_workflow__caption_export") == "film_workflow")
    }

    @Test("A bare name is left alone in both directions")
    func leavesBareNames() {
        #expect(MCPToolName.bare("Bash") == "Bash")
        #expect(MCPToolName.server(of: "Bash") == nil)
        #expect(MCPToolName.prefixed("mcp__x__y", server: "z") == "mcp__x__y")
    }

    @Test("Prefixing namespaces a bare name")
    func addsPrefix() {
        #expect(MCPToolName.prefixed("caption_export", server: "film_workflow")
            == "mcp__film_workflow__caption_export")
    }

    @Test("A tool name containing the separator keeps its tail intact")
    func toolNameWithSeparator() {
        // Only the first `__` after the prefix delimits the server, so a tool
        // whose own name contains `__` survives the round trip.
        let full = "mcp__server__odd__tool"
        #expect(MCPToolName.bare(full) == "odd__tool")
        #expect(MCPToolName.server(of: full) == "server")
    }

    @Test("Spellings cover every server in play")
    func spellings() {
        let spellings = MCPToolName.spellings(
            of: "caption_export",
            servers: ["film_workflow", "rxagent-tools"]
        )
        #expect(spellings.contains("caption_export"))
        #expect(spellings.contains("mcp__film_workflow__caption_export"))
        #expect(spellings.contains("mcp__rxagent-tools__caption_export"))
    }
}

@Suite("Turn tool scoping is namespace-insensitive")
struct NamespacedScopingTests {

    private func request(
        allowed: [String]? = nil,
        disallowed: [String] = []
    ) -> AgentSendRequest {
        AgentSendRequest(
            threadID: AgentThreadID(),
            prompt: "x",
            workingDirectory: URL(filePath: "/tmp"),
            mcpServers: [.http(name: "film_workflow", url: URL(string: "http://127.0.0.1:1/mcp")!)],
            allowedTools: allowed,
            disallowedTools: disallowed
        )
    }

    @Test("A bare allowlist admits the namespaced spelling a CLI agent uses")
    func bareListAdmitsNamespaced() {
        // The host declares its policy once; whether the caller is in-process or
        // a CLI agent must not change the answer.
        let request = request(allowed: ["caption_export"])
        #expect(request.permitsTool(named: "caption_export"))
        #expect(request.permitsTool(named: "mcp__film_workflow__caption_export"))
        #expect(!request.permitsTool(named: "Bash"))
    }

    @Test("A bare denylist withholds the namespaced spelling too")
    func bareDenylistWithholdsNamespaced() {
        let request = request(disallowed: ["delete_project"])
        #expect(!request.permitsTool(named: "delete_project"))
        #expect(!request.permitsTool(named: "mcp__film_workflow__delete_project"))
    }

    @Test("Server names include the local tool server")
    func serverNames() {
        let request = AgentSendRequest(
            threadID: AgentThreadID(),
            prompt: "x",
            workingDirectory: URL(filePath: "/tmp"),
            toolServer: LocalToolServerHandle(
                name: "rxagent-tools",
                httpURL: URL(string: "http://127.0.0.1:2/mcp")!
            ),
            mcpServers: [.http(name: "film_workflow", url: URL(string: "http://127.0.0.1:1/mcp")!)]
        )
        #expect(request.mcpServerNames == ["film_workflow", "rxagent-tools"])
    }

    @Test("A disabled server contributes no namespace")
    func disabledServerExcluded() {
        var disabled = MCPServerSpec.http(name: "off", url: URL(string: "http://127.0.0.1:1/mcp")!)
        disabled.enabled = false
        let request = AgentSendRequest(
            threadID: AgentThreadID(),
            prompt: "x",
            workingDirectory: URL(filePath: "/tmp"),
            mcpServers: [disabled]
        )
        #expect(request.mcpServerNames.isEmpty)
    }
}
