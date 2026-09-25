import Testing
@testable import AgentMessageListUI

@MainActor
@Suite("MessageList geometry updates")
struct MessageListGeometryUpdatesTests {
    @Test("A quick user scroll survives an idle layout update in the same frame")
    func keepsUserDrivenSample() async throws {
        let updates = MessageListGeometryUpdates()
        var handled: [String] = []

        updates.scheduleMetrics(isUserDriven: false) { handled.append("stale") }
        updates.scheduleMetrics(isUserDriven: true) { handled.append("user") }
        updates.scheduleMetrics(isUserDriven: false) { handled.append("latest") }

        #expect(handled.isEmpty)
        for _ in 0..<20 {
            if handled.count == 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(handled == ["user", "latest"])
    }

    @Test("Pinned turn release is deferred and coalesced")
    func coalescesPinRelease() async throws {
        let updates = MessageListGeometryUpdates()
        var releases = 0

        updates.schedulePinRelease { releases += 1 }
        updates.schedulePinRelease { releases += 1 }

        #expect(releases == 0)
        for _ in 0..<20 {
            if releases > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(releases == 1)
    }
}
