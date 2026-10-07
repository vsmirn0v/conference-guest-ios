import AVFoundation
import Combine
import UIKit

/// A local input meter is evidence of capture, never proof of remote audibility.
@MainActor
final class MicrophoneActivity: ObservableObject {
    @Published private(set) var level: CGFloat = 0
    @Published private(set) var status: PiPMicrophoneStatus = .muted
    @Published private(set) var hasSignal = false
    private var lastSample: TimeInterval = 0
    private var expiry: Timer?

    func setStatus(_ value: PiPMicrophoneStatus) {
        guard value != status else { return }
        status = value
        clear()
    }
    func receive(rms: Float, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard status == .on, rms.isFinite, rms >= 0, time >= lastSample else { return }
        lastSample = time
        let target = CGFloat(Self.normalized(rms: rms))
        level += (target - level) * (target > level ? 0.7 : 0.3)
        if !hasSignal { hasSignal = true }
        if expiry == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if ProcessInfo.processInfo.systemUptime - self.lastSample > 0.65 { self.clear() }
                }
            }
            expiry = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    func clear() {
        if level != 0 { level = 0 }
        if hasSignal { hasSignal = false }
        lastSample = 0
        expiry?.invalidate(); expiry = nil
    }
    static func normalized(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        return min(1, max(0, (20 * log10(rms) + 60) / 60))
    }
    deinit { expiry?.invalidate() }
}

/// Throttle at the source, so audio callbacks cannot flood the main queue.
final class MicrophoneSampleSink: @unchecked Sendable {
    private let lock = NSLock()
    private var last: TimeInterval = 0
    private let deliver: @Sendable (Float) -> Void
    init(deliver: @escaping @Sendable (Float) -> Void) { self.deliver = deliver }
    func receive(_ buffer: AVAudioPCMBuffer) {
        let time = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard time - last >= 0.08 else { lock.unlock(); return }
        last = time; lock.unlock()
        let frames = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return }
        var energy: Double = 0
        if let data = buffer.floatChannelData {
            for channel in 0..<channels { for frame in 0..<frames {
                let v = Double(data[buffer.format.isInterleaved ? 0 : channel][frame * Int(buffer.stride) + (buffer.format.isInterleaved ? channel : 0)])
                energy += v * v
            } }
        } else if let data = buffer.int16ChannelData {
            for channel in 0..<channels { for frame in 0..<frames {
                let v = Double(data[buffer.format.isInterleaved ? 0 : channel][frame * Int(buffer.stride) + (buffer.format.isInterleaved ? channel : 0)]) / 32768
                energy += v * v
            } }
        } else { return }
        deliver(Float(sqrt(energy / Double(frames * channels))))
    }
}

/// Only the glyph's layers change. Meeting layout and decoded video are untouched.
@MainActor
final class MicrophoneActivityView: UIView {
    private let outline = UIImageView()
    private let fill = CAGradientLayer()
    private let maskLayer = CALayer()
    private var observation: AnyCancellable?
    private var level: CGFloat = 0
    private var status: PiPMicrophoneStatus = .muted
    private var hasSignal = false
    private var renderedStatus: PiPMicrophoneStatus?
    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        outline.contentMode = .scaleAspectFit
        addSubview(outline)
        fill.colors = [UIColor(red: 1, green: 0.60, blue: 0.33, alpha: 1).cgColor, UIColor(red: 1, green: 0.93, blue: 0.74, alpha: 1).cgColor]
        fill.startPoint = CGPoint(x: 0.5, y: 1); fill.endPoint = CGPoint(x: 0.5, y: 0)
        layer.addSublayer(fill)
        fill.mask = maskLayer
    }
    required init?(coder: NSCoder) { nil }
    func bind(_ model: MicrophoneActivity) {
        observation = Publishers.CombineLatest3(model.$level, model.$status, model.$hasSignal)
            .sink { [weak self] level, status, hasSignal in
                // Published emits before the model stores the new value.
                // Render the emitted snapshot, including the very first sample.
                guard let self else { return }
                self.level = level; self.status = status; self.hasSignal = hasSignal
                self.render()
            }
    }
    private func render() {
        if renderedStatus != status {
            renderedStatus = status
            let symbol = status == .on ? "mic" : status.symbol
            outline.image = UIImage(systemName: symbol)
            outline.tintColor = status == .on ? UIColor(red: 1, green: 0.60, blue: 0.33, alpha: 1) : .white
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.isHidden = status != .on || !hasSignal
        let h = bounds.height * level
        fill.frame = CGRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)
        maskLayer.frame = CGRect(x: 0, y: -(bounds.height - h), width: bounds.width, height: bounds.height)
        CATransaction.commit()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        outline.frame = bounds
        let image = UIImage(systemName: "mic.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: max(8, bounds.height), weight: .regular))
        maskLayer.contents = image?.cgImage
        maskLayer.contentsGravity = .resizeAspect
        render()
    }
    static func install(on button: AlignedCallButton, model: MicrophoneActivity) {
        button.accessibilityIdentifier = "call.microphone"
        let glyph = MicrophoneActivityView()
        glyph.bind(model)
        button.setSymbolContent(glyph)
    }
}
