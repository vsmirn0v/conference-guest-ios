import ConferenceCore
import SwiftUI
import UIKit

/// Native gestures coordinate dragging with the context menu and cancel button
/// tracking on lift. The trailing star remains a separate tap target.
struct FavoriteRoomRow: UIViewRepresentable {
    let room: RecentRoom
    let presentation: RoomRowPresentation
    let tint: UIColor
    let history: RoomHistoryStore
    let drag: FavoriteDragState
    let onJoin: () -> Void
    let onRename: () -> Void
    let onStar: () -> Void
    let onOriginalName: () -> Void

    func makeUIView(context: Context) -> FavoriteRoomControl { FavoriteRoomControl() }
    func updateUIView(_ view: FavoriteRoomControl, context: Context) { view.configure(self) }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: FavoriteRoomControl, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return uiView.systemLayoutSizeFitting(CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
    }
}

@MainActor
final class FavoriteRoomControl: UIView, UIDragInteractionDelegate, UIDropInteractionDelegate, UIContextMenuInteractionDelegate {
    private final class JoinControl: UIControl {
        var activate: (() -> Bool)?
        override func accessibilityActivate() -> Bool { activate?() ?? false }
    }
    private struct DragToken { let id: UUID; let owner: ObjectIdentifier }
    private let join = JoinControl()
    private let title = UILabel()
    private let subtitle = UILabel()
    private let location = UILabel()
    private let star = UIButton(type: .system)
    private var content: FavoriteRoomRow?
    private var pressedContent: FavoriteRoomRow?
    private var cancelledPress = false
    private var slotHeights: [NSLayoutConstraint] = []
    private lazy var dragInteraction = UIDragInteraction(delegate: self)

    override init(frame: CGRect) {
        super.init(frame: frame)
        for label in [title, subtitle, location] {
            label.adjustsFontForContentSizeCategory = true; label.lineBreakMode = .byTruncatingTail
        }
        subtitle.textColor = .secondaryLabel; location.textColor = .secondaryLabel
        slotHeights = [title, subtitle, location].map { $0.heightAnchor.constraint(equalToConstant: 1) }
        NSLayoutConstraint.activate(slotHeights)
        updateTypography()
        let text = UIStackView(arrangedSubviews: [title, subtitle, location])
        text.axis = .vertical; text.spacing = 3; text.isUserInteractionEnabled = false
        join.addSubview(text)
        let row = UIStackView(arrangedSubviews: [join, star])
        row.alignment = .center; row.spacing = 10
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false; text.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            text.leadingAnchor.constraint(equalTo: join.leadingAnchor), text.trailingAnchor.constraint(equalTo: join.trailingAnchor),
            text.topAnchor.constraint(equalTo: join.topAnchor), text.bottomAnchor.constraint(equalTo: join.bottomAnchor),
            join.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            star.widthAnchor.constraint(equalToConstant: 44), star.heightAnchor.constraint(equalToConstant: 44)
        ])
        join.addTarget(self, action: #selector(joinTapped), for: .touchUpInside)
        join.addTarget(self, action: #selector(joinPressed), for: .touchDown)
        join.addTarget(self, action: #selector(joinCancelled), for: [.touchCancel, .touchUpOutside])
        star.addTarget(self, action: #selector(starTapped), for: .touchUpInside)
        join.isAccessibilityElement = true; join.accessibilityTraits = .button
        join.activate = { [weak self] in
            guard let self, let content = self.content, content.drag.session == nil,
                  content.history.rooms.contains(where: { $0.id == content.room.id }) else { return false }
            content.onJoin(); return true
        }
        join.addInteraction(dragInteraction)
        join.addInteraction(UIContextMenuInteraction(delegate: self))
        addInteraction(UIDropInteraction(delegate: self))
        if #available(iOS 27.0, *) { dragInteraction.allowsPointerDragBeforeLiftDelay = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ content: FavoriteRoomRow) {
        if let pressedContent, pressedContent.room.id != content.room.id { joinCancelled() }
        self.content = content
        title.text = content.presentation.title; subtitle.text = content.presentation.timing
        location.text = content.presentation.location
        star.setImage(UIImage(systemName: "star.fill"), for: .normal); star.tintColor = content.tint
        join.accessibilityLabel = L("Rejoin %@ on %@", content.room.displayTitle,
                                    content.room.invitationURL.host() ?? L("meeting website"))
        join.accessibilityValue = content.presentation.details
        join.accessibilityIdentifier = "favorite.order.\(content.room.id)"
        star.accessibilityLabel = L("Unstar %@", content.room.displayTitle)
        star.isUserInteractionEnabled = content.drag.session == nil
        let favorites = content.history.rooms.filter(\.isStarred)
        dragInteraction.isEnabled = content.drag.session != nil || favorites.count > 1
        join.accessibilityHint = favorites.count > 1 ? L("Touch and hold, then drag to reorder.") : nil
        var actions: [UIAccessibilityCustomAction] = []
        if let index = favorites.firstIndex(where: { $0.id == content.room.id }) {
            if index > 0 { actions.append(UIAccessibilityCustomAction(name: L("Move up")) { [weak self] _ in self?.move(by: -1) ?? false }) }
            if index + 1 < favorites.count { actions.append(UIAccessibilityCustomAction(name: L("Move down")) { [weak self] _ in self?.move(by: 1) ?? false }) }
        }
        join.accessibilityCustomActions = actions
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateTypography(); invalidateIntrinsicContentSize()
        }
    }
    private func updateTypography() {
        let descriptor = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection).fontDescriptor
            .addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]])
        title.font = UIFont(descriptor: descriptor, size: 0)
        subtitle.font = .preferredFont(forTextStyle: .caption1, compatibleWith: traitCollection)
        location.font = subtitle.font
        let lines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 2 : 1
        for (index, label) in [title, subtitle, location].enumerated() {
            label.numberOfLines = lines
            slotHeights[index].constant = ceil(label.font.lineHeight) * CGFloat(lines) + 2
        }
    }
    @objc private func joinPressed() { pressedContent = content; cancelledPress = false }
    @objc private func joinCancelled() { pressedContent = nil; cancelledPress = true }

    @objc private func joinTapped() {
        defer { pressedContent = nil; cancelledPress = false }
        guard !cancelledPress, let content = pressedContent ?? content, content.drag.session == nil,
              content.history.rooms.contains(where: { $0.id == content.room.id }) else { return }
        content.onJoin()
    }
    @objc private func starTapped() {
        guard let content, content.drag.session == nil else { return }
        content.onStar()
    }
    private func move(by offset: Int) -> Bool {
        guard let content else { return false }
        return content.drag.move(content.room.id, by: offset, history: content.history)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard content != nil else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self, let content = self.content else { return nil }
            var actions: [UIMenuElement] = [
                UIAction(title: L("Rename"), image: UIImage(systemName: "pencil")) { _ in content.onRename() },
                UIAction(title: L("Copy invitation"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.url = content.room.joinURL
                }
            ]
            if content.room.alias != nil {
                actions.append(UIAction(title: L("Use original name"), image: UIImage(systemName: "arrow.uturn.backward")) { _ in content.onOriginalName() })
            }
            let favorites = content.history.rooms.filter(\.isStarred)
            if favorites.count > 1 {
                actions.append(UIMenu(options: .displayInline, children: [
                    UIAction(title: L("Move up"), image: UIImage(systemName: "arrow.up"),
                        attributes: favorites.first?.id == content.room.id ? .disabled : []) { [weak self] _ in _ = self?.move(by: -1) },
                    UIAction(title: L("Move down"), image: UIImage(systemName: "arrow.down"),
                        attributes: favorites.last?.id == content.room.id ? .disabled : []) { [weak self] _ in _ = self?.move(by: 1) }
                ]))
            }
            return UIMenu(children: actions)
        }
    }

    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        guard let content, content.drag.session == nil,
              content.history.rooms.filter(\.isStarred).count > 1 else { return [] }
        let token = DragToken(id: UUID(), owner: ObjectIdentifier(content.drag))
        // Only an opaque identifier enters the drag provider; invitations stay local.
        let item = UIDragItem(itemProvider: NSItemProvider(object: token.id.uuidString as NSString))
        item.localObject = token
        return [item]
    }
    func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: UIDragSession) {
        guard let content, let token = session.items.first?.localObject as? DragToken else { return }
        _ = content.drag.begin(sourceID: content.room.id, rooms: content.history.rooms.filter(\.isStarred), token: token.id)
    }
    func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem,
                         session: UIDragSession) -> UITargetedDragPreview? {
        let parameters = UIDragPreviewParameters()
        parameters.backgroundColor = .secondarySystemGroupedBackground
        parameters.visiblePath = UIBezierPath(roundedRect: bounds, cornerRadius: 12)
        return UITargetedDragPreview(view: self, parameters: parameters)
    }
    func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool { true }
    func dragInteraction(_ interaction: UIDragInteraction, prefersFullSizePreviewsFor session: UIDragSession) -> Bool { true }
    func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession, willEndWith operation: UIDropOperation) {
        if operation == .cancel || operation == .forbidden, let token = session.items.first?.localObject as? DragToken {
            content?.drag.cancel(token: token.id)
        }
    }
    func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation) {
        if let token = session.items.first?.localObject as? DragToken { content?.drag.cancel(token: token.id) }
    }

    private func acceptedToken(_ session: UIDropSession) -> DragToken? {
        guard let content, session.localDragSession != nil, session.items.count == 1,
              let token = session.items.first?.localObject as? DragToken,
              token.owner == ObjectIdentifier(content.drag), token.id == content.drag.token else { return nil }
        return token
    }
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool { acceptedToken(session) != nil }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        guard acceptedToken(session) != nil, let content else { return UIDropProposal(operation: .forbidden) }
        content.drag.autoScroll.update(session: session, in: self)
        content.drag.move(relativeTo: content.room.id, before: session.location(in: self).y < bounds.midY)
        let proposal = UIDropProposal(operation: .move)
        proposal.isPrecise = true
        proposal.prefersFullSizePreview = true
        return proposal
    }
    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let token = acceptedToken(session), let content else { return }
        content.drag.drop(token: token.id, history: content.history)
    }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) { content?.drag.autoScroll.stop() }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) { content?.drag.autoScroll.stop() }
}
