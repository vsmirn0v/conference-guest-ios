import Combine
import ConferenceCore
import UIKit

/// A transcript viewer over the conference, without changing SDK audio routing.
final class CatchUpPanel: UIView {
    private let title = UILabel()
    private let details = UITextView()
    private let reviewed = UIButton(type: .system)
    private var subscriptions = Set<AnyCancellable>()
    var onClose: (() -> Void)?

    init(store: CatchUpStore) {
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 18
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)
        isHidden = true

        title.text = "Catch up"
        title.font = .preferredFont(forTextStyle: .headline)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)

        let close = UIButton(type: .system)
        close.configuration = .plain()
        close.configuration?.image = UIImage(systemName: "xmark.circle.fill")
        close.accessibilityLabel = "Close catch up"
        close.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)

        let header = UIStackView(arrangedSubviews: [title, close])
        header.axis = .horizontal
        header.alignment = .center
        header.distribution = .equalSpacing

        details.isEditable = false
        details.isSelectable = true
        details.backgroundColor = .clear
        details.font = .preferredFont(forTextStyle: .body)
        details.adjustsFontForContentSizeCategory = true
        details.accessibilityLabel = "Missed jam transcript"

        reviewed.configuration = .tinted()
        reviewed.configuration?.title = "Mark reviewed"
        reviewed.addAction(UIAction { _ in store.markReviewed() }, for: .touchUpInside)

        let column = UIStackView(arrangedSubviews: [header, details, reviewed])
        column.axis = .vertical
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            reviewed.heightAnchor.constraint(greaterThanOrEqualToConstant: 40)
        ])

        Publishers.CombineLatest4(store.$timeline, store.$canViewTranscript,
                                  store.$transcriptionEnabled, store.$persistenceWarning)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] timeline, canView, enabled, warning in
                self?.render(timeline: timeline, canView: canView, enabled: enabled,
                             warning: warning)
            }
            .store(in: &subscriptions)
    }

    required init?(coder: NSCoder) { nil }

    private func render(timeline: CatchUpTimeline, canView: Bool?, enabled: Bool,
                        warning: String?) {
        details.text = CatchUpText.make(timeline: timeline, canView: canView,
                                        enabled: enabled, warning: warning)
        reviewed.isEnabled = timeline.unreadCount > 0
    }
}
