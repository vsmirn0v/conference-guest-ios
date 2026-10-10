import AVKit
import CoreMedia
import UIKit
import Combine

/// One decoded frame feeds the focused inline tile and floating video through
/// sample-buffer surfaces with the same color interpretation.
@MainActor
final class GuestVideoPictureInPicture {
    private let sourceView: UIView
    private let content = UIView()
    private let caption = UILabel()
    private let video = GuestSampleBufferView()
    private let processor = GuestVideoFrameProcessor()
    private let floating: FloatingVideoController
    private var frameTap: GuestVideoFrameTap?
    private var hasFrame = false
    private var presenting = false
    private var energySubscription: AnyCancellable?
    var onPresentationChanged: ((Bool) -> Void)? { didSet { floating.onPresentationChanged = onPresentationChanged } }
    private var suspended = false
    private var selectedViewport: StreamViewport?
    private weak var selectedRenderer: UIView?
    private var isStageSource = true
    var onAvailabilityChanged: ((Bool) -> Void)?
    var rendersSelectedViewport = true
    var wantsInlineFrames = true {
        didSet { if oldValue != wantsInlineFrames { processor.setEnabled(shouldProcessFrames) } }
    }
    #if DEBUG
    private(set) var convertedFramesForTesting = 0
    var hasPreparedFrameForTesting: Bool { hasFrame }
    var hasSourceForTesting: Bool { floating.hasSourceForTesting }
    func setFloatingForTesting(_ active: Bool) { active ? willStartFloating() : didStopFloating() }
    #endif
    var onInlineSample: ((CMSampleBuffer, Int) -> Void)?
    var canShow: Bool { hasFrame && frameTap != nil && !suspended && floating.canShow }

    init(sourceView: UIView, speaker: ActiveSpeakerStore? = nil) {
        self.sourceView = sourceView
        floating = FloatingVideoController(contentView: content, speaker: speaker)
        content.backgroundColor = .black
        content.accessibilityIdentifier = "Floating video surface"
        video.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(video)
        caption.accessibilityIdentifier = "Floating video source"
        caption.font = .preferredFont(forTextStyle: .caption1)
        caption.textColor = .white
        caption.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        caption.layer.cornerRadius = 5
        caption.clipsToBounds = true
        caption.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(caption)
        NSLayoutConstraint.activate([
            video.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            video.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            video.topAnchor.constraint(equalTo: content.topAnchor),
            video.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            caption.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            caption.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -8)
        ])
        floating.onWillStart = { [weak self] in self?.willStartFloating() }
        floating.onStopped = { [weak self] in self?.didStopFloating() }
        energySubscription = MediaEnergyBudget.shared.$pressure.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.processor.setFrameRate(self.presenting ? MediaEnergyBudget.shared.previewFPS : MediaEnergyBudget.shared.inlineFPS)
            }
        }
        processor.onSample = { [weak self] sample, size, rotation in
            guard let self, !self.floating.isEnded, self.frameTap != nil else { return }
            #if DEBUG
            self.convertedFramesForTesting += 1
            #endif
            if self.presenting || !self.hasFrame { self.video.enqueue(sample, rotation: rotation) }
            if self.isStageSource && self.wantsInlineFrames && !self.suspended && UIApplication.shared.applicationState != .background {
                if self.rendersSelectedViewport { self.selectedViewport?.showCorrectedVideo(sample, rotation: rotation) }
                self.onInlineSample?(sample, rotation)
            }
            self.floating.preferredSize = rotation == 90 || rotation == 270
                ? CGSize(width: size.height, height: size.width) : size
            if !self.hasFrame {
                self.hasFrame = true
                self.floating.setSourceView(self.sourceView)
                self.onAvailabilityChanged?(self.canShow)
            }
            // Gallery needs only a prepared first frame for automatic PiP. Its
            // visible tiles already convert their own frames independently.
            self.processor.setEnabled(self.shouldProcessFrames)
        }
    }

    private var shouldProcessFrames: Bool {
        !floating.isEnded && frameTap != nil && !suspended &&
            (presenting || UIApplication.shared.applicationState != .background && (isStageSource && wantsInlineFrames || !hasFrame))
    }

    private func willStartFloating() {
        guard !floating.isEnded, frameTap != nil, !suspended else { return }
        presenting = true
        processor.setFrameRate(MediaEnergyBudget.shared.previewFPS)
        processor.setEnabled(true)
    }
    private func didStopFloating() {
        presenting = false
        processor.setFrameRate(MediaEnergyBudget.shared.inlineFPS)
        processor.setEnabled(shouldProcessFrames)
    }

    func select(viewport: StreamViewport?, name: String, isScreenShare: Bool, isStageSource: Bool = true) {
        guard !floating.isEnded else { return }
        self.isStageSource = isStageSource
        #if DEBUG
        CameraBackgroundTrace.event("guest-select", ["hasViewport": viewport != nil, "presenting": presenting,
            "rendererChanged": selectedRenderer !== viewport?.rendererView, "hasFrame": hasFrame])
        #endif
        guard let viewport else { clear(); return }
        if selectedViewport !== viewport { selectedViewport?.clearCorrectedVideo() }
        selectedViewport = viewport
        if selectedRenderer !== viewport.rendererView || frameTap?.matches(viewport.rendererView) != true {
            viewport.clearCorrectedVideo()
            frameTap?.invalidate()
            frameTap = nil
            let sourceID = processor.replaceSource()
            processor.setEnabled(false)
            hasFrame = false
            // The SDK may replace a tile while the call is backgrounded. Keep
            // the last displayed frame and the stable PiP anchor until the new
            // renderer supplies a frame, so a layout refresh cannot close PiP.
            if !presenting {
                video.clear()
                hasFrame = false
                onAvailabilityChanged?(false)
            }
            selectedRenderer = viewport.rendererView
            let processor = processor
            frameTap = GuestVideoFrameTap(view: viewport.rendererView) { [weak processor] frame in
                processor?.submit(frame, source: sourceID)
            }
            processor.setEnabled(shouldProcessFrames)
        }
        caption.text = name.isEmpty ? nil : "  \(name)\(isScreenShare ? L(" · Screen") : "")  "
        caption.isHidden = name.isEmpty
        if hasFrame && frameTap != nil { floating.setSourceView(sourceView) }
        else if !presenting { floating.setSourceView(nil) }
        processor.setEnabled(shouldProcessFrames)
    }

    func start() { if canShow { floating.start() } }
    func bindMicrophoneActivity(_ activity: MicrophoneActivity) { floating.bindMicrophoneActivity(activity) }
    func setMicrophoneStatus(_ status: PiPMicrophoneStatus) { floating.setMicrophoneStatus(status) }
    func refreshPreference() { floating.refreshPreference() }
    func foregrounded() {
        floating.foregrounded()
        processor.setFrameRate(MediaEnergyBudget.shared.inlineFPS)
        processor.setEnabled(shouldProcessFrames)
    }

    func backgrounded() {
        if !presenting { processor.setEnabled(false) }
    }

    func setSuspended(_ suspended: Bool) {
        guard self.suspended != suspended else { return }
        self.suspended = suspended
        floating.setSuspended(suspended)
        if suspended { selectedViewport?.clearCorrectedVideo(); hasFrame = false; video.clear() }
        processor.setEnabled(shouldProcessFrames)
        onAvailabilityChanged?(canShow)
    }

    func clear() {
        selectedViewport?.clearCorrectedVideo()
        floating.setSourceView(nil)
        processor.setEnabled(false)
        _ = processor.replaceSource()
        frameTap?.invalidate()
        frameTap = nil
        hasFrame = false
        presenting = false
        selectedViewport = nil
        selectedRenderer = nil
        video.clear()
        onAvailabilityChanged?(false)
    }

    func end() {
        floating.end()
        clear()
    }

}
