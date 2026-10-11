import UIKit

/// One interpretation of signaled microphone state and observed speech, shared
/// by captions, highlights, participant lists and accessibility descriptions.
struct ParticipantAudioState: Equatable {
    let microphoneOn: Bool
    let speaking: Bool

    init(microphoneOn: Bool, speaking: Bool, receptionAvailable: Bool = true) {
        self.microphoneOn = microphoneOn
        self.speaking = microphoneOn && speaking && receptionAvailable
    }
}

/// A passive caption whose microphone status cannot be truncated by the name.
final class ParticipantMediaBadge: UIView {
    private let microphone = UIImageView()
    private let name = UILabel()
    private var participantName = ""
    private var microphoneOn = false
    private var speaking = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityIdentifier = "Participant name"
        backgroundColor = UIColor.black.withAlphaComponent(0.65)
        layer.cornerRadius = 6
        clipsToBounds = true
        microphone.contentMode = .scaleAspectFit
        name.font = .preferredFont(forTextStyle: .caption1)
        name.adjustsFontForContentSizeCategory = true
        name.textColor = .white
        name.lineBreakMode = .byTruncatingTail
        addSubview(microphone)
        addSubview(name)
        update(name: "", microphoneOn: false, speaking: false)
    }
    required init?(coder: NSCoder) { nil }

    func update(name: String, microphoneOn: Bool, speaking: Bool) {
        let speaking = ParticipantAudioState(microphoneOn: microphoneOn, speaking: speaking).speaking
        if participantName != name {
            participantName = name
            self.name.text = name
            accessibilityLabel = name
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
        if microphone.image == nil || self.microphoneOn != microphoneOn || self.speaking != speaking {
            self.microphoneOn = microphoneOn
            self.speaking = speaking
            microphone.image = UIImage(systemName: !microphoneOn ? "mic.slash.fill" : speaking ? "waveform" : "mic.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
            microphone.tintColor = speaking ? .systemGreen : .white
            accessibilityValue = !microphoneOn ? L("Microphone off") : speaking ? L("Speaking") : L("Microphone on")
        }
    }

    func updateMicrophone(on: Bool, speaking: Bool) {
        update(name: participantName, microphoneOn: on, speaking: speaking)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: ceil(name.intrinsicContentSize.width) + 38,
               height: max(24, ceil(name.font.lineHeight) + 8))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        microphone.frame = CGRect(x: rtl ? max(6, bounds.width - 26) : 6,
            y: (bounds.height - 20) / 2, width: 20, height: 20)
        name.frame = CGRect(x: rtl ? 6 : 32, y: 0,
            width: max(0, bounds.width - 38), height: bounds.height)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            name.font = .preferredFont(forTextStyle: .caption1, compatibleWith: traitCollection)
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }
}
