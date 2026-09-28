import UIKit

enum PiPMicrophoneStatus: CaseIterable {
    case muted, on, unavailable

    var title: String {
        switch self {
        case .muted: return "You · Muted"
        case .on: return "You · Mic on"
        case .unavailable: return "You · Mic unavailable"
        }
    }

    var symbol: String {
        switch self {
        case .muted: return "mic.slash.fill"
        case .on: return "mic.fill"
        case .unavailable: return "exclamationmark.triangle.fill"
        }
    }
}

/// Status is composited above the video, never burned into decoded frames.
/// It can update even when a shared screen stops producing new frames.
@MainActor
final class FloatingVideoContentView: UIView {
    private let videoContent: UIView
    private let badge = UIView()
    private let icon = UIImageView()
    private let label = UILabel()
    private(set) var microphoneStatus: PiPMicrophoneStatus = .unavailable

    init(videoContent: UIView) {
        self.videoContent = videoContent
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        addSubview(videoContent)
        badge.backgroundColor = UIColor(white: 0.08, alpha: 0.9)
        badge.layer.cornerRadius = 7
        badge.isUserInteractionEnabled = false
        badge.isAccessibilityElement = true
        badge.accessibilityTraits = .staticText
        badge.accessibilityIdentifier = "Floating microphone status"
        badge.accessibilityLabel = "Your microphone"
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = .init(pointSize: 12, weight: .semibold)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.addSubview(icon)
        badge.addSubview(label)
        addSubview(badge)
        renderStatus()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setMicrophoneStatus(_ status: PiPMicrophoneStatus) {
        guard status != microphoneStatus else { return }
        microphoneStatus = status
        renderStatus()
    }

    private func renderStatus() {
        icon.image = UIImage(systemName: microphoneStatus.symbol)
        let color: UIColor
        switch microphoneStatus {
        case .muted: color = .white
        case .on: color = UIColor(red: 1, green: 0.60, blue: 0.33, alpha: 1)
        case .unavailable: color = UIColor(white: 0.8, alpha: 1)
        }
        icon.tintColor = color
        label.textColor = color
        switch microphoneStatus {
        case .muted: badge.accessibilityValue = "Muted"
        case .on: badge.accessibilityValue = "On"
        case .unavailable: badge.accessibilityValue = "Unavailable"
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        videoContent.frame = bounds
        let inset: CGFloat = bounds.width < 200 ? 6 : 8
        let available = max(0, bounds.width - 2 * inset)
        let fullTitle = microphoneStatus.title
        let fullWidth = (fullTitle as NSString).size(withAttributes: [.font: label.font!]).width
        // Leave most of a small PiP window clear; retain "You" to distinguish
        // the local microphone from the participant whose video is displayed.
        label.text = fullWidth + 33 <= available * 0.72 ? fullTitle : "You"
        let textSize = label.sizeThatFits(CGSize(width: available, height: 24))
        let width = min(available, ceil(textSize.width) + 33)
        let height: CGFloat = 26
        badge.frame = CGRect(x: inset, y: max(0, bounds.height - inset - height),
                             width: width, height: height)
        icon.frame = CGRect(x: 7, y: 6, width: 14, height: 14)
        label.frame = CGRect(x: 26, y: 0, width: max(0, width - 33), height: height)
    }
}
