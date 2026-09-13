#if os(macOS)
import AppKit
import Observation
import RxAgentContext
import RxAgentCore
import SwiftUI
import Testing
import ViewInspector
@testable import AgentChatUI

@MainActor
@Suite("Chat activity indicator", .serialized)
struct AgentStreamingIndicatorTests {
    @Test("Dots animate on repeated turns while the token footer stays mounted")
    func repeatedTurnsAnimate() async throws {
        let model = IndicatorModel()
        let host = IndicatorHost(IndicatorHarness(model: model))
        defer { host.close() }

        for turn in 1...3 {
            model.isStreaming = true
            try await Task.sleep(for: .milliseconds(500))
            #expect(try await host.distinctFrames() > 1, "dots froze on turn \(turn)")
            model.isStreaming = false
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    @Test("Dots resume when the transcript reappears during a turn")
    func reappearingIndicatorAnimates() async throws {
        let model = IndicatorModel()
        model.isStreaming = true
        let host = IndicatorHost(IndicatorHarness(model: model))
        defer { host.close() }
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await host.distinctFrames() > 1)
        model.isVisible = false
        try await Task.sleep(for: .milliseconds(150))
        model.isVisible = true
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await host.distinctFrames() > 1)
    }

    @Test("The chat keeps its activity dots through tool approval and execution")
    func toolsKeepActivityIndicator() async throws {
        let script = AgentEventScript([
            .event(.messageStarted(role: .assistant, id: "lookup")),
            .event(.toolCallStarted(id: "lookup", name: "marketplace_list")),
            .event(.toolCallInput(id: "lookup", input: [:])),
            .event(.toolCallResult(id: "lookup", content: "Found", isError: false)),
            .event(.messageEnded(id: "lookup", usage: nil)),
            .event(.messageStarted(role: .assistant, id: "reply")),
            .event(.toolCallStarted(id: "call", name: "marketplace_create")),
            .event(.toolCallInput(id: "call", input: [:])),
            .event(.permissionRequested(PermissionRequest(
                id: "call", toolName: "marketplace_create", toolInput: [:], mode: .default
            ))),
            .pause(.seconds(2)),
            .event(.toolCallResult(id: "call", content: "Created", isError: false)),
            .pause(.seconds(2)),
            .event(.messageEnded(id: "reply", usage: UsageInfo(inputTokens: 100, outputTokens: 20))),
            .event(.turnEnded(TurnResult())),
        ])
        let agent = Agent(clients: [PreviewAgentClient(script: script, deltaInterval: .zero)])
        defer { agent.stop() }
        let chat = AgentChatView(agent: agent).agentToolCallCollapse(.consecutive(minimum: 2))
        agent.send("Create a template")
        try await waitUntil {
            if case .awaitingPermission = agent.phase { return true }
            return false
        }
        #expect(agent.phase.isBusy)
        let pending = try chat.inspect().find(AgentStreamingIndicator.self).actualView()
        #expect(try pending.inspect().find(ViewType.HStack.self).accessibilityLabel().string() == "Working")
        let host = IndicatorHost(pending)
        defer { host.close() }
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await host.distinctFrames() > 1, "no pulsing dots while a tool is pending")
        try await waitUntil {
            agent.thread.messages.flatMap(\.toolCalls).allSatisfy { $0.isComplete }
        }
        #expect(agent.thread.messages.flatMap(\.toolCalls).count == 2)
        let afterTool = try chat.inspect().find(AgentStreamingIndicator.self).actualView()
        #expect(try afterTool.inspect().find(ViewType.HStack.self).accessibilityLabel().string() == "Working")
        host.update(afterTool)
        #expect(try await host.distinctFrames() > 1, "dots stopped before the final answer")
        try await waitUntil { agent.phase == .idle }
        #expect(agent.phase == .idle)
        let finished = try chat.inspect().find(AgentStreamingIndicator.self).actualView()
        #expect(try finished.inspect().find(ViewType.HStack.self).accessibilityLabel().string() == "")
        host.update(finished)
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await host.distinctFrames() == 1, "dots kept animating after the turn ended")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "The scripted chat did not reach the expected state")
    }
}

@MainActor @Observable
private final class IndicatorModel {
    var isStreaming = false
    var isVisible = true
}

private struct IndicatorHarness: View {
    let model: IndicatorModel

    var body: some View {
        VStack {
            if model.isVisible {
                AgentStreamingIndicator(
                    isStreaming: model.isStreaming,
                    usage: UsageInfo(inputTokens: 100, outputTokens: 20)
                )
            }
        }
    }
}

/// Compare rendered frames of the actual indicator, not its animation flag.
@MainActor
private final class IndicatorHost<Content: View> {
    let view: NSHostingView<AnyView>
    let window: NSWindow

    init(_ content: Content) {
        _ = NSApplication.shared
        view = NSHostingView(rootView: AnyView(content.padding(20).background(Color.black)))
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 300, height: 90),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
    }

    func update(_ content: Content) {
        view.rootView = AnyView(content.padding(20).background(Color.black))
    }

    func close() { window.close() }

    func distinctFrames() async throws -> Int {
        var frames = Set<Data>()
        for _ in 0..<7 {
            try await Task.sleep(for: .milliseconds(90))
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            frames.insert(try #require(bitmap.representation(using: .png, properties: [:])))
        }
        return frames.count
    }
}
#endif
