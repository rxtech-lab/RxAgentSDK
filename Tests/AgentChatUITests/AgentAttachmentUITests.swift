#if os(macOS)
import AppKit
import RxAgentContext
import RxAgentCore
import SwiftUI
import Testing
import ViewInspector
@testable import AgentChatUI

@MainActor
@Suite("Chat attachments", .serialized)
struct AgentAttachmentUITests {
    @Test("Native paste adds an image, removal works, and image-only send reaches the agent")
    func pasteRemoveAndSend() async throws {
        let agent = Agent(clients: [AttachmentClient()])
        let host = AttachmentHost(agent: agent)
        defer { host.window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let field = try #require(host.textView)
        let data = try imageData()
        let clipboard = ClipboardBackup()
        defer { clipboard.restore() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        field.paste(nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(agent.draftAttachments.count == 1)
        #expect(field.string.isEmpty)
        let first = try #require(agent.draftAttachments.first)
        if case .image(let actual, let mime) = first.kind {
            #expect(actual == data)
            #expect(mime == "image/png")
        } else { Issue.record("Paste must retain image bytes") }
        try host.press("agent-remove-attachment-\(first.id)")
        #expect(agent.draftAttachments.isEmpty)

        field.paste(nil)
        try await Task.sleep(for: .milliseconds(200))
        try host.capture("/private/tmp/agent-attachment-composer.png")
        let sending = agent.draftAttachments
        try host.press("agent-composer-send")
        try await Task.sleep(for: .milliseconds(100))
        #expect(agent.draftAttachments.isEmpty)
        #expect(agent.thread.messages.first?.attachments == sending)
        #expect(agent.thread.messages.first?.plainText == "")
    }

    @Test("The plus button opens a picker that accepts files and folders")
    func pickerAllowsFilesAndFolders() async throws {
        let host = AttachmentHost(agent: Agent(clients: [AttachmentClient()]))
        defer { host.window.close() }
        try await Task.sleep(for: .milliseconds(200))
        try host.press("agent-composer-add-attachment")
        try await Task.sleep(for: .milliseconds(350))
        let panel = try #require(NSApp.windows.compactMap { $0 as? NSOpenPanel }.first)
        defer { panel.cancel(nil) }
        #expect(panel.canChooseFiles)
        #expect(panel.canChooseDirectories)
        #expect(panel.allowsMultipleSelection)
    }

    @Test("Dropping an image, a file, and a folder onto the text field creates three attachments")
    func dropsFilesAndFolders() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let image = fixture.appendingPathComponent("reference.png")
        let file = fixture.appendingPathComponent("notes.txt")
        let folder = fixture.appendingPathComponent("Footage")
        try imageData().write(to: image)
        try Data("Notes".utf8).write(to: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let agent = Agent(clients: [AttachmentClient()])
        let host = AttachmentHost(agent: agent)
        defer { host.window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let field = try #require(host.textView)
        let drag = AttachmentDrag(urls: [image, file, folder], window: host.window)
        #expect(field.draggingEntered(drag) == .copy)
        #expect(field.performDragOperation(drag))
        try await Task.sleep(for: .milliseconds(150))
        #expect(agent.draftAttachments.map(\.label) == ["reference.png", "notes.txt", "Footage"])
        #expect(agent.draftAttachments[1].kind == .file(file))
        #expect(agent.draftAttachments[2].kind == .file(folder))
        #expect(field.string.isEmpty)
        try host.capture("/private/tmp/agent-file-folder-attachments.png")
    }

    @Test("Text paste still inserts at the caret and TIFF screenshots become PNG images")
    func textPasteAndTIFF() throws {
        let field = AgentNSTextView()
        var attachments: [AgentAttachment] = []
        field.onPasteImages = { attachments.append(contentsOf: $0) }
        let clipboard = ClipboardBackup()
        defer { clipboard.restore() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("world", forType: .string)
        field.string = "Hello "
        field.setSelectedRange(NSRange(location: 6, length: 0))
        field.paste(nil)
        #expect(field.string == "Hello world")
        #expect(attachments.isEmpty)
        let image = try #require(NSImage(data: imageData()))
        NSPasteboard.general.clearContents()
        let tiff = try #require(image.tiffRepresentation)
        NSPasteboard.general.setData(tiff, forType: .tiff)
        field.paste(nil)
        #expect(field.string == "Hello world")
        let pasted = try #require(attachments.first)
        if case .image(let data, let mime) = pasted.kind {
            #expect(mime == "image/png")
            #expect(AgentImageLoader.thumbnail(data) != nil)
        } else { Issue.record("Expected an image") }
    }

    @Test("An unsupported engine offers no attachment button")
    func unsupportedEngine() async throws {
        let host = AttachmentHost(agent: Agent(clients: [AttachmentClient(capabilities: [])]))
        defer { host.window.close() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(try host.buttons("agent-composer-add-attachment").isEmpty)
    }

    private func imageData() throws -> Data {
        let image = NSImage(size: NSSize(width: 48, height: 32), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}

private struct AttachmentClient: AgentClient {
    let id = AgentClientID("attachment-test")
    let displayName = "Test Agent"
    var provider: AgentProvider { .openAICompatible }
    var capabilities: AgentCapabilities = [.attachments]
    func send(_ request: AgentSendRequest) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            continuation.yield(.turnStarted(turnID: request.turnID))
            continuation.yield(.turnEnded(TurnResult()))
            continuation.finish()
        }
    }
    func cancel(turn: UUID) async {}
}

@MainActor
private final class AttachmentHost {
    let view: NSHostingView<AnyView>
    let window: NSWindow
    init(agent: Agent) {
        _ = NSApplication.shared
        view = NSHostingView(rootView: AnyView(AgentChatView(agent: agent).agentToolbar(.hidden)))
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 520, height: 360),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
    }
    var textView: AgentNSTextView? { findTextView(view) }
    private func findTextView(_ view: NSView) -> AgentNSTextView? {
        if let field = view as? AgentNSTextView { return field }
        return view.subviews.lazy.compactMap { self.findTextView($0) }.first
    }
    func buttons(_ identifier: String) throws -> [InspectableView<ViewType.Button>] {
        try view.rootView.inspect().findAll(ViewType.Button.self).filter {
            (try? $0.accessibilityIdentifier()) == identifier
        }
    }
    func press(_ identifier: String) throws {
        try #require(buttons(identifier).first).tap()
    }
    func capture(_ path: String) throws {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(filePath: path))
    }
}

/// The test uses the real paste action while preserving the user's clipboard.
@MainActor
private struct ClipboardBackup {
    let items = (NSPasteboard.general.pasteboardItems ?? []).map { item in
        item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
    func restore() {
        let restored = items.map { item in
            let result = NSPasteboardItem()
            for (type, data) in item { result.setData(data, forType: type) }
            return result
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(restored)
    }
}

@MainActor
private final class AttachmentDrag: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    let draggingDestinationWindow: NSWindow?
    let draggingSourceOperationMask: NSDragOperation = .copy
    let draggingLocation = NSPoint.zero
    let draggedImageLocation = NSPoint.zero
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 3
    let springLoadingHighlight: NSSpringLoadingHighlight = .none
    init(urls: [URL], window: NSWindow) {
        draggingDestinationWindow = window
        super.init()
        draggingPasteboard.writeObjects(urls as [NSURL])
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
#endif
