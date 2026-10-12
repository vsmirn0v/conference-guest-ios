import CoreMedia

/// Owns one capture session. Leaving/holding invalidates picker callbacks before
/// stopping capture; a late selection must never start sharing into another room.
@MainActor
protocol GuestScreenCapture: AnyObject {
    func start()
    func stop() async
}

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit

@available(iOS 27.0, *)
@MainActor
final class NativeGuestScreenCapture: NSObject, GuestScreenCapture, PresenterScreenSource {
    private let windowResize = MacScreenCaptureBridge()
    private var stream: SCStream?
    private var upload: GuestPresenterSender?
    private var uploadStarted = false
    private var retirement: Task<Void, Never>?
    private var picking = false
    private var pickerRegistered = false
    private var generation = 0
    private var selectionGeneration = 0
    private var captureSource: LocalSharePreview.Source = .screen
    private var cadence = OutgoingVideoCadence()
    private let onError: (String) -> Void
    private let preview: LocalSharePreview
    private let onFrame: ((CMSampleBuffer) -> Void)?
    private let onEffect: (Bool) -> Void
    private let onSelection: () -> Void
    private let onEnd: (String?) -> Void
    #if DEBUG
    private let deliveryExperiment = OutgoingShareExperiment.configured()
    #endif

    init(preview: LocalSharePreview, onFrame: ((CMSampleBuffer) -> Void)? = nil,
         onEffect: @escaping (Bool) -> Void = { _ in }, onSelection: @escaping () -> Void = {},
         onEnd: @escaping (String?) -> Void = { _ in }, onError: @escaping (String) -> Void) {
        self.preview = preview; self.onFrame = onFrame; self.onEffect = onEffect
        self.onSelection = onSelection; self.onEnd = onEnd; self.onError = onError
    }

    func start() {
        guard !picking, retirement == nil else { return }
        let picker = SCContentSharingPicker.shared
        guard picker.isAvailable, !picker.isActive || pickerRegistered else {
            let message = L("Screen sharing is unavailable. Close any other sharing chooser and try again.")
            onError(message); onEnd(message)
            return
        }
        if stream == nil { generation += 1 }
        picking = true
        if !pickerRegistered { picker.add(self); pickerRegistered = true }
        picker.isActive = true
        picker.present()
    }

    private func releasePicker() {
        picking = false
        guard stream == nil, pickerRegistered else { return }
        pickerRegistered = false
        SCContentSharingPicker.shared.remove(self)
        SCContentSharingPicker.shared.isActive = false
    }

    func stop() async {
        if let retirement { await retirement.value; return }
        guard stream != nil || upload != nil || pickerRegistered || picking else { return }
        #if DEBUG
        if let deliveryExperiment, deliveryExperiment.received > 0 { print(deliveryExperiment.summary) }
        deliveryExperiment?.reset()
        #endif
        generation += 1
        selectionGeneration += 1
        windowResize.invalidateWindowResize()
        let previous = stream
        stream = nil
        let previousUpload = upload
        upload = nil; uploadStarted = false
        releasePicker()
        if onFrame == nil { preview.end() }
        // Stop forwarding frames immediately, before any suspension point.
        let attempt = generation
        let ending = Task { @MainActor [self] in
            await previousUpload?.stop()
            if let previous {
                do { try await previous.stopCapture() }
                catch {
                    if generation == attempt { onError(L("Could not stop screen sharing: %@", error.localizedDescription)) }
                }
                try? previous.removeStreamOutput(self, type: .screen)
            }
        }
        retirement = ending
        await ending.value
        retirement = nil
    }

    private func selected(_ filter: SCContentFilter) async {
        guard picking || stream != nil else { return }
        let attempt = generation
        selectionGeneration += 1
        let selection = selectionGeneration
        windowResize.invalidateWindowResize()
        let source: LocalSharePreview.Source
        switch filter.style {
        case .window: source = .window
        case .application: source = .application
        default: source = .screen
        }
        captureSource = source
        let config = SCStreamConfiguration()
        let content = filter.contentRect.size
        let scale = CGFloat(filter.pointPixelScale)
        let bounded = MacScreenCaptureBridge.outputSize(for: CGSize(width: content.width * scale, height: content.height * scale))
        let size = bounded == .zero ? CGSize(width: 1920, height: 1080) : bounded
        config.width = Int(size.width); config.height = Int(size.height)
        // Meeting microphone/audio remains owned by the call engine.
        config.capturesAudio = false
        if let previous = stream {
            // UIKit's public ScreenCaptureKit surface cannot update an existing
            // filter/configuration. Replace capture, preserving the one sender.
            stream = nil
            try? await previous.stopCapture()
            try? previous.removeStreamOutput(self, type: .screen)
            guard generation == attempt, selectionGeneration == selection else { return }
            onEffect(false)
        }
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        stream = capture
        if ProcessInfo.processInfo.isiOSAppOnMac, filter.style == .window {
            // Public macOS updateConfiguration is unavailable in the UIKit SDK's
            // declarations, but available on the Mac stream through our ABI adapter.
            windowResize.prepareWindowResize(forStream: capture, configuration: config)
        }
        do {
            try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
            if onFrame == nil && upload == nil {
                let sender = GuestPresenterSender(preview: preview) { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.generation == attempt else { return }
                        let retirementGeneration = self.generation + 1
                        await self.stop()
                        guard self.generation == retirementGeneration else { return }
                        self.onError(message)
                    }
                }
                upload = sender
            }
            try await capture.startCapture()
            guard generation == attempt, selectionGeneration == selection else {
                try? await capture.stopCapture()
                return
            }
            releasePicker(); onSelection()
        } catch {
            guard generation == attempt, selectionGeneration == selection else { return }
            await stop()
            let message = L("Could not share screen: %@", error.localizedDescription)
            onError(message); onEnd(message)
        }
    }
}

@available(iOS 27.0, *)
extension NativeGuestScreenCapture: SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                         didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [weak self] in await self?.selected(filter) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in guard let self else { return }
            self.releasePicker(); self.onSelection()
            if self.stream == nil { self.onEnd(nil) } }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.picking else { return }
            self.releasePicker()
            let message = L("Could not open screen sharing: %@", error.localizedDescription)
            self.onError(message); self.onEnd(message)
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        // SCStream delivers samples on the main queue specified above. Do not
        // enqueue unbounded frame Tasks while the encoder/IPC transport is busy.
        MainActor.assumeIsolated {
            guard self.stream === stream, type == .screen, sampleBuffer.isValid,
                  CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
            windowResize.observeWindowSample(sampleBuffer)
            if let onFrame {
                #if DEBUG
                if !uploadStarted, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) {
                    print("Presenter screen source: \(CVPixelBufferGetWidth(pixels))x\(CVPixelBufferGetHeight(pixels)), pts=\(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)")
                    uploadStarted = true
                }
                #endif
                onFrame(sampleBuffer); return
            }
            guard let upload else { return }
            // startCapture returns before the system countdown finishes. Match
            // ReplayKit's broadcastStarted semantics: announce only when pixels
            // are available, rather than publishing an empty stream during setup.
            if !uploadStarted {
                #if DEBUG
                deliveryExperiment?.reset()
                #endif
                uploadStarted = true
                upload.start(source: captureSource)
            }
            #if DEBUG
            if let deliveryExperiment {
                deliveryExperiment.deliver(sampleBuffer,
                    send: { upload.send(sampleBuffer, applyCadence: false, updatePreview: false) },
                    preview: { if let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) { preview.accept(pixels) } })
                return
            }
            #endif
            guard cadence.accept(sampleBuffer, fps: MediaEnergyBudget.shared.sharingFPS) else { return }
            if let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) { preview.accept(pixels) }
            upload.send(sampleBuffer, applyCadence: false, updatePreview: false)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            #if DEBUG
            if let deliveryExperiment, deliveryExperiment.received > 0 { print(deliveryExperiment.summary) }
            deliveryExperiment?.reset()
            #endif
            #if DEBUG
            print("Native screen capture stopped: domain=\((error as NSError).domain), code=\((error as NSError).code), message=\(error.localizedDescription)")
            #endif
            self.stream = nil
            let retirementGeneration = self.generation + 1
            await self.stop()
            guard self.generation == retirementGeneration else { return }
            if (error as NSError).code != SCStreamError.Code.userStopped.rawValue {
                let message = L("Screen sharing stopped: %@", error.localizedDescription)
                self.onError(message); self.onEnd(message)
            } else { self.onEnd(nil) }
        }
    }

    nonisolated func outputVideoEffectDidStart(for stream: SCStream) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }; self.onEffect(true)
        }
    }
    nonisolated func outputVideoEffectDidStop(for stream: SCStream) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }; self.onEffect(false)
        }
    }
}
#endif
