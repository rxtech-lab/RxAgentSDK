import Foundation
import RxAgentCore
import Testing
@testable import RxAgentLLM

@Suite("OpenAI reasoning effort")
struct ReasoningBodyTests {

    private func client(
        levels: [AgentReasoningOption],
        key: String = "reasoning_effort"
    ) -> OpenAIChatClient {
        OpenAIChatClient(configuration: .init(
            endpoint: URL(string: "https://example.invalid/v1")!,
            defaultModel: "gpt-5",
            extraBody: ["providerOptions": .string("x")],
            reasoningLevels: levels,
            reasoningEffortKey: key
        ))
    }

    private func request(effort: String?) -> AgentSendRequest {
        AgentSendRequest(
            threadID: AgentThreadID(),
            prompt: "x",
            workingDirectory: URL(filePath: "/tmp"),
            effort: effort
        )
    }

    @Test("A supported level is merged into the request body")
    func merged() {
        let body = client(levels: .openAIReasoningEfforts).requestBody(for: request(effort: "high"))
        #expect(body["reasoning_effort"]?.stringValue == "high")
        // Without clobbering the configured extras.
        #expect(body["providerOptions"]?.stringValue == "x")
    }

    @Test("A gateway can rename the field")
    func customKey() {
        let body = client(levels: .openAIReasoningEfforts, key: "effort")
            .requestBody(for: request(effort: "low"))
        #expect(body["effort"]?.stringValue == "low")
        #expect(body["reasoning_effort"] == nil)
    }

    /// A level left over from another client would otherwise fail the whole
    /// request on a field this endpoint has never heard of.
    @Test("A level the endpoint never advertised is dropped")
    func unsupportedLevelDropped() {
        #expect(client(levels: .openAIReasoningEfforts)
            .requestBody(for: request(effort: "xhigh"))["reasoning_effort"] == nil)
        #expect(client(levels: [])
            .requestBody(for: request(effort: "high"))["reasoning_effort"] == nil)
    }

    @Test("No effort means no field")
    func absent() {
        #expect(client(levels: .openAIReasoningEfforts)
            .requestBody(for: request(effort: nil))["reasoning_effort"] == nil)
    }
}
