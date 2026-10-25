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
    var canRefresh: Bool { sourceID != nil && !busy && admissionAvailable && !SharedTextWorkAdmission.shared.isOccupied }

    init(timeout: Duration = .seconds(12), recognition: SharedTextJob.Recognition? = nil) {
        self.timeout = timeout
        let recognizer = SharedTextRecognizer()
        recognize = recognition ?? { try await recognizer.recognize($0) }
        admissionObserver = NotificationCenter.default.addObserver(forName: SharedTextWorkAdmission.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.admissionAvailable = !SharedTextWorkAdmission.shared.isOccupied }
        }
    }
    func updateSource(id: String?, name: String, frame: NativeDesktopTextFrame) {
        sourceID = id; sourceName = name; self.frame = frame
        if let snapshot { liveState = .resolve(capturedSource: snapshot.sourceID, currentSource: id) }
    }
    func open() { guard sourceID != nil else { return }; isOpen = true; refresh() }
    func refresh() {
        guard !busy, let sourceID, let frame else { return }
        busy = true; status = L("Capturing incoming frame…")
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
                self.analysis = analysis
                self.status = analysis.hasResults(for: .text) ? L("Drag to select text. ⌘C to copy. Meeting audio continues.") : L("No text found. Try a clearer frame or return to Live.")
            case .transcript(let text):
                self.transcript = text
                self.status = text.isEmpty ? L("No text found. Try a clearer frame or return to Live.") : L("Selectable text · Live Text is unavailable on this device.")
            }
        }, onFailure: { [weak self] failure in
            guard let self, self.requestID == request else { return }
            self.status = failure == .captureUnavailable ? L("No incoming frame available. Try again when the share is visible.") : L("Text recognition failed. Try another frame or return to Live.")
        }, onTimeout: { [weak self] in
            guard let self, self.requestID == request else { return }
            self.identity = nil; self.busy = false
            self.status = L("Text recognition is taking too long. Return to Live and try again later.")
        }, onFinished: { [weak self] in
            guard let self, self.requestID == request else { return }
            self.busy = false; self.job = nil
        })
        if job == nil {
            busy = false; status = L("Text recognition is already running. Return to Live and try again later.")
        }
    }
    func close() {
        requestID = nil; job?.cancelUI(); job = nil; identity = nil; snapshot = nil; analysis = nil; transcript = ""
        busy = false; isOpen = false
    }
    deinit { if let admissionObserver { NotificationCenter.default.removeObserver(admissionObserver) } }
}

struct NativeDesktopSharedTextView: View {
    @ObservedObject var model: NativeDesktopSharedText
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Label(L("Select text"), systemImage: "text.viewfinder")
                    if let snapshot = model.snapshot {
                        Text(model.liveState == .ended ? L("Captured frame · %@'s share ended", snapshot.sourceName) : model.liveState == .changed ? L("Captured frame · A different share is now live") : L("Captured frame · %@", snapshot.sourceName)).font(.caption).foregroundStyle(.secondary)
                        Text(snapshot.capturedAt, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(L("Back to Live")) { model.close() }.keyboardShortcut(.escape, modifiers: [])
            }
            if !model.transcript.isEmpty {
                ScrollView { Text(model.transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
            } else if let snapshot = model.snapshot {
                NativeDesktopAnalyzedImage(snapshot: snapshot, analysis: model.analysis, onMargin: { model.close() })
            } else { Spacer(); if model.busy { ProgressView() }; Spacer() }
            HStack {
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(model.liveState == .changed ? L("Capture current share") : L("New frame")) { model.refresh() }.disabled(!model.canRefresh)
            }
        }.padding(14).background(Color.black).foregroundStyle(.white)
        .accessibilityIdentifier("Shared text capture")
    }
}

struct NativeDesktopAnalyzedImage: NSViewRepresentable {
    let snapshot: SharedTextSnapshot
    let analysis: ImageAnalysis?
    let onMargin: () -> Void
    func makeNSView(context: Context) -> NativeDesktopTextScroll {
        let view = NativeDesktopTextScroll(); view.imageDocument.onMargin = onMargin; return view
    }
    func updateNSView(_ scroll: NativeDesktopTextScroll, context: Context) {
        let view = scroll.imageDocument
        if view.snapshotID != snapshot.id {
            view.snapshotID = snapshot.id; view.overlay.analysis = nil
            view.image.image = NSImage(cgImage: snapshot.image, size: NSSize(width: snapshot.image.width, height: snapshot.image.height))
            scroll.magnification = 1
        }
        view.overlay.analysis = analysis
        view.onMargin = onMargin
    }
}

@MainActor final class NativeDesktopTextScroll: NSScrollView {
    let imageDocument = NativeDesktopTextImage()
    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false; hasVerticalScroller = true; hasHorizontalScroller = true; autohidesScrollers = true
        allowsMagnification = true; minMagnification = 1; maxMagnification = 8
        documentView = imageDocument
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        let base = contentSize
        if imageDocument.frame.size != base { imageDocument.setFrameSize(base) }
    }
}

@MainActor final class NativeDesktopTextImage: NSView {
    let image = NSImageView()
    let overlay = ImageAnalysisOverlayView()
    var snapshotID: UUID?
    var onMargin: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        image.imageScaling = .scaleProportionallyUpOrDown; image.imageAlignment = .alignCenter
        image.translatesAutoresizingMaskIntoConstraints = false; addSubview(image)
        overlay.trackingImageView = image; overlay.preferredInteractionTypes = .textSelection
        overlay.translatesAutoresizingMaskIntoConstraints = false; addSubview(overlay)
        NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: leadingAnchor), image.trailingAnchor.constraint(equalTo: trailingAnchor),
            image.topAnchor.constraint(equalTo: topAnchor), image.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor), overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor), overlay.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { nil }
    private var imageRect: CGRect {
        guard let size = image.image?.size, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGRect(x: (bounds.width - size.width * scale) / 2, y: (bounds.height - size.height * scale) / 2, width: size.width * scale, height: size.height * scale)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return imageRect.contains(point) ? super.hitTest(point) : self
    }
    override func mouseDown(with event: NSEvent) {
        if !imageRect.contains(convert(event.locationInWindow, from: nil)) { onMargin?() }
        else { super.mouseDown(with: event) }
    }
}
