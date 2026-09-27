#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import UIKit

struct MessageListRepresentable<Message: MessageListItem, RowContent: View>: UIViewRepresentable {
    let configuration: MessageListEngine<Message>.Configuration
    let rowContent: (Message) -> RowContent

    func makeUIView(context: Context) -> MessageListCollectionView<Message, RowContent> {
        MessageListCollectionView()
    }

    func updateUIView(_ view: MessageListCollectionView<Message, RowContent>, context: Context) {
        view.update(
            configuration: configuration,
            environment: context.environment,
            rowContent: rowContent
        )
    }
}

/// A single-column `UICollectionView` whose cells host SwiftUI rows. Rows
/// self-size through `UIHostingConfiguration`; ``MessageListEngine`` decides
/// where to scroll.
final class MessageListCollectionView<Message: MessageListItem, RowContent: View>: UICollectionView,
    UICollectionViewDelegate, MessageListSurface {
    private let engine = MessageListEngine<Message>()
    private var diffableDataSource: UICollectionViewDiffableDataSource<Int, Message.ID>!
    private var messagesByID: [Message.ID: Message] = [:]
    private var rowContent: ((Message) -> RowContent)?
    private var environment = EnvironmentValues()
    private var lastLayoutSignature: LayoutSignature?

    private struct LayoutSignature: Equatable {
        var contentHeight: CGFloat
        var boundsSize: CGSize
        var adjustedInsets: UIEdgeInsets
    }

    init() {
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .estimated(MessageListConstants.estimatedRowHeight)
        ))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: item.layoutSize, subitems: [item])
        let layout = UICollectionViewCompositionalLayout(section: NSCollectionLayoutSection(group: group))
        super.init(frame: .zero, collectionViewLayout: layout)

        backgroundColor = .clear
        alwaysBounceVertical = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        keyboardDismissMode = .interactive
        delegate = self
        engine.surface = self

        let registration = UICollectionView.CellRegistration<UICollectionViewCell, Message.ID> {
            [unowned self] cell, _, id in
            configure(cell, id: id)
        }
        diffableDataSource = UICollectionViewDiffableDataSource(collectionView: self) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
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
        let ids = messages.map(\.id)
        let oldIDs = diffableDataSource.snapshot().itemIdentifiers

        if ids != oldIDs {
            let preserved = engine.shouldPreserveVisibleRow ? firstVisibleRowPosition() : nil
            var snapshot = NSDiffableDataSourceSnapshot<Int, Message.ID>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids)
            diffableDataSource.apply(snapshot, animatingDifferences: false)
            layoutIfNeeded()
            if let preserved { restore(preserved) }
        }

        // Row content may depend on state outside the message (e.g. a streaming
        // indicator), so refresh every visible row the way SwiftUI would.
        for indexPath in indexPathsForVisibleItems {
            guard let cell = cellForItem(at: indexPath),
                  let id = diffableDataSource.itemIdentifier(for: indexPath) else { continue }
            configure(cell, id: id)
        }
        layoutIfNeeded()

        engine.update(configuration)
    }

    private func configure(_ cell: UICollectionViewCell, id: Message.ID) {
        guard let message = messagesByID[id], let rowContent else { return }
        let environment = environment
        cell.contentConfiguration = UIHostingConfiguration {
            rowContent(message)
                .environment(\.self, environment)
        }
        .margins(.all, 0)
        cell.backgroundConfiguration = .clear()
    }

    // MARK: Keeping the reader's place

    private struct RowPosition {
        var id: Message.ID
        var offsetFromVisibleTop: CGFloat
    }

    private func firstVisibleRowPosition() -> RowPosition? {
        let top = visibleMinY
        let firstVisible = indexPathsForVisibleItems
            .compactMap { indexPath -> (IndexPath, CGRect)? in
                guard let frame = layoutAttributesForItem(at: indexPath)?.frame,
                      frame.maxY > top else { return nil }
                return (indexPath, frame)
            }
            .min { $0.1.minY < $1.1.minY }
        guard let (indexPath, frame) = firstVisible,
              let id = diffableDataSource.itemIdentifier(for: indexPath) else { return nil }
        return RowPosition(id: id, offsetFromVisibleTop: frame.minY - top)
    }

    private func restore(_ position: RowPosition) {
        guard let indexPath = diffableDataSource.indexPath(for: position.id),
              let frame = layoutAttributesForItem(at: indexPath)?.frame else { return }
        let target = min(max(0, frame.minY - position.offsetFromVisibleTop), maxVisibleMinY)
        contentOffset.y = target - adjustedContentInset.top
    }

    // MARK: Layout & scrolling callbacks

    override func layoutSubviews() {
        super.layoutSubviews()
        let signature = LayoutSignature(
            contentHeight: contentSize.height,
            boundsSize: bounds.size,
            adjustedInsets: adjustedContentInset
        )
        guard signature != lastLayoutSignature else { return }
        lastLayoutSignature = signature
        engine.layoutDidChange()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        engine.didScroll()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { engine.userScrollDidEnd() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        engine.userScrollDidEnd()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        engine.scrollAnimationDidEnd()
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        true
    }

    // MARK: MessageListSurface

    /// Safe-area part of the bottom inset (the rest is our tail).
    private var safeAreaBottom: CGFloat {
        adjustedContentInset.bottom - contentInset.bottom
    }

    var visibleHeight: CGFloat {
        max(0, bounds.height - adjustedContentInset.top - safeAreaBottom)
    }

    var visibleMinY: CGFloat {
        contentOffset.y + adjustedContentInset.top
    }

    var maxVisibleMinY: CGFloat {
        max(0, contentSize.height + adjustedContentInset.bottom + adjustedContentInset.top - bounds.height)
    }

    var rowsHeight: CGFloat {
        contentSize.height
    }

    var isUserScrolling: Bool {
        isTracking || isDragging || isDecelerating
    }

    func rowMinY(at index: Int) -> CGFloat? {
        guard index < numberOfItems(inSection: 0) else { return nil }
        return layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame.minY
    }

    func setTailHeight(_ height: CGFloat) {
        contentInset.bottom = height
        verticalScrollIndicatorInsets.bottom = height
    }

    func scroll(toVisibleMinY y: CGFloat, animated: Bool) {
        setContentOffset(CGPoint(x: contentOffset.x, y: y - adjustedContentInset.top), animated: animated)
    }
}

extension MessageListCollectionView: MessageListDebugView {
    func debugFrameInViewport(ofRowAt index: Int) -> CGRect? {
        guard let frame = layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else {
            return nil
        }
        return frame.offsetBy(dx: 0, dy: -visibleMinY)
    }

    var debugViewportHeight: CGFloat { visibleHeight }
}
#endif
