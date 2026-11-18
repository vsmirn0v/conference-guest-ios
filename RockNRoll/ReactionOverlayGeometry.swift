import CoreGraphics

enum ReactionOverlayGeometry {
    /// Compact headers can overlay the stage. Reactions start below that
    /// occlusion and inside the final tile area, including navigation/strips.
    static func contentRect(stage: CGRect, header: CGRect, headerVisible: Bool) -> CGRect {
        guard !stage.isEmpty else { return .zero }
        let top = headerVisible && stage.intersects(header) ? max(stage.minY, header.maxY) : stage.minY
        return CGRect(x: stage.minX + 8, y: top + 8, width: max(0, stage.width - 16),
                      height: max(0, stage.maxY - top - 16))
    }
}

#if canImport(UIKit)
import ConferenceCore
import UIKit

/// Transient reaction feedback only. No history, replay, taps, or queued events.
@MainActor
final class ReceivedReactionOverlay: UIView {
    private let stack = UIStackView()
    private var rows: [(id: UUID, view: UIView, expiry: Task<Void, Never>)] = []
    private var observer: NSObjectProtocol?
    var suppressed = false { didSet { if suppressed { clear() } } }
    var presentationRect: CGRect = .zero { didSet { if oldValue != presentationRect { setNeedsLayout() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        stack.axis = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        addSubview(stack)
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clear() }
        }
    }

    required init?(coder: NSCoder) { nil }

    private var announcementTask: Task<Void, Never>?
    private var announcementCount = 0

    func show(_ reaction: MeetingReaction, from name: String) {
        guard !suppressed, window != nil, UIApplication.shared.applicationState == .active else { return }
        while rows.count >= 3 { remove(rows[0].id) }
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.text = reaction.emoji + "  " + name
        label.accessibilityIdentifier = "reactions.received." + reaction.rawValue
        let card = UIView()
        card.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        card.layer.cornerRadius = 12
        card.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(label)
        stack.addArrangedSubview(card)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -9),
            card.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor)
        ])
        let id = UUID()
        let expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.remove(id)
        }
        rows.append((id, card, expiry))
        setNeedsLayout()
        if UIAccessibility.isVoiceOverRunning {
            announcementCount += 1
            if announcementTask == nil {
                announcementTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self else { return }
                    let count = self.announcementCount
                    self.announcementCount = 0
                    self.announcementTask = nil
                    guard UIApplication.shared.applicationState == .active, !self.suppressed else { return }
                    UIAccessibility.post(notification: .announcement, argument: L("%ld new reactions, available in Chat", count))
                }
            }
        }
    }

    private func remove(_ id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let row = rows.remove(at: index)
        row.expiry.cancel()
        row.view.removeFromSuperview()
        setNeedsLayout()
    }

    func clear() {
        announcementTask?.cancel()
        announcementTask = nil
        announcementCount = 0
        while let row = rows.first { remove(row.id) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = bounds.intersection(presentationRect)
        guard !area.isNull, !area.isEmpty else { stack.frame = .zero; return }
        let width = min(320, max(0, area.width))
        let height = stack.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        stack.frame = CGRect(x: area.minX, y: area.minY, width: width, height: min(max(0, area.height), height))
        stack.clipsToBounds = true
    }

    deinit {
        announcementTask?.cancel()
        observer.map(NotificationCenter.default.removeObserver)
        rows.forEach { $0.expiry.cancel() }
    }
}
#endif
