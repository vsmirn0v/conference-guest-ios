import AppKit
import SwiftUI
import Vision
import VisionKit

@MainActor final class NativeDesktopTextFrame: ObservableObject {
    struct Provider {
        let sourceID: String
        let capture: () async -> CGImage?
    }
    var provider: Provider?
}

@MainActor final class NativeDesktopSharedText: ObservableObject {
    @Published private(set) var isOpen = false
    @Published private(set) var snapshot: SharedTextSnapshot?
    @Published private(set) var analysis: ImageAnalysis?
    @Published private(set) var status = ""
    @Published private(set) var transcript = ""
    @Published private(set) var busy = false
    @Published private(set) var statusNeedsAttention = false
    @Published private(set) var liveState = SharedTextLiveState.same
    @Published private var admissionAvailable = !SharedTextWorkAdmission.shared.isOccupied
    private let timeout: Duration
    private let recognize: SharedTextJob.Recognition
    private let meeting = UUID()
    private var identity: SharedTextAnalysisIdentity?
    private var requestID: UUID?
    private var job: SharedTextJob?
    private var admissionObserver: NSObjectProtocol?
    private(set) var sourceID: String?
    private var sourceName = ""
    private var frame: NativeDesktopTextFrame?
    private(set) var initialZoom: CGFloat = 1
    private(set) var initialPan = CGSize.zero
    private(set) var initialViewportSize = CGSize.zero
    var canRefresh: Bool { sourceID != nil && !busy && admissionAvailable && !SharedTextWorkAdmission.shared.isOccupied }

    init(timeout: Duration = .seconds(12), recognition: SharedTextJob.Recognition? = nil) {
        self.timeout = timeout
        // Injected work must not create and discard a real system analyzer.
        if let recognition { recognize = recognition }
        else {
            let recognizer = SharedTextRecognizer()
            recognize = { try await recognizer.recognize($0) }
        }
        admissionObserver = NotificationCenter.default.addObserver(forName: SharedTextWorkAdmission.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.admissionAvailable = !SharedTextWorkAdmission.shared.isOccupied }
        }
    }
    func updateSource(id: String?, name: String, frame: NativeDesktopTextFrame) {
        sourceID = id; sourceName = name; self.frame = frame
        if let snapshot { liveState = .resolve(capturedSource: snapshot.sourceID, currentSource: id) }
    }
    func open(zoom: CGFloat = 1, pan: CGSize = .zero, viewportSize: CGSize = .zero) {
        guard sourceID != nil else { return }
        initialZoom = zoom.isFinite ? min(8, max(1, zoom)) : 1
        initialPan = pan; initialViewportSize = viewportSize
        isOpen = true; refresh()
    }
    func refresh() {
        guard !busy, let sourceID, let frame else { return }
        busy = true; statusNeedsAttention = false; status = L("Capturing incoming frame…")
        let name = sourceName, provider = frame.provider
        let capture = provider?.sourceID == sourceID ? provider?.capture : nil
        let request = UUID(); requestID = request
        job = SharedTextJob.start(timeout: timeout, capture: {
            guard let image = await capture?() else { return nil }
            return SharedTextSnapshot(image: image, sourceID: sourceID, sourceName: name)
        }, recognize: recognize, onCapture: { [weak self] snapshot in
            guard let self, self.requestID == request else { return }
            self.snapshot = snapshot; self.analysis = nil; self.transcript = ""
            self.liveState = .resolve(capturedSource: snapshot.sourceID, currentSource: self.sourceID)
            self.identity = .init(meeting: self.meeting, snapshot: snapshot.id)
            self.status = L("Finding text on this device…")
        }, onResult: { [weak self] result in
            guard let self, self.requestID == request, let snapshot = self.snapshot,
                  self.identity == .init(meeting: self.meeting, snapshot: snapshot.id) else { return }
            switch result {
            case .native(let analysis):
                self.analysis = analysis; self.statusNeedsAttention = !analysis.hasResults(for: .text)
                self.status = analysis.hasResults(for: .text) ? L("Drag to select text. ⌘C to copy. Meeting audio continues.") : L("No text found. Try a clearer frame or return to Live.")
            case .transcript(let text):
                self.transcript = text; self.statusNeedsAttention = text.isEmpty
                self.status = text.isEmpty ? L("No text found. Try a clearer frame or return to Live.") : L("Selectable text · Live Text is unavailable on this device.")
            }
        }, onFailure: { [weak self] failure in
            guard let self, self.requestID == request else { return }
            self.statusNeedsAttention = true
            self.status = failure == .captureUnavailable ? L("No incoming frame available. Try again when the share is visible.") : L("Text recognition failed. Try another frame or return to Live.")
        }, onTimeout: { [weak self] in
            guard let self, self.requestID == request else { return }
            self.identity = nil; self.busy = false; self.statusNeedsAttention = true
            self.status = L("Text recognition is taking too long. Return to Live and try again later.")
        }, onFinished: { [weak self] in
            guard let self, self.requestID == request else { return }
            self.busy = false; self.job = nil
        })
        if job == nil {
            busy = false; statusNeedsAttention = true; status = L("Text recognition is already running. Return to Live and try again later.")
        }
    }
    func close() {
        requestID = nil; job?.cancelUI(); job = nil; identity = nil; snapshot = nil; analysis = nil; transcript = ""
        busy = false; statusNeedsAttention = false; isOpen = false
    }
    deinit { if let admissionObserver { NotificationCenter.default.removeObserver(admissionObserver) } }
}

/// The captured frame is a mode of the meeting canvas. Controls float above the
/// image so the same viewport is available for reading in every window size.
struct NativeDesktopSharedTextView: View {
    @ObservedObject var model: NativeDesktopSharedText
    var meetingTools: AnyView? = nil
    @StateObject private var viewport = NativeDesktopTextViewport()
    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            if !model.transcript.isEmpty {
                ScrollView { Text(model.transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(24) }
                    .background(Color(nsColor: .textBackgroundColor)).foregroundStyle(.primary)
            } else if let snapshot = model.snapshot {
                NativeDesktopAnalyzedImage(snapshot: snapshot, analysis: model.analysis, viewport: viewport,
                    initialZoom: model.initialZoom, initialPan: model.initialPan, initialViewportSize: model.initialViewportSize)
            } else if model.busy { ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity) }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if let snapshot = model.snapshot {
                        Text(model.liveState == .ended ? L("Captured frame · %@'s share ended", snapshot.sourceName) : model.liveState == .changed ? L("Captured frame · A different share is now live") : L("Captured frame · %@", snapshot.sourceName))
                            .font(.callout).lineLimit(1)
                        Text(snapshot.capturedAt, style: .time).font(.caption).foregroundStyle(.secondary)
                    } else { Text(L("Select text")).font(.callout) }
                    if model.busy || model.statusNeedsAttention { Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                }.padding(.horizontal, 14).padding(.vertical, 10).nativeMeetingChrome()
                    .frame(maxWidth: 340, alignment: .leading).help(model.status)
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    Button { model.close() } label: { Label(L("Back to Live"), systemImage: "arrow.left") }
                        .keyboardShortcut(.escape, modifiers: []).help(L("Back to Live"))
                    tool("arrow.clockwise", model.liveState == .changed ? L("Capture current share") : L("New frame")) { model.refresh() }.disabled(!model.canRefresh)
                    tool(viewport.zoom > 1.01 ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", viewport.zoom > 1.01 ? L("Fit to screen") : L("Zoom in")) { viewport.toggleFit() }.disabled(model.snapshot == nil)
                    Divider().frame(height: 22)
                    if let meetingTools { meetingTools }
                    else { Menu { Text(model.status) } label: { Image(systemName: "ellipsis").frame(width: 30, height: 30) }
                        .menuStyle(.borderlessButton).fixedSize().help(L("Select text")) }
                }.buttonStyle(.plain).padding(6).nativeMeetingChrome()
            }.padding(.horizontal, 18).padding(.top, 10)
        }
        .accessibilityIdentifier("Shared text capture")
    }
    private func tool(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 32, height: 32) }.help(label).accessibilityLabel(label)
    }
}

@MainActor final class NativeDesktopTextViewport: ObservableObject {
    @Published private(set) var zoom: CGFloat = 1
    weak var scroll: NativeDesktopTextScroll?
    func changed(_ value: CGFloat) { if abs(zoom - value) > 0.001 { zoom = value } }
    func toggleFit() { scroll?.setRelativeZoom(zoom > 1.01 ? 1 : 2) }
}

struct NativeDesktopAnalyzedImage: NSViewRepresentable {
    let snapshot: SharedTextSnapshot
    let analysis: ImageAnalysis?
    var viewport: NativeDesktopTextViewport? = nil
    var initialZoom: CGFloat = 1
    var initialPan = CGSize.zero
    var initialViewportSize = CGSize.zero
    func makeNSView(context: Context) -> NativeDesktopTextScroll { NativeDesktopTextScroll() }
    func updateNSView(_ scroll: NativeDesktopTextScroll, context: Context) {
        scroll.viewport = viewport; viewport?.scroll = scroll
        scroll.install(snapshot, initialZoom: initialZoom, initialPan: initialPan, initialViewportSize: initialViewportSize)
        if scroll.imageDocument.overlay.analysis !== analysis { scroll.imageDocument.overlay.analysis = analysis }
    }
}

/// The document uses the unzoomed viewport as its fit basis. Its visible center
/// is saved in image coordinates before resizing; the same frame, OCR overlay
/// and relative zoom survive instead of leaving the old offset offscreen.
@MainActor final class NativeDesktopTextScroll: NSScrollView {
    let imageDocument = NativeDesktopTextImage()
    weak var viewport: NativeDesktopTextViewport?
    private var basis = CGSize.zero
    private var pendingCenter: CGPoint?
    private var layingOut = false
    private var restoring = false
    private var desiredCenter: CGPoint?
    private var boundsObserver: NSObjectProtocol?
    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false; hasVerticalScroller = false; hasHorizontalScroller = false
        allowsMagnification = true; minMagnification = 1; maxMagnification = 8
        contentView = NativeDesktopTextClip()
        documentView = imageDocument
        contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.layingOut, !self.restoring, self.pendingCenter == nil else { return }
                self.desiredCenter = self.normalizedImageCenter
            }
        }
    }
    required init?(coder: NSCoder) { nil }
    deinit { if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }
    func install(_ snapshot: SharedTextSnapshot, initialZoom: CGFloat = 1, initialPan: CGSize = .zero, initialViewportSize: CGSize = .zero) {
        guard imageDocument.snapshotID != snapshot.id else { return }
        let first = imageDocument.snapshotID == nil
        let preserve = !first && imageDocument.sourceID == snapshot.sourceID
        let center = preserve ? (desiredCenter ?? normalizedImageCenter) : first ? Self.initialCenter(imageSize: CGSize(width: snapshot.image.width, height: snapshot.image.height), viewportSize: initialViewportSize, zoom: initialZoom, pan: initialPan) : CGPoint(x: 0.5, y: 0.5)
        let zoom = preserve ? magnification : first && initialZoom.isFinite ? initialZoom : 1
        imageDocument.sourceID = snapshot.sourceID
        imageDocument.snapshotID = snapshot.id; imageDocument.overlay.analysis = nil
        imageDocument.image.image = NSImage(cgImage: snapshot.image, size: NSSize(width: snapshot.image.width, height: snapshot.image.height))
        pendingCenter = center; desiredCenter = center
        restoring = true
        magnification = min(maxMagnification, max(minMagnification, zoom))
        restoring = false; needsLayout = true
    }
    static func initialCenter(imageSize: CGSize, viewportSize: CGSize, zoom: CGFloat, pan: CGSize) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0, viewportSize.width > 0, viewportSize.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let scale = min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height) * (zoom.isFinite ? min(8, max(1, zoom)) : 1)
        let width = imageSize.width * scale, height = imageSize.height * scale
        let x = pan.width.isFinite ? min(1, max(-1, pan.width)) : 0
        let y = pan.height.isFinite ? min(1, max(-1, pan.height)) : 0
        return CGPoint(x: 0.5 - x * max(0, width - viewportSize.width) / (2 * width),
                       y: 0.5 + y * max(0, height - viewportSize.height) / (2 * height))
    }
    var normalizedImageCenter: CGPoint {
        let imageRect = imageDocument.imageRect, visible = documentVisibleRect
        guard imageRect.width > 0, imageRect.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: min(1, max(0, (visible.midX - imageRect.minX) / imageRect.width)),
                       y: min(1, max(0, (visible.midY - imageRect.minY) / imageRect.height)))
    }
    override func setFrameSize(_ newSize: NSSize) {
        if !layingOut, frame.size != newSize, basis.width > 0 { pendingCenter = desiredCenter ?? normalizedImageCenter }
        let wasRestoring = restoring; restoring = true
        super.setFrameSize(newSize)
        restoring = wasRestoring
    }
    override func layout() {
        guard !layingOut else { return }
        layingOut = true; defer { layingOut = false }
        let center = pendingCenter ?? desiredCenter ?? normalizedImageCenter
        super.layout()
        let base = contentSize
        guard base.width > 0, base.height > 0 else { return }
        if imageDocument.frame.size != base {
            imageDocument.setFrameSize(base); imageDocument.layoutSubtreeIfNeeded()
        }
        if basis != base || pendingCenter != nil { restore(center: center) }
        basis = base; pendingCenter = nil; desiredCenter = center
        publishZoom()
    }
    func setRelativeZoom(_ value: CGFloat) {
        let center = desiredCenter ?? normalizedImageCenter
        restoring = true
        magnification = min(maxMagnification, max(minMagnification, value))
        restore(center: center); desiredCenter = center
        restoring = false; publishZoom()
    }
    override func magnify(with event: NSEvent) { super.magnify(with: event); desiredCenter = normalizedImageCenter; publishZoom() }
    private func restore(center: CGPoint) {
        let rect = imageDocument.imageRect, size = documentVisibleRect.size
        let point = CGPoint(x: rect.minX + rect.width * center.x, y: rect.minY + rect.height * center.y)
        let proposed = CGRect(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size)
        contentView.scroll(to: contentView.constrainBoundsRect(proposed).origin)
        reflectScrolledClipView(contentView)
    }
    private func publishZoom() {
        // NSView layout can run during a SwiftUI update. Publish on the next
        // turn, and read the current value there so stale work cannot win.
        DispatchQueue.main.async { [weak self] in guard let self else { return }; self.viewport?.changed(self.magnification) }
    }
}

/// Magnified aspect-fit margins are never a scroll destination. Keep the image
/// centered on axes where it is smaller than the visible rect, otherwise bound
/// panning to its actual extent instead of the larger letterboxed document.
@MainActor final class NativeDesktopTextClip: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView as? NativeDesktopTextImage else { return result }
        let image = document.imageRect
        guard image.width > 0, image.height > 0 else { return result }
        result.origin.x = image.width <= result.width ? image.midX - result.width / 2 : min(image.maxX - result.width, max(image.minX, result.minX))
        result.origin.y = image.height <= result.height ? image.midY - result.height / 2 : min(image.maxY - result.height, max(image.minY, result.minY))
        return result
    }
}

@MainActor final class NativeDesktopTextImage: NSView, NSGestureRecognizerDelegate {
    let image = NSImageView()
    let overlay = ImageAnalysisOverlayView()
    var snapshotID: UUID?
    var sourceID: String?
    override init(frame: NSRect) {
        super.init(frame: frame)
        image.imageScaling = .scaleProportionallyUpOrDown; image.imageAlignment = .alignCenter
        image.translatesAutoresizingMaskIntoConstraints = false; addSubview(image)
        overlay.trackingImageView = image; overlay.preferredInteractionTypes = .textSelection
        overlay.translatesAutoresizingMaskIntoConstraints = false; addSubview(overlay)
        let clearSelection = NSClickGestureRecognizer(target: self, action: #selector(clearEmptySelection(_:)))
        clearSelection.delaysPrimaryMouseButtonEvents = false; clearSelection.delegate = self
        addGestureRecognizer(clearSelection)
        NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: leadingAnchor), image.trailingAnchor.constraint(equalTo: trailingAnchor),
            image.topAnchor.constraint(equalTo: topAnchor), image.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor), overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor), overlay.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { nil }
    var imageRect: CGRect {
        guard let size = image.image?.size, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGRect(x: (bounds.width - size.width * scale) / 2, y: (bounds.height - size.height * scale) / 2, width: size.width * scale, height: size.height * scale)
    }
    @objc private func clearEmptySelection(_ recognizer: NSClickGestureRecognizer) {
        let point = recognizer.location(in: overlay)
        if !overlay.hasText(at: point), !overlay.analysisHasText(at: point), !overlay.hasDataDetector(at: point), !overlay.hasSupplementaryInterface(at: point) { overlay.resetSelection() }
    }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return imageRect.contains(point) ? super.hitTest(point) : self
    }
    override func mouseDown(with event: NSEvent) {
        if !imageRect.contains(convert(event.locationInWindow, from: nil)) { overlay.resetSelection() }
        else { super.mouseDown(with: event) }
    }
}
