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
    private let statusChrome = MeetingChromeContainer()
    private let toolsChrome = MeetingChromeContainer()
    private let fit = UIButton(type: .system)
    private let more = UIButton(type: .system)
    private var toolsRect = CGRect.zero
    private var statusRect = CGRect.zero
    private var laidOutSize = CGSize.zero
    private var restoringViewport = false
    private var relativeZoom: CGFloat = 1
    private var readingCenter = CGPoint(x: 0.5, y: 0.5)
    private let initialViewportSize: CGSize
    var onMore: (() -> Void)?
    var moreAnchor: UIButton { more }
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

    init(sourceID: String, sourceName: String, timeout: Duration = .seconds(12), recognition: SharedTextJob.Recognition? = nil, initialScale: CGFloat = 1, initialCenter: CGPoint = CGPoint(x: 0.5, y: 0.5), initialViewportSize: CGSize = .zero, capture: @escaping Capture) {
        self.initialViewportSize = initialViewportSize
        self.timeout = timeout; self.relativeZoom = min(8, max(1, initialScale)); self.readingCenter = initialCenter
        let recognizer = SharedTextRecognizer()
        recognize = recognition ?? { try await recognizer.recognize($0) }
        self.currentSource = sourceID; self.currentName = sourceName; self.capture = capture
        super.init(frame: .zero)
        backgroundColor = .black; accessibilityIdentifier = "Shared text capture"
        imageView.contentMode = .scaleAspectFit; imageView.isUserInteractionEnabled = true
        imageView.addInteraction(interaction); interaction.preferredInteractionTypes = .textSelection
        imageScroll.delegate = self; imageScroll.minimumZoomScale = 1; imageScroll.maximumZoomScale = 8
        imageScroll.contentInsetAdjustmentBehavior = .never
        imageScroll.accessibilityIdentifier = "Captured image viewport"
        imageScroll.addSubview(imageView); addSubview(imageScroll)
        fallback.isEditable = false; fallback.isSelectable = true; fallback.font = .preferredFont(forTextStyle: .body)
        fallback.backgroundColor = .systemBackground; fallback.isHidden = true; addSubview(fallback)
        addSubview(statusChrome); addSubview(toolsChrome)
        status.font = .preferredFont(forTextStyle: .caption1); status.textColor = .label; status.numberOfLines = 3
        status.accessibilityIdentifier = "Captured share status"
        statusChrome.contentView.addSubview(status)
        for button in [close, refresh, fit, more] {
            button.configuration = .plain(); button.configuration?.baseForegroundColor = .label
            button.configuration?.preferredSymbolConfigurationForImage = .init(pointSize: 18, weight: .medium)
            button.configuration?.contentInsets = .init(top: 8, leading: 8, bottom: 8, trailing: 8)
            toolsChrome.contentView.addSubview(button)
        }
        close.configuration?.title = L("Live"); close.configuration?.image = UIImage(systemName: "arrow.left")
        close.configuration?.imagePadding = 5; close.accessibilityLabel = L("Back to Live")
        close.accessibilityIdentifier = "Return to live share"
        close.addAction(UIAction { [weak self] _ in self?.finish() }, for: .touchUpInside)
        refresh.configuration?.image = UIImage(systemName: "arrow.clockwise")
        refresh.accessibilityLabel = L("New frame"); refresh.accessibilityIdentifier = "Capture current shared frame"
        refresh.addAction(UIAction { [weak self] _ in self?.takeFrame() }, for: .touchUpInside)
        fit.accessibilityIdentifier = "Fit captured image"
        fit.addAction(UIAction { [weak self] _ in self?.toggleFit() }, for: .touchUpInside)
        more.configuration?.image = UIImage(systemName: "ellipsis"); more.accessibilityLabel = L("More"); more.accessibilityIdentifier = "Captured share more"
        more.addAction(UIAction { [weak self] _ in self?.onMore?() }, for: .touchUpInside)
        let margin = UITapGestureRecognizer(target: self, action: #selector(tappedMargin(_:)))
        margin.delegate = self; margin.cancelsTouchesInView = false; imageScroll.addGestureRecognizer(margin)
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
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard !restoringViewport else { return }
        centerImage(); rememberViewport(); updateFitControl()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { rememberViewport() }
    private func rememberViewport() {
        guard !restoringViewport, laidOutSize == imageScroll.bounds.size,
              imageScroll.contentSize.width > 0, imageScroll.contentSize.height > 0 else { return }
        relativeZoom = imageScroll.zoomScale
        // A temporarily letterboxed axis must not discard the user's pan position.
        if imageScroll.contentSize.width > imageScroll.bounds.width + 1 {
            readingCenter.x = min(1, max(0, (imageScroll.contentOffset.x + imageScroll.bounds.width / 2) / imageScroll.contentSize.width))
        }
        if imageScroll.contentSize.height > imageScroll.bounds.height + 1 {
            readingCenter.y = min(1, max(0, (imageScroll.contentOffset.y + imageScroll.bounds.height / 2) / imageScroll.contentSize.height))
        }
    }
    private func centerImage() {
        imageScroll.contentInset = UIEdgeInsets(top: max(0, (imageScroll.bounds.height - imageScroll.contentSize.height) / 2),
            left: max(0, (imageScroll.bounds.width - imageScroll.contentSize.width) / 2),
            bottom: max(0, (imageScroll.bounds.height - imageScroll.contentSize.height) / 2),
            right: max(0, (imageScroll.bounds.width - imageScroll.contentSize.width) / 2))
    }
    /// Live renderers aspect-fit pixels inside a canvas-sized view. Convert its
    /// saved center to the actual image before switching to an image-sized document.
    static func imageCenter(from center: CGPoint, viewport: CGSize, image: CGSize) -> CGPoint {
        guard viewport.width > 0, viewport.height > 0, image.width > 0, image.height > 0 else { return center }
        let fit = AVMakeRect(aspectRatio: image, insideRect: CGRect(origin: .zero, size: viewport))
        return CGPoint(x: min(1, max(0, (center.x * viewport.width - fit.minX) / fit.width)),
            y: min(1, max(0, (center.y * viewport.height - fit.minY) / fit.height)))
    }
    private func restoreViewport() {
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0 else { return }
        restoringViewport = true
        imageScroll.frame = bounds
        imageScroll.setZoomScale(1, animated: false)
        imageView.transform = .identity
        imageView.frame = CGRect(origin: .zero, size: AVMakeRect(aspectRatio: image.size, insideRect: bounds).size)
        imageScroll.contentSize = imageView.bounds.size
        imageScroll.setZoomScale(relativeZoom, animated: false)
        centerImage()
        let inset = imageScroll.contentInset, size = imageScroll.contentSize
        imageScroll.contentOffset = CGPoint(
            x: min(max(-inset.left, readingCenter.x * size.width - bounds.width / 2), max(-inset.left, size.width - bounds.width + inset.right)),
            y: min(max(-inset.top, readingCenter.y * size.height - bounds.height / 2), max(-inset.top, size.height - bounds.height + inset.bottom)))
        laidOutSize = bounds.size; restoringViewport = false; updateFitControl()
    }
    /// Parent supplies the existing chrome row in this canvas's coordinates.
    func layoutChrome(status: CGRect, tools: CGRect) {
        statusRect = status; toolsRect = tools; setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if laidOutSize != bounds.size || imageScroll.bounds.size != bounds.size { restoreViewport() }
        imageScroll.frame = bounds; fallback.frame = bounds
        let safe = bounds.inset(by: safeAreaInsets).insetBy(dx: 10, dy: 6)
        let anchor = toolsRect.isEmpty ? CGRect(x: safe.minX, y: safe.maxY - 52, width: safe.width, height: 48) : toolsRect
        let width = min(max(0, safe.width), 264)
        toolsChrome.frame = CGRect(x: min(safe.maxX - width, max(safe.minX, anchor.maxX - width)), y: anchor.minY, width: width, height: 48)
        toolsChrome.layoutIfNeeded()
        let liveWidth = max(44, width - 3 * 44 - 8)
        close.frame = CGRect(x: 4, y: 2, width: liveWidth, height: 44)
        for (index, button) in [refresh, fit, more].enumerated() {
            button.frame = CGRect(x: 4 + liveWidth + CGFloat(index) * 44, y: 2, width: 44, height: 44)
        }
        let header = statusRect.isEmpty ? CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: 64) : statusRect
        let statusWidth = min(max(0, safe.width), min(360, header.width))
        let textHeight = min(90, max(36, status.sizeThatFits(CGSize(width: max(1, statusWidth - 24), height: 100)).height))
        statusChrome.frame = CGRect(x: max(safe.minX, header.minX), y: header.minY, width: statusWidth, height: textHeight + 16)
        statusChrome.layoutIfNeeded(); status.frame = statusChrome.bounds.insetBy(dx: 12, dy: 8)
        fallback.textContainerInset = UIEdgeInsets(top: statusChrome.frame.maxY + 12, left: 16,
            bottom: max(16, bounds.maxY - toolsChrome.frame.minY + 12), right: 16)
    }
    func toggleFit() {
        relativeZoom = relativeZoom > 1.01 ? 1 : min(8, max(2, SharedScreenScale.fill(content: imageView.image?.size ?? .zero, viewport: bounds.size) ?? 2))
        if relativeZoom == 1 { readingCenter = CGPoint(x: 0.5, y: 0.5) }
        restoreViewport()
    }
    private func updateFitControl() {
        let zoomed = relativeZoom > 1.01
        fit.configuration?.image = UIImage(systemName: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        fit.accessibilityLabel = zoomed ? L("Fit shared screen") : L("Zoom in")
    }
    @objc private func tappedMargin(_ gesture: UITapGestureRecognizer) { interaction.resetTextSelection() }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let image = imageView.image else { return false }
        let rect = AVMakeRect(aspectRatio: image.size, insideRect: imageView.bounds)
        let point = touch.location(in: imageView)
        return !rect.contains(point) || (!interaction.hasInteractiveItem(at: point) && !interaction.analysisHasText(at: point))
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
        status.accessibilityValue = analysisStatus; setNeedsLayout()
        refresh.accessibilityLabel = state == .changed ? L("Capture current share") : L("New frame")
        refresh.isEnabled = currentSource != nil && !busy && !SharedTextWorkAdmission.shared.isOccupied
    }
    private func takeFrame() {
        guard !busy, currentSource != nil else { return }
        busy = true; updateStatus(L("Capturing incoming frame…"))
        let request = UUID(); requestID = request
        job = SharedTextJob.start(timeout: timeout, capture: capture, recognize: recognize, onCapture: { [weak self] captured in
            guard let self, self.requestID == request else { return }
            if self.snapshot == nil {
                self.readingCenter = Self.imageCenter(from: self.readingCenter, viewport: self.initialViewportSize,
                    image: CGSize(width: captured.image.width, height: captured.image.height))
            }
            if let previous = self.snapshot, previous.sourceID != captured.sourceID {
                self.relativeZoom = 1; self.readingCenter = CGPoint(x: 0.5, y: 0.5)
            }
            self.snapshot = captured
            self.identity = .init(meeting: self.meeting, snapshot: captured.id)
            self.imageView.image = UIImage(cgImage: captured.image)
            self.laidOutSize = .zero; self.setNeedsLayout(); self.layoutIfNeeded()
            self.interaction.analysis = nil; self.fallback.text = ""; self.fallback.isHidden = true
            self.updateStatus(L("Finding text on this device…"))
        }, onResult: { [weak self] result in
            guard let self, self.requestID == request, let snapshot = self.snapshot,
                  self.identity == .init(meeting: self.meeting, snapshot: snapshot.id) else { return }
            switch result {
            case .native(let analysis):
                self.interaction.analysis = analysis
                if analysis.hasResults(for: .text) {
                    self.analysisStatus = nil
                    self.status.accessibilityHint = L("Touch and hold text to select. Meeting audio continues.")
                    self.updateStatus()
                } else { self.updateStatus(L("No text found. Try a clearer frame or return to Live.")) }
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
