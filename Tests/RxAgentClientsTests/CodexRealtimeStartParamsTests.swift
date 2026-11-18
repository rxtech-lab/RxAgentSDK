#if os(macOS)
import Foundation
import RxAgentCore
import Testing
@testable import RxAgentClients

@Suite("Codex realtime start params")
struct CodexRealtimeStartParamsTests {
    @Test("Initial items reach the realtime model and select V3 over WebSocket")
    func initialItemsSelectV3() {
        let params = CodexClient.realtimeStartParams(
            threadID: "t1", transport: .websocket,
            initialItems: [.init(role: .developer, text: "You are Sea Baby."), .init(role: .user, text: "  ")]
        )
        #expect(params["version"] == .string("v3"))
        #expect(params["initialItems"] == .array([
            .object(["role": .string("developer"), "text": .string("You are Sea Baby.")]),
        ]))
    }

    @Test("WebSocket without items keeps the configured version; WebRTC defaults to V3")
    func defaults() {
        let ws = CodexClient.realtimeStartParams(threadID: "t1", transport: .websocket)
        #expect(ws["version"] == nil)
        #expect(ws["initialItems"] == nil)
        let rtc = CodexClient.realtimeStartParams(threadID: "t1", transport: .webRTC(offer: "sdp"))
        #expect(rtc["version"] == .string("v3"))
    }

    @Test("An explicit version wins")
    func explicitVersion() {
        let params = CodexClient.realtimeStartParams(
            threadID: "t1", transport: .websocket,
            initialItems: [.init(role: .developer, text: "x")], version: "v2"
        )
        #expect(params["version"] == .string("v2"))
    }
}
#endif
