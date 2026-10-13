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
    var onRecoveryDemandChanged: ((Bool) -> Void)? { didSet { floating.onRecoveryDemandChanged = onRecoveryDemandChanged } }
    private var background = false
    private var isInBackground: Bool { background || UIApplication.shared.applicationState == .background }
    private var suspended = false
    private var selectedViewport: StreamViewport?
    private weak var selectedRenderer: UIView?
    private var cameraPreview: CameraCapturePreview?
    private var cameraSink: RoomFloatingVideoSink?
    private var frameDelivery: SampleBufferFrameDelivery?
    private var inlineDelivery: SampleBufferFrameDelivery?
    var makeInlineFrameDelivery: ((Bool) -> SampleBufferFrameDelivery?)?
    private var isStageSource = true
    private var isScreenShare = false
    var isMirrored: Bool { selectedViewport?.isCameraMirrored == true }
    var onAvailabilityChanged: ((Bool) -> Void)?
    var rendersSelectedViewport = true
    var wantsInlineFrames = true {
        didSet {
            guard oldValue != wantsInlineFrames else { return }
            refreshInlineDelivery()
            processor.setEnabled(shouldProcessFrames)
            replayShareSnapshot()
            if let cameraPreview {
                if rendersSelectedViewport {
                    if wantsInlineFrames { selectedViewport?.showCameraPreview(cameraPreview) }
                    else { selectedViewport?.clearCorrectedVideo() }
                }
                onInlineCameraPreview?(isStageSource && wantsInlineFrames ? cameraPreview : nil, isMirrored)
            }
        }
    }
    #if DEBUG
    var convertedFramesForTesting: Int { processor.preparedFrameCount }
    var hasPreparedFrameForTesting: Bool { hasFrame }
    var hasSourceForTesting: Bool { floating.hasSourceForTesting }
    var lifecycleForTesting: FloatingVideoController { floating }
    func setFloatingForTesting(_ active: Bool) { active ? willStartFloating() : didStopFloating() }
    #endif
    var onInlineSample: ((CMSampleBuffer, Int) -> Void)?
    var onInlineCameraPreview: ((CameraCapturePreview?, Bool) -> Void)?
    var canShow: Bool { hasFrame && (frameTap != nil || cameraPreview != nil) && !suspended && floating.canShow }

    init(sourceView: UIView, speaker: ActiveSpeakerStore? = nil,
         floatingEnvironment: FloatingVideoController.Environment = .init()) {
        self.sourceView = sourceView
        floating = FloatingVideoController(contentView: content, speaker: speaker, environment: floatingEnvironment)
        video.onCameraPreviewSizeChanged = { [weak floating] size in floating?.preferredSize = size }
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
                self.cameraSink?.setWanted(self.presenting && !self.suspended, fps: MediaEnergyBudget.shared.previewFPS)
                self.processor.setFrameRate(self.presenting ? MediaEnergyBudget.shared.previewFPS : MediaEnergyBudget.shared.inlineFPS)
            }
        }
        processor.onSample = { [weak self] sample, size, rotation in
            guard let self, !self.floating.isEnded, self.frameTap != nil else { return }
            self.video.mirrored = self.isMirrored
            if self.isStageSource && self.wantsInlineFrames && !self.suspended && !self.isInBackground {
                if self.rendersSelectedViewport && self.inlineDelivery == nil { self.selectedViewport?.showCorrectedVideo(sample, rotation: rotation) }
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
        cameraPreview == nil && !floating.isEnded && frameTap != nil && !suspended &&
            (presenting || floating.needsRecoveryFrames && !hasFrame || !isInBackground && (isStageSource && wantsInlineFrames || !hasFrame))
    }

    private func willStartFloating() {
        guard !floating.isEnded, frameTap != nil || cameraPreview != nil, !suspended else { return }
        presenting = true
        frameDelivery?.setActive(true)
        cameraPreview?.setFloatingDemand(true)
        cameraSink?.setWanted(true, fps: MediaEnergyBudget.shared.previewFPS)
        processor.setFrameRate(MediaEnergyBudget.shared.previewFPS)
        processor.setEnabled(shouldProcessFrames)
        replayShareSnapshot()
    }
    private func didStopFloating() {
        presenting = false
        frameDelivery?.setActive(false)
        cameraPreview?.setFloatingDemand(false)
        cameraSink?.setWanted(false, fps: MediaEnergyBudget.shared.previewFPS)
        processor.setFrameRate(MediaEnergyBudget.shared.inlineFPS)
        processor.setEnabled(shouldProcessFrames)
    }

    func select(viewport: StreamViewport?, name: String, isScreenShare: Bool, isStageSource: Bool = true) {
        guard !floating.isEnded else { return }
        self.isStageSource = isStageSource
        self.isScreenShare = isScreenShare
        #if DEBUG
        CameraBackgroundTrace.event("guest-select", ["hasViewport": viewport != nil, "presenting": presenting,
            "rendererChanged": selectedRenderer !== viewport?.rendererView, "hasFrame": hasFrame])
        #endif
        guard let viewport else { clear(); return }
        if selectedViewport !== viewport { selectedViewport?.clearCorrectedVideo() }
        selectedViewport = viewport
        if viewport.isLocalCamera, let capture = GuestCaptureDeviceObserver.cameraPreview() {
            frameTap?.invalidate(); frameTap = nil
            processor.setEnabled(false)
            processor.setFrameDeliveries([])
            if cameraPreview !== capture {
                retireCameraSink()
                cameraPreview = capture; hasFrame = false
                let delivery = video.makeFrameDelivery { [weak self, weak capture] size, rotation in
                    guard let self, self.cameraPreview === capture, !self.suspended, !self.floating.isEnded else { return }
                    self.floating.preferredSize = rotation == 90 || rotation == 270
                        ? CGSize(width: size.height, height: size.width) : size
                    if !self.hasFrame {
                        self.hasFrame = true; self.floating.setSourceView(self.sourceView)
                        self.onAvailabilityChanged?(self.canShow)
                    }
                }
                delivery.setActive(presenting); delivery.setEnabled(!suspended)
                frameDelivery = delivery
                let sink = RoomFloatingVideoSink(backgroundDeliver: { delivery.deliver($0, rotation: $1) })
                cameraSink = sink; capture.frames.add(sink)
            }
            selectedRenderer = viewport.rendererView
            video.mirrored = isMirrored
            cameraSink?.setWanted(presenting, fps: MediaEnergyBudget.shared.previewFPS)
            capture.setFloatingDemand(presenting)
            if rendersSelectedViewport && wantsInlineFrames { viewport.showCameraPreview(capture) }
            onInlineCameraPreview?(isStageSource && wantsInlineFrames ? capture : nil, isMirrored)
            caption.text = name.isEmpty ? nil : "  \(name)  "
            caption.isHidden = name.isEmpty
            onAvailabilityChanged?(canShow)
            return
        }
        if cameraPreview != nil {
            retireCameraSink(); video.clear()
            onInlineCameraPreview?(nil, false)
            selectedRenderer = nil
        }
        if selectedRenderer !== viewport.rendererView || frameTap?.matches(viewport.rendererView) != true {
            viewport.clearCorrectedVideo()
            frameTap?.invalidate()
            frameTap = nil
            frameDelivery?.invalidate(); frameDelivery = nil
            processor.setFrameDeliveries([])
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
            let delivery = video.makeFrameDelivery { [weak self] size, rotation in
                guard let self, !self.floating.isEnded else { return }
                self.video.mirrored = self.isMirrored
                self.floating.preferredSize = rotation == 90 || rotation == 270
                    ? CGSize(width: size.height, height: size.width) : size
                if !self.hasFrame {
                    self.hasFrame = true; self.floating.setSourceView(self.sourceView)
                    self.onAvailabilityChanged?(self.canShow)
                    self.processor.setEnabled(self.shouldProcessFrames)
                }
            }
            delivery.setActive(presenting); delivery.setEnabled(!suspended)
            frameDelivery = delivery
            processor.setMainDeliveryEnabled(onInlineSample != nil)
            processor.setFrameDeliveries([delivery])
            let processor = processor
            frameTap = GuestVideoFrameTap(view: viewport.rendererView) { [weak processor] frame in
                processor?.submit(frame, source: sourceID)
            }
            processor.setEnabled(shouldProcessFrames)
        }
        refreshInlineDelivery()
        caption.text = name.isEmpty ? nil : "  \(name)\(isScreenShare ? L(" · Screen") : "")  "
        caption.isHidden = name.isEmpty
        if hasFrame && frameTap != nil { floating.setSourceView(sourceView) }
        else if !presenting { floating.setSourceView(nil, preservingPresentation: true) }
        processor.setEnabled(shouldProcessFrames)
        replayShareSnapshot()
    }

    private func replayShareSnapshot() {
        if isScreenShare && shouldProcessFrames { frameTap?.replayLatestFrame() }
    }

    private func refreshInlineDelivery() {
        inlineDelivery?.setEnabled(false)
        inlineDelivery = nil
        if cameraPreview == nil, isStageSource, wantsInlineFrames, !suspended,
           !isInBackground {
            inlineDelivery = makeInlineFrameDelivery?(isMirrored)
                ?? (rendersSelectedViewport ? selectedViewport?.makeCorrectedFrameDelivery() : nil)
            inlineDelivery?.setActive(true); inlineDelivery?.setEnabled(true)
        }
        processor.setFrameDeliveries([frameDelivery, inlineDelivery].compactMap { $0 })
        processor.setMainDeliveryEnabled(onInlineSample != nil)
    }

    func start() { if canShow { floating.start() } }
    func bindMicrophoneActivity(_ activity: MicrophoneActivity) { floating.bindMicrophoneActivity(activity) }
    func setMicrophoneStatus(_ status: PiPMicrophoneStatus) { floating.setMicrophoneStatus(status) }
    func refreshPreference() { floating.refreshPreference() }
    func foregrounded() {
        background = false
        floating.foregrounded()
        refreshInlineDelivery()
        processor.setFrameRate(MediaEnergyBudget.shared.inlineFPS)
        processor.setEnabled(shouldProcessFrames)
        replayShareSnapshot()
    }

    func backgrounded() {
        background = true
        inlineDelivery?.setEnabled(false)
        processor.setEnabled(shouldProcessFrames)
    }

    func setSuspended(_ suspended: Bool) {
        guard self.suspended != suspended else { return }
        self.suspended = suspended
        video.setFrameDeliverySuspended(suspended)
        floating.setSuspended(suspended)
        if suspended {
            selectedViewport?.clearCorrectedVideo(); hasFrame = false
            floating.setSourceView(nil, preservingPresentation: true)
            cameraPreview?.setFloatingDemand(false); cameraSink?.setWanted(false, fps: MediaEnergyBudget.shared.previewFPS)
            onInlineCameraPreview?(nil, false)
        } else if let cameraPreview {
            cameraPreview.setFloatingDemand(presenting)
            cameraSink?.prime()
            cameraSink?.setWanted(presenting, fps: MediaEnergyBudget.shared.previewFPS)
            onInlineCameraPreview?(isStageSource && wantsInlineFrames ? cameraPreview : nil, isMirrored)
        }
        refreshInlineDelivery()
        processor.setEnabled(shouldProcessFrames)
        replayShareSnapshot()
        onAvailabilityChanged?(canShow)
    }

    func clear(preservingPresentation: Bool = true) {
        inlineDelivery?.invalidate(); inlineDelivery = nil
        frameDelivery?.invalidate(); frameDelivery = nil
        processor.setFrameDeliveries([])
        selectedViewport?.clearCorrectedVideo()
        floating.setSourceView(nil, preservingPresentation: preservingPresentation)
        processor.setEnabled(false)
        _ = processor.replaceSource()
        frameTap?.invalidate()
        frameTap = nil
        hasFrame = false
        presenting = floating.isPresenting
        selectedViewport = nil
        selectedRenderer = nil
        retireCameraSink()
        onInlineCameraPreview?(nil, false)
        video.clear()
        onAvailabilityChanged?(false)
    }

    private func retireCameraSink() {
        frameDelivery?.invalidate(); frameDelivery = nil
        if let cameraSink { cameraSink.retire(); cameraPreview?.frames.remove(cameraSink) }
        cameraSink = nil; cameraPreview?.setFloatingDemand(false); cameraPreview = nil
    }

    func end() {
        floating.end()
        clear()
    }

}
