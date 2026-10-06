import Combine
import UIKit

struct CallSpeaker: Equatable {
    let id: String
    let name: String
    let isLocal: Bool
    var title: String { isLocal ? L("You") : name.isEmpty ? L("Musician") : name }
    var accessibilityLabel: String { L("Speaking: %@", title) }
}

/// Speaker metadata has its own lifetime; it never selects or rebuilds video.
@MainActor
final class ActiveSpeakerStore {
    @Published private(set) var current: CallSpeaker?
    private var candidate: CallSpeaker?
    private(set) var available = true
    private var ended = false
    private var transition: Task<Void, Never>?
    private let delay: UInt64

    init(delay: UInt64 = 350_000_000) { self.delay = delay }

    func update(_ speaker: CallSpeaker?) {
        guard available, !ended, candidate != speaker else { return }
        candidate = speaker
        transition?.cancel(); transition = nil
        guard let speaker else { publish(nil); return }
        if current?.id == speaker.id { publish(speaker); return }
        transition = Task { @MainActor [weak self, delay] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard !Task.isCancelled, let self, self.available, !self.ended, self.candidate == speaker else { return }
            self.publish(speaker)
            self.transition = nil
        }
    }

    func setAvailable(_ value: Bool) {
        guard !ended, available != value else { return }
        available = value
        if !value { clear() }
    }

    func reset() { clear(); ended = false; available = false }
    func end() { ended = true; available = false; clear() }

    private func clear() {
        transition?.cancel(); transition = nil
        candidate = nil
        publish(nil)
    }

    private func publish(_ speaker: CallSpeaker?) {
        if current != speaker { current = speaker }
    }
}

/// A passive, one-line indicator shared by the compact header and PiP.
final class ActiveSpeakerIndicator: UIView {
    private let icon = UIImageView(image: UIImage(systemName: "waveform"))
    private let name = UILabel()
    private var displayed: CallSpeaker?

    init(font: UIFont) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        icon.tintColor = .systemGreen
        icon.contentMode = .scaleAspectFit
        name.font = font
        name.textColor = .white
        name.lineBreakMode = .byTruncatingTail
        addSubview(icon); addSubview(name)
        isHidden = true
    }
    required init?(coder: NSCoder) { nil }

    func setSpeaker(_ speaker: CallSpeaker?) {
        guard displayed != speaker else { return }
        displayed = speaker
        name.text = speaker?.title
        accessibilityLabel = speaker?.accessibilityLabel
        isHidden = speaker == nil
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: ceil(name.intrinsicContentSize.width) + 33, height: 26)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = CGRect(x: 7, y: (bounds.height - 14) / 2, width: 14, height: 14)
        name.frame = CGRect(x: 26, y: 0, width: max(0, bounds.width - 33), height: bounds.height)
    }
}
