import Foundation
import RxAgentCore
import Testing
@testable import RxAgentLLM

@Suite("Attachment replay")
struct AttachmentHistoryTests {
    @Test("An image-only turn remains visual input on the next OpenAI-compatible request")
    func imageHistory() {
        let image = AgentAttachment(kind: .image(Data([1, 2, 3]), mimeType: "image/png"))
        let request = AgentSendRequest(threadID: AgentThreadID(), prompt: "What color was it?",
                                       workingDirectory: URL(filePath: "/tmp"),
                                       history: [AgentMessage(role: .user, attachments: [image])])
        let messages = OpenAIChatClient.seed(request)
        #expect(messages.count == 2)
        #expect(messages.first?.parts == [.imageURL("data:image/png;base64,AQID")])
        #expect(messages.last?.text == "What color was it?")
    }
}
