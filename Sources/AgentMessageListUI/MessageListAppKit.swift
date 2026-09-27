#if os(macOS)
import AppKit
import SwiftUI

struct MessageListRepresentable<Message: MessageListItem, RowContent: View>: NSViewRepresentable {
    let configuration: MessageListEngine<Message>.Configuration
    let rowContent: (Message) -> RowContent

    func makeNSView(context: Context) -> MessageListScrollView<Message, RowContent> {
        MessageListScrollView()
    }

    func updateNSView(_ view: MessageListScrollView<Message, RowContent>, context: Context) {
        view.update(
            configuration: configuration,
            environment: context.environment,
            rowContent: rowContent
        )
    }
}

/// An `NSScrollView` around a single-column `NSTableView` whose cells host
/// SwiftUI rows. Each row reports its own height (measured at the column
/// width); unmeasured rows use an estimate. The last table row is a spacer
/// that ``MessageListEngine`` sizes to the bottom inset plus any space it
/// reserves for the latest turn.
final class MessageListScrollView<Message: MessageListItem, RowContent: View>: NSScrollView,
    NSTableViewDataSource, NSTableViewDelegate, MessageListSurface {
    private typealias Row = MessageListHostedRow<RowContent>
    private typealias Cell = MessageListHostingCell<Row>

    private let tableView = MessageListTableView()
    private let engine = MessageListEngine<Message>()
    private var ids: [Message.ID] = []
    private var messagesByID: [Message.ID: Message] = [:]
    private var measuredHeights: [Message.ID: CGFloat] = [:]
    private var pendingHeightIDs = Set<Message.ID>()
    private var rowContent: ((Message) -> RowContent)?
    private var environment = EnvironmentValues()
    private var tailHeight: CGFloat = 0
    private var isLiveScrolling = false
    private var isApplyingChanges = false

    private static var cellIdentifier: NSUserInterfaceItemIdentifier { .init("message-list-row") }
    private static var tailIdentifier: NSUserInterfaceItemIdentifier { .init("message-list-tail") }

    init() {
        super.init(frame: .zero)

        drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
        horizontalScrollElasticity = .none
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsetsZero

        let column = NSTableColumn(identifier: .init("message"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.focusRingType = .none
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.rowSizeStyle = .custom
        tableView.usesAutomaticRowHeights = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.postsFrameChangedNotifications = true
        documentView = tableView

        contentView.postsBoundsChangedNotifications = true
        contentView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(boundsDidChange), name: NSView.boundsDidChangeNotification, object: contentView)
        center.addObserver(self, selector: #selector(geometryDidChange), name: NSView.frameDidChangeNotification, object: contentView)
        center.addObserver(self, selector: #selector(geometryDidChange), name: NSView.frameDidChangeNotification, object: tableView)
        center.addObserver(self, selector: #selector(willStartLiveScroll), name: NSScrollView.willStartLiveScrollNotification, object: self)
        center.addObserver(self, selector: #selector(didEndLiveScroll), name: NSScrollView.didEndLiveScrollNotification, object: self)

        engine.surface = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Updates

    func update(
        configuration: MessageListEngine<Message>.Configuration,
        environment: EnvironmentValues,
        rowContent: @escaping (Message) -> RowContent
    ) {
        self.environment = environment
        self.rowContent = rowContent

        let messages = configuration.messages
        messagesByID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newIDs = messages.map(\.id)

        isApplyingChanges = true
        if newIDs != ids {
            let preserved = engine.shouldPreserveVisibleRow ? firstVisibleRowPosition() : nil
            applyRowChanges(to: newIDs)
            if let preserved { restore(preserved) }
        }

        // Row content may depend on state outside the message (e.g. a streaming
        // indicator), so refresh every visible row the way SwiftUI would.
        let visible = tableView.rows(in: contentView.documentVisibleRect)
        for row in visible.lowerBound..<min(visible.upperBound, ids.count) {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? Cell,
                  let hostedRow = makeRow(for: ids[row]) else { continue }
            cell.hostingView.rootView = hostedRow
        }
        isApplyingChanges = false

        engine.update(configuration)
    }

    private func applyRowChanges(to newIDs: [Message.ID]) {
        let difference = newIDs.difference(from: ids)
        let changeCount = difference.insertions.count + difference.removals.count
        guard !ids.isEmpty, changeCount < 64 else {
            ids = newIDs
            let live = Set(newIDs)
            measuredHeights = measuredHeights.filter { live.contains($0.key) }
            tableView.reloadData()
            return
        }

        ids = newIDs
        tableView.beginUpdates()
        for change in difference.removals.reversed() {
            if case .remove(let offset, _, _) = change {
                tableView.removeRows(at: IndexSet(integer: offset), withAnimation: [])
            }
        }
        for change in difference.insertions {
            if case .insert(let offset, _, _) = change {
                tableView.insertRows(at: IndexSet(integer: offset), withAnimation: [])
            }
        }
        tableView.endUpdates()
    }

    private func makeRow(for id: Message.ID) -> Row? {
        guard let message = messagesByID[id], let rowContent else { return nil }
        return Row(content: rowContent(message), environment: environment) { [weak self] height in
            self?.rowDidMeasure(id: id, height: height)
        }
    }

    // MARK: Row heights

    private func rowDidMeasure(id: Message.ID, height: CGFloat) {
        let height = max(1, height.rounded(.up))
        guard abs((measuredHeights[id] ?? -1) - height) > 0.5 else { return }
        measuredHeights[id] = height
        let isFirstPending = pendingHeightIDs.isEmpty
        pendingHeightIDs.insert(id)
        guard isFirstPending else { return }
        // Measurements arrive during SwiftUI's layout pass; resize the table
        // rows after it finishes.
        DispatchQueue.main.async { [weak self] in
            self?.flushHeightChanges()
        }
    }

    private func flushHeightChanges() {
        let changedIDs = pendingHeightIDs
        pendingHeightIDs.removeAll()
        let changedRows = IndexSet(ids.indices.filter { changedIDs.contains(ids[$0]) })
        guard !changedRows.isEmpty else { return }
        let preserved = engine.shouldPreserveVisibleRow ? firstVisibleRowPosition() : nil
        isApplyingChanges = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            tableView.noteHeightOfRows(withIndexesChanged: changedRows)
        }
        tableView.tile()
        if let preserved { restore(preserved) }
        isApplyingChanges = false
        engine.layoutDidChange()
    }

    // MARK: Keeping the reader's place

    private struct RowPosition {
        var id: Message.ID
        var offsetFromVisibleTop: CGFloat
    }

    private func firstVisibleRowPosition() -> RowPosition? {
        let top = visibleMinY
        let row = tableView.row(at: NSPoint(x: 0, y: top))
        guard row >= 0, row < ids.count else { return nil }
        return RowPosition(id: ids[row], offsetFromVisibleTop: tableView.rect(ofRow: row).minY - top)
    }

    private func restore(_ position: RowPosition) {
        guard let row = ids.firstIndex(of: position.id) else { return }
        tableView.tile()
        let target = tableView.rect(ofRow: row).minY - position.offsetFromVisibleTop
        guard abs(target - visibleMinY) > 0.5 else { return }
        scroll(toVisibleMinY: target, animated: false)
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        ids.count + 1
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < ids.count else { return max(1, tailHeight) }
        return measuredHeights[ids[row]] ?? MessageListConstants.estimatedRowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < ids.count else {
            if let tail = tableView.makeView(withIdentifier: Self.tailIdentifier, owner: nil) {
                return tail
            }
            let tail = NSView()
            tail.identifier = Self.tailIdentifier
            return tail
        }
        guard let hostedRow = makeRow(for: ids[row]) else { return nil }
        if let cell = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: nil) as? Cell {
            cell.hostingView.rootView = hostedRow
            return cell
        }
        let cell = Cell(rootView: hostedRow)
        cell.identifier = Self.cellIdentifier
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    // MARK: Scroll & geometry notifications

    @objc private func boundsDidChange() {
        engine.didScroll()
    }

    @objc private func geometryDidChange() {
        guard !isApplyingChanges else { return }
        engine.layoutDidChange()
    }

    @objc private func willStartLiveScroll() {
        isLiveScrolling = true
    }

    @objc private func didEndLiveScroll() {
        isLiveScrolling = false
        engine.userScrollDidEnd()
    }

    // MARK: MessageListSurface

    var visibleHeight: CGFloat {
        contentView.bounds.height
    }

    var visibleMinY: CGFloat {
        contentView.bounds.minY
    }

    var maxVisibleMinY: CGFloat {
        max(0, tableView.frame.height - contentView.bounds.height)
    }

    var rowsHeight: CGFloat {
        ids.isEmpty ? 0 : tableView.rect(ofRow: ids.count - 1).maxY
    }

    var isUserScrolling: Bool {
        // A legacy mouse wheel scrolls without live-scroll notifications.
        isLiveScrolling || NSApp?.currentEvent?.type == .scrollWheel
    }

    func rowMinY(at index: Int) -> CGFloat? {
        guard index < ids.count else { return nil }
        return tableView.rect(ofRow: index).minY
    }

    func setTailHeight(_ height: CGFloat) {
        tailHeight = height
        let wasApplying = isApplyingChanges
        isApplyingChanges = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: ids.count))
        }
        tableView.tile()
        isApplyingChanges = wasApplying
    }

    func scroll(toVisibleMinY y: CGFloat, animated: Bool) {
        let target = NSPoint(x: contentView.bounds.minX, y: min(max(0, y), maxVisibleMinY))
        guard animated else {
            contentView.scroll(to: target)
            reflectScrolledClipView(contentView)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MessageListConstants.scrollAnimationSeconds
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            contentView.animator().setBoundsOrigin(target)
            reflectScrolledClipView(contentView)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reflectScrolledClipView(self.contentView)
                self.engine.scrollAnimationDidEnd()
            }
        }
    }
}

extension MessageListScrollView: MessageListDebugView {
    func debugFrameInViewport(ofRowAt index: Int) -> CGRect? {
        guard index < ids.count else { return nil }
        return tableView.rect(ofRow: index).offsetBy(dx: 0, dy: -visibleMinY)
    }

    var debugViewportHeight: CGFloat { visibleHeight }
}

final class MessageListTableView: NSTableView {
    // Rows are chat content, not a selectable list.
    override var acceptsFirstResponder: Bool { false }
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        true
    }
}

final class MessageListHostingCell<Content: View>: NSView {
    let hostingView: NSHostingView<Content>

    init(rootView: Content) {
        hostingView = NSHostingView(rootView: rootView)
        // The row height comes from the table; don't let the hosting view push
        // its own intrinsic size into Auto Layout.
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        super.init(frame: .zero)
        hostingView.frame = bounds
        addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Measures a row at the column width. The height it reports becomes the
/// table row's height.
struct MessageListHostedRow<Content: View>: View {
    let content: Content
    let environment: EnvironmentValues
    let onHeightChange: (CGFloat) -> Void

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                onHeightChange(height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.self, environment)
    }
}
#endif
