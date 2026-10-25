import AVFoundation
import CoreImage
import UIKit
import Vision
import VisionKit

/// Covers only the media stage. Meeting controls and reception remain live.
@MainActor final class SharedTextOverlay: UIView, UIGestureRecognizerDelegate, UIScrollViewDelegate {
    typealias Capture = () async -> SharedTextSnapshot?
    private let imageView = UIImageView()
    private let imageScroll = UIScrollView()
    private let interaction = ImageAnalysisInteraction()
    private let timeout: Duration
    private let recognize: SharedTextJob.Recognition
    private let status = UILabel()
    private let refresh = UIButton(type: .system)
    private let close = UIButton(type: .system)
    private let fallback = UITextView()
    private var job: SharedTextJob?
    private var requestID: UUID?
    private var admissionObserver: NSObjectProtocol?
    private(set) var busy = false
    private let meeting = UUID()
    private var identity: SharedTextAnalysisIdentity?
    private(set) var snapshot: SharedTextSnapshot?
    private var currentSource: String?
    private var currentName = ""
    private var analysisStatus: String?
    private let capture: Capture
    var onClose: (() -> Void)?
    static var available: Bool { true } // Vision supplies a selectable transcript on unsupported hardware.

    init(sourceID: String, sourceName: String, timeout: Duration = .seconds(12), recognition: SharedTextJob.Recognition? = nil, capture: @escaping Capture) {
        self.timeout = timeout
        let recognizer = SharedTextRecognizer()
        recognize = recognition ?? { try await recognizer.recognize($0) }
        self.currentSource = sourceID; self.currentName = sourceName; self.capture = capture
        super.init(frame: .zero)
        backgroundColor = .black; accessibilityIdentifier = "Shared text capture"
        imageView.contentMode = .scaleAspectFit; imageView.isUserInteractionEnabled = true
        imageView.addInteraction(interaction); interaction.preferredInteractionTypes = .textSelection
        imageScroll.delegate = self; imageScroll.minimumZoomScale = 1; imageScroll.maximumZoomScale = 8
        imageScroll.contentInsetAdjustmentBehavior = .never
        imageView.translatesAutoresizingMaskIntoConstraints = false; imageScroll.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: imageScroll.contentLayoutGuide.leadingAnchor), imageView.trailingAnchor.constraint(equalTo: imageScroll.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: imageScroll.contentLayoutGuide.topAnchor), imageView.bottomAnchor.constraint(equalTo: imageScroll.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: imageScroll.frameLayoutGuide.widthAnchor), imageView.heightAnchor.constraint(equalTo: imageScroll.frameLayoutGuide.heightAnchor)
        ])
        fallback.isEditable = false; fallback.isSelectable = true; fallback.font = .preferredFont(forTextStyle: .body)
        fallback.backgroundColor = .secondarySystemBackground; fallback.isHidden = true
        status.font = .preferredFont(forTextStyle: .caption1); status.textColor = .white; status.numberOfLines = 0
        status.accessibilityIdentifier = "Captured share status"
        close.configuration = .tinted(); close.configuration?.title = L("Back to Live")
        close.addAction(UIAction { [weak self] _ in self?.finish() }, for: .touchUpInside)
        refresh.configuration = .tinted(); refresh.configuration?.title = L("New frame")
        refresh.accessibilityIdentifier = "Capture current shared frame"
        refresh.addAction(UIAction { [weak self] _ in self?.takeFrame() }, for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [status, close]); header.spacing = 8; header.alignment = .center
        let footer = UIStackView(arrangedSubviews: [UILabel(), refresh]); footer.spacing = 8
        let layout = UIStackView(arrangedSubviews: [header, imageScroll, footer]); layout.axis = .vertical; layout.spacing = 10
        layout.translatesAutoresizingMaskIntoConstraints = false; addSubview(layout)
        fallback.translatesAutoresizingMaskIntoConstraints = false; addSubview(fallback)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), layout.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            layout.topAnchor.constraint(equalTo: topAnchor, constant: 8), layout.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            close.heightAnchor.constraint(greaterThanOrEqualToConstant: 44), refresh.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            fallback.leadingAnchor.constraint(equalTo: imageScroll.leadingAnchor), fallback.trailingAnchor.constraint(equalTo: imageScroll.trailingAnchor),
            fallback.topAnchor.constraint(equalTo: imageScroll.topAnchor), fallback.bottomAnchor.constraint(equalTo: imageScroll.bottomAnchor)
        ])
        let margin = UITapGestureRecognizer(target: self, action: #selector(tappedMargin(_:)))
        margin.delegate = self; addGestureRecognizer(margin)
        admissionObserver = NotificationCenter.default.addObserver(forName: SharedTextWorkAdmission.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatus() }
        }
        takeFrame()
    }
    required init?(coder: NSCoder) { nil }
    override var keyCommands: [UIKeyCommand]? { [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))] }
    override var canBecomeFirstResponder: Bool { true }
    @objc private func escape() { finish() }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    @objc private func tappedMargin(_ gesture: UITapGestureRecognizer) { finish() }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let image = imageView.image else { return touch.view === self }
        let rect = AVMakeRect(aspectRatio: image.size, insideRect: imageView.bounds)
        return touch.view === imageView && !rect.contains(touch.location(in: imageView))
    }
    func updateSource(id: String?, name: String?) {
        currentSource = id; currentName = name ?? ""; updateStatus()
    }
    private func updateStatus(_ message: String? = nil) {
        if let message { analysisStatus = message }
        let state = snapshot.map { SharedTextLiveState.resolve(capturedSource: $0.sourceID, currentSource: currentSource) } ?? .same
        let name = snapshot?.sourceName ?? currentName
        let captured = state == .ended ? L("Captured frame · %@'s share ended", name) : state == .changed
            ? L("Captured frame · A different share is now live") : L("Captured frame · %@", name)
        let time = snapshot?.capturedAt.formatted(date: .omitted, time: .standard)
        status.text = [captured, time, analysisStatus].compactMap { $0 }.joined(separator: "\n")
        refresh.configuration?.title = state == .changed ? L("Capture current share") : L("New frame")
        refresh.isEnabled = currentSource != nil && !busy && !SharedTextWorkAdmission.shared.isOccupied
    }
    private func takeFrame() {
        guard !busy, currentSource != nil else { return }
        busy = true; updateStatus(L("Capturing incoming frame…"))
        let request = UUID(); requestID = request
        job = SharedTextJob.start(timeout: timeout, capture: capture, recognize: recognize, onCapture: { [weak self] captured in
            guard let self, self.requestID == request else { return }
            self.snapshot = captured
            self.identity = .init(meeting: self.meeting, snapshot: captured.id)
            self.imageView.image = UIImage(cgImage: captured.image)
            self.imageScroll.setZoomScale(1, animated: false); self.imageScroll.setContentOffset(.zero, animated: false)
            self.interaction.analysis = nil; self.fallback.text = ""; self.fallback.isHidden = true
            self.updateStatus(L("Finding text on this device…"))
        }, onResult: { [weak self] result in
            guard let self, self.requestID == request, let snapshot = self.snapshot,
                  self.identity == .init(meeting: self.meeting, snapshot: snapshot.id) else { return }
            switch result {
            case .native(let analysis):
                self.interaction.analysis = analysis
                self.updateStatus(analysis.hasResults(for: .text) ? L("Touch and hold text to select. Meeting audio continues.") : L("No text found. Try a clearer frame or return to Live."))
            case .transcript(let text):
                self.fallback.text = text; self.fallback.isHidden = text.isEmpty
                self.updateStatus(text.isEmpty ? L("No text found. Try a clearer frame or return to Live.") : L("Selectable text · Live Text is unavailable on this device."))
            }
        }, onFailure: { [weak self] failure in
            guard let self, self.requestID == request else { return }
            self.updateStatus(failure == .captureUnavailable ? L("No incoming frame available. Try again when the share is visible.") : L("Text recognition failed. Try another frame or return to Live."))
        }, onTimeout: { [weak self] in
            guard let self, self.requestID == request else { return }
            self.identity = nil; self.busy = false
            self.updateStatus(L("Text recognition is taking too long. Return to Live and try again later."))
        }, onFinished: { [weak self] in
            guard let self, self.requestID == request else { return }
            self.busy = false; self.job = nil; self.updateStatus()
        })
        if job == nil { busy = false; updateStatus(L("Text recognition is already running. Return to Live and try again later.")) }
    }

    func finish() {
        requestID = nil; job?.cancelUI(); job = nil; busy = false; identity = nil; snapshot = nil
        interaction.analysis = nil; imageView.image = nil; fallback.text = ""; analysisStatus = nil
        removeFromSuperview(); onClose?(); onClose = nil
    }
    deinit { if let admissionObserver { NotificationCenter.default.removeObserver(admissionObserver) } }
}

enum SharedTextCapture {
    @MainActor static func make(_ frame: (CMSampleBuffer, Int)?, sourceID: String, name: String, mirrored: Bool = false) async -> SharedTextSnapshot? {
        guard let frame, let pixels = CMSampleBufferGetImageBuffer(frame.0),
              let image = SharedTextImage.oriented(pixels, rotation: frame.1, mirrored: mirrored) else { return nil }
        let result = await Task.detached(priority: .userInitiated) { SharedTextImage.materialize(image) }.value
        guard !Task.isCancelled, let result else { return nil }
        return SharedTextSnapshot(image: result, sourceID: sourceID, sourceName: name)
    }
}
