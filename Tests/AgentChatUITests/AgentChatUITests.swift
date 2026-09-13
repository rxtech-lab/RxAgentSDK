import Foundation
import SwiftUI
import Testing
import RxAgentContext
import RxAgentCore
@testable import AgentChatUI

@MainActor
@Suite("AgentTranscriptItem")
struct AgentTranscriptItemTests {

    @Test("A user message is flagged for the list's pinning logic")
    func userMessageFlag() {
        let item = AgentTranscriptItem.message(.text("hello", role: .user))
        #expect(item.isUserMessage)
        #expect(!item.isMessageListAccessory)
    }

    @Test("An assistant message is not a user message")
    func assistantMessageFlag() {
        let item = AgentTranscriptItem.message(.text("hi", role: .assistant))
        #expect(!item.isUserMessage)
    }

    /// Accessories must be excluded from turn-height measurement, or the
    /// reserved tail spacer measures the wrong thing.
    @Test("Accessories are flagged as accessories")
    func accessoryFlag() {
        let item = AgentTranscriptItem.accessory(.streamingIndicator)
        #expect(item.isMessageListAccessory)
        #expect(!item.isUserMessage)
    }

    @Test("Item ids are stable across rebuilds")
    func stableIDs() {
        let message = AgentMessage.text("hello", role: .user)
        #expect(AgentTranscriptItem.message(message).id == AgentTranscriptItem.message(message).id)
    }

    @Test("items(for:) preserves transcript order")
    func itemsPreserveOrder() {
        let messages = [
            AgentMessage.text("one", role: .user),
            AgentMessage.text("two", role: .assistant),
        ]
        let items = AgentTranscriptItem.items(for: messages)
        #expect(items.count == 2)
        #expect(items[0].isUserMessage)
        #expect(!items[1].isUserMessage)
    }

    private func toolMessage(_ name: String) -> AgentMessage {
        AgentMessage(
            role: .assistant,
            blocks: [.toolCall(AgentToolCall(id: name, name: name, result: "ok", hasCompleteInput: true))]
        )
    }

    @Test("items(for:) folds a run of tool-only messages into one group")
    func itemsFoldToolRuns() {
        let messages = [
            AgentMessage.text("look around", role: .user),
            toolMessage("list"),
            toolMessage("read"),
            toolMessage("search"),
            AgentMessage.text("found it", role: .assistant),
        ]
        let items = AgentTranscriptItem.items(for: messages, transientGroupMinSize: 2)
        #expect(items.count == 3)
        guard case .transientGroup(let calls) = items[1].kind else {
            Issue.record("expected a transient group, got \(items[1].kind)")
            return
        }
        #expect(calls.map(\.name) == ["list", "read", "search"])
        #expect(!items[2].isUserMessage)
    }

    @Test("items(for:) leaves runs shorter than the minimum alone")
    func itemsKeepShortRuns() {
        let messages = [toolMessage("list"), AgentMessage.text("done", role: .assistant)]
        let items = AgentTranscriptItem.items(for: messages, transientGroupMinSize: 2)
        #expect(items.count == 2)
        if case .transientGroup = items[0].kind { Issue.record("a lone call must not fold") }
    }

    @Test("items(for:) never folds unless asked")
    func itemsDefaultNoFold() {
        let messages = [toolMessage("list"), toolMessage("read")]
        #expect(AgentTranscriptItem.items(for: messages).count == 2)
    }

    @Test("A message with visible text breaks a run")
    func textBreaksRun() {
        var talkative = toolMessage("read")
        talkative.blocks.append(.text(id: UUID(), "Here is what I found."))
        let messages = [toolMessage("list"), talkative, toolMessage("search")]
        let items = AgentTranscriptItem.items(for: messages, transientGroupMinSize: 2)
        #expect(items.count == 3)
        for item in items {
            if case .transientGroup = item.kind { Issue.record("nothing should fold here") }
        }
    }
}

@MainActor
@Suite("InteractivePermissionCoordinator")
struct InteractivePermissionCoordinatorTests {

    private func request(
        _ tool: String,
        command: String? = nil,
        mode: PermissionMode = .default
    ) -> PermissionRequest {
        var input: [String: JSONValue] = [:]
        if let command { input["command"] = .string(command) }
        return PermissionRequest(id: UUID().uuidString, toolName: tool, toolInput: input, mode: mode)
    }

    @Test("A request becomes pending until answered")
    func pendingThenResolved() async {
        let coordinator = InteractivePermissionCoordinator()
        let task = Task { await coordinator.resolve(request("Bash", command: "ls")) }

        while coordinator.pending == nil { await Task.yield() }
        #expect(coordinator.pending?.toolName == "Bash")

        coordinator.respond(.allow)
        #expect(await task.value == .allow)
        #expect(coordinator.pending == nil)
    }

    @Test("Requests queue and are presented one at a time")
    func queuesRequests() async {
        let coordinator = InteractivePermissionCoordinator()
        let first = Task { await coordinator.resolve(request("Bash", command: "one")) }
        while coordinator.pending == nil { await Task.yield() }

        let second = Task { await coordinator.resolve(request("Bash", command: "two")) }
        // Give the second a chance to enqueue.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(coordinator.pending?.command == "one", "the second must not displace the first")

        coordinator.respond(.allow)
        #expect(await first.value == .allow)

        while coordinator.pending == nil { await Task.yield() }
        #expect(coordinator.pending?.command == "two")
        coordinator.respond(.deny)
        #expect(await second.value == .deny)
    }

    @Test("An always-allow command answers later identical commands without prompting")
    func rememberedCommand() async {
        let coordinator = InteractivePermissionCoordinator()
        let first = Task { await coordinator.resolve(request("Bash", command: "npm test")) }
        while coordinator.pending == nil { await Task.yield() }
        coordinator.respond(.allowAlwaysCommand(command: "npm test"))
        _ = await first.value

        // No prompt should appear this time.
        let repeated = await coordinator.resolve(request("Bash", command: "npm test"))
        #expect(repeated == .allow)
        #expect(coordinator.pending == nil)
    }

    @Test("A session-tool allow answers later calls to the same tool")
    func rememberedTool() async {
        let coordinator = InteractivePermissionCoordinator()
        let first = Task { await coordinator.resolve(request("Edit")) }
        while coordinator.pending == nil { await Task.yield() }
        coordinator.respond(.allowSessionTool)
        _ = await first.value

        #expect(await coordinator.resolve(request("Edit")) == .allow)
    }

    @Test("bypassPermissions never prompts")
    func bypassNeverPrompts() async {
        let coordinator = InteractivePermissionCoordinator()
        let decision = await coordinator.resolve(
            request("Bash", command: "rm -rf /", mode: .bypassPermissions)
        )
        #expect(decision == .allow)
        #expect(coordinator.pending == nil)
    }

    @Test("cancelAll denies everything outstanding")
    func cancelAll() async {
        let coordinator = InteractivePermissionCoordinator()
        let first = Task { await coordinator.resolve(request("Bash", command: "one")) }
        while coordinator.pending == nil { await Task.yield() }
        let second = Task { await coordinator.resolve(request("Bash", command: "two")) }
        try? await Task.sleep(for: .milliseconds(50))

        coordinator.cancelAll()
        #expect(await first.value == .deny)
        #expect(await second.value == .deny)
        #expect(coordinator.pending == nil)
    }
}

@MainActor
@Suite("AgentTheme")
struct AgentThemeTests {

    @Test("The compact theme is derived from standard with tighter metrics")
    func compactDerivesFromStandard() {
        #expect(AgentTheme.compact.cornerRadius < AgentTheme.standard.cornerRadius)
        #expect(AgentTheme.compact.markdown.bodyFontSize < AgentTheme.standard.markdown.bodyFontSize)
        #expect(AgentTheme.compact.rowPadding.leading < AgentTheme.standard.rowPadding.leading)
    }
}
