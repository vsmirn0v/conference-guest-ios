import ConferenceCore
import UIKit

/// A compact activity row; reactions never impersonate chat messages.
@MainActor
final class ReactionHistoryRowView: UIStackView {
    private(set) var group: ReactionHistoryGroup
    var onExpansionChanged: (() -> Void)?
    private let title = UILabel()
    private let caption = UILabel()
    private let details = UIStackView()
    private let disclosure = UIButton(type: .system)
    private let header = UIStackView()
    private var detailLabels: [String: UILabel] = [:]
    private var expanded = false

    init(group: ReactionHistoryGroup) {
        self.group = group
        super.init(frame: .zero)
        axis = .vertical; spacing = 6
        isLayoutMarginsRelativeArrangement = true
        directionalLayoutMargins = .init(top: 8, leading: 8, bottom: 8, trailing: 8)
        accessibilityIdentifier = "reaction.group.\(group.id)"
        title.font = .preferredFont(forTextStyle: .subheadline)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = .lightGray; title.numberOfLines = 0
        header.addArrangedSubview(title); header.alignment = .center
        disclosure.tintColor = .lightGray
        disclosure.accessibilityIdentifier = "reaction.details.\(group.id)"
        NSLayoutConstraint.activate([disclosure.widthAnchor.constraint(equalToConstant: 44),
                                     disclosure.heightAnchor.constraint(equalToConstant: 44)])
        disclosure.addAction(UIAction { [weak self] _ in self?.toggleDetails() }, for: .touchUpInside)
        header.addArrangedSubview(disclosure); addArrangedSubview(header)
        caption.font = .preferredFont(forTextStyle: .caption1); caption.adjustsFontForContentSizeCategory = true
        caption.textColor = .lightGray; caption.numberOfLines = 0
        addArrangedSubview(caption)
        details.axis = .vertical; details.spacing = 6; details.isHidden = true
        addArrangedSubview(details)
        update(group)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func name(_ event: MeetingReactionEvent) -> String { event.isOwn ? L("You") : event.displayName ?? L("Participant") }

    func matchesContent(_ other: ReactionHistoryGroup) -> Bool {
        group.events.count == other.events.count && zip(group.events, other.events).allSatisfy {
            $0.id == $1.id && $0.displayName == $1.displayName && $0.delivery == $1.delivery && $0.timestamp == $1.timestamp
        }
    }
    func update(_ group: ReactionHistoryGroup) {
        self.group = group
        let singleIdentity = group.events.allSatisfy {
            $0.participantID == group.events[0].participantID && $0.kind == group.events[0].kind
        }
        if singleIdentity {
            let first = group.events[0]
            title.text = first.kind.emoji + "  " + name(first) + (group.events.count > 1 ? " ×\(group.events.count)" : "")
            title.accessibilityLabel = name(first) + ", " + first.kind.title + ", " + L("%ld reactions", group.events.count)
        } else {
            title.text = MeetingReaction.allCases.compactMap { kind in
                group.reactionCounts[kind].map { kind.emoji + ($0 > 1 ? " ×\($0)" : "") }
            }.joined(separator: "  ")
            title.accessibilityLabel = group.events.map { name($0) + ", " + $0.kind.title }.joined(separator: "; ")
        }
        if group.events.count < 2 {
            expanded = false; details.isHidden = true
            detailLabels.values.forEach { $0.removeFromSuperview() }; detailLabels.removeAll()
        }
        disclosure.isHidden = group.events.count < 2
        disclosure.setImage(UIImage(systemName: expanded ? "chevron.up" : "chevron.down"), for: .normal)
        disclosure.accessibilityLabel = L(expanded ? "Hide reaction details" : "Show reaction details")
        let count = group.events.count > 1 && !singleIdentity ?
            L("%ld reactions", group.events.count) + " · " + L("%ld participants", group.participantCount) + " · " : ""
        let failed = group.events.contains { $0.delivery == .failed } ? " · " + L("Not sent") : ""
        caption.text = count + group.start.formatted(date: .omitted, time: .shortened) + failed
        if expanded { renderDetails() }
    }
    private func renderDetails() {
        for event in group.events {
            let label: UILabel
            if let existing = detailLabels[event.id] { label = existing }
            else {
                label = UILabel(); label.font = .preferredFont(forTextStyle: .caption1)
                label.adjustsFontForContentSizeCategory = true
                label.textColor = .lightGray; label.numberOfLines = 0
                detailLabels[event.id] = label; details.addArrangedSubview(label)
            }
            label.text = event.kind.emoji + "  " + name(event) + " · " +
                event.receivedAt.formatted(date: .omitted, time: .standard) + (event.delivery == .failed ? " · " + L("Not sent") : "")
            label.accessibilityLabel = name(event) + ", " + event.kind.title + ", " + event.receivedAt.formatted(date: .omitted, time: .standard)
        }
        let valid = Set(group.events.map(\.id))
        for (id, label) in detailLabels where !valid.contains(id) { label.removeFromSuperview(); detailLabels.removeValue(forKey: id) }
    }
    private func toggleDetails() {
        expanded.toggle()
        if expanded { renderDetails() }
        details.isHidden = !expanded
        disclosure.setImage(UIImage(systemName: expanded ? "chevron.up" : "chevron.down"), for: .normal)
        disclosure.accessibilityLabel = L(expanded ? "Hide reaction details" : "Show reaction details")
        onExpansionChanged?()
    }
    /// Expanded rows acknowledge only individual visible entries, not offscreen additions.
    func visibleEventIDs(in scroll: UIScrollView) -> [String] {
        let visible = CGRect(origin: scroll.contentOffset, size: scroll.bounds.size)
        func isVisible(_ view: UIView) -> Bool {
            let frame = view.convert(view.bounds, to: scroll)
            return !view.isHidden && frame.height > 0 && frame.intersection(visible).height >= min(16, frame.height)
        }
        if expanded { return group.events.filter { detailLabels[$0.id].map(isVisible) == true }.map(\.id) }
        return isVisible(header) ? group.events.map(\.id) : []
    }
}
