#if os(macOS)
import Foundation
import RxAgentCore
import Testing
@testable import RxAgentClients

@Suite("Attachment delivery")
struct AttachmentWireTests {
    private var request: AgentSendRequest {
        AgentSendRequest(threadID: AgentThreadID(), prompt: "Use these references",
                         attachments: [
                            .init(kind: .image(Data([1, 2, 3]), mimeType: "image/png"), label: "Reference"),
                            .file(URL(filePath: "/tmp/notes.txt")),
                            .file(URL(filePath: "/tmp/Footage")),
                         ], workingDirectory: URL(filePath: "/tmp"))
    }

    @Test("Codex receives image bytes and file/folder paths as input items")
    func codexInput() throws {
        let params = CodexClient().turnParams(request, threadID: "thread-1")
        guard case .array(let input)? = params["input"] else { Issue.record("Missing input"); return }
        #expect(input.count == 4)
        #expect(input[0]["text"]?.stringValue == request.prompt)
        #expect(input[1]["type"]?.stringValue == "image")
        #expect(input[1]["url"]?.stringValue == "data:image/png;base64,AQID")
        #expect(input[2]["text"]?.stringValue?.contains("/tmp/notes.txt") == true)
        #expect(input[3]["text"]?.stringValue?.contains("/tmp/Footage") == true)
        #expect(CodexClient().capabilities.contains(.attachments))
    }

    @Test("Claude receives a base64 image block alongside file and folder references")
    func claudeInput() throws {
        let content = ClaudeCodeClient().userMessageContent(request)
        #expect(content.count == 2)
        let prompt = try #require(content[0]["text"] as? String)
        #expect(prompt.contains("/tmp/notes.txt"))
        #expect(prompt.contains("/tmp/Footage"))
        #expect(content[1]["type"] as? String == "image")
        let source = try #require(content[1]["source"] as? [String: String])
        #expect(source == ["type": "base64", "media_type": "image/png", "data": "AQID"])
    }
}
#endif
