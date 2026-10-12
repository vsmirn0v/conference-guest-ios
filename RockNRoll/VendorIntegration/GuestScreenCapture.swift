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
    private let lifecycle = ScreenCaptureLifecycle()
    private lazy var macPicker: ScreenCapturePickerSession = {
        let session = ScreenCapturePickerSession()
        session.onFilter = { [weak self] filter in
            MainActor.assumeIsolated {
                guard let self, let filter = filter as? SCContentFilter else { return }
                let attempt = self.generation
                Task { @MainActor [weak self] in
                    guard let self, self.generation == attempt else { return }
                    await self.selected(filter)
                }
            }
        }
        session.onCancel = { [weak self] in self?.selectionCancelled() }
        session.onError = { [weak self] error in self?.selectionFailed(error) }
        return session
    }()
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
    private let onSelection: (PresenterScreenSelection) -> Void
    private let onEnd: (String?) -> Void
    #if DEBUG
    private let deliveryExperiment = OutgoingShareExperiment.configured()
    #endif

    init(preview: LocalSharePreview, onFrame: ((CMSampleBuffer) -> Void)? = nil,
         onEffect: @escaping (Bool) -> Void = { _ in }, onSelection: @escaping (PresenterScreenSelection) -> Void = { _ in },
         onEnd: @escaping (String?) -> Void = { _ in }, onError: @escaping (String) -> Void) {
        self.preview = preview; self.onFrame = onFrame; self.onEffect = onEffect
        self.onSelection = onSelection; self.onEnd = onEnd; self.onError = onError
    }

    func start() {
        guard !picking, retirement == nil else { return }
        if ProcessInfo.processInfo.isiOSAppOnMac {
            if stream == nil { generation += 1 }
            picking = true
            pickerRegistered = true; macPicker.stream = stream
            do { try macPicker.present() }
            catch { selectionFailed(error) }
            return
        }
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
        if ProcessInfo.processInfo.isiOSAppOnMac { macPicker.invalidate(); return }
        SCContentSharingPicker.shared.remove(self)
        SCContentSharingPicker.shared.isActive = false
    }

    func stop() async {
        if let retirement { await retirement.value; return }
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
        let ending = Task { @MainActor [self] in
            await previousUpload?.stop()
            if let previous { await retire(previous) }
            await withCheckedContinuation { continuation in
                lifecycle.drain { continuation.resume() }
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
        // Mac defaults are 60 fps/eight surfaces. Our visible preview tops out
        // at 30 fps and outgoing sharing at 15; keep capture bounded accordingly.
        if ProcessInfo.processInfo.isiOSAppOnMac { MacScreenCaptureBridge.configureTiming(config, fps: 30, queueDepth: 3) }
        #if DEBUG
        if ProcessInfo.processInfo.isiOSAppOnMac,
           let fps = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_CAPTURE_FPS"].flatMap(Int.init) {
            let depth = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_CAPTURE_DEPTH"].flatMap(Int.init) ?? 3
            MacScreenCaptureBridge.configureTiming(config, fps: fps, queueDepth: depth)
        }
        #endif
        if let previous = stream {
            // UIKit's public ScreenCaptureKit surface cannot update an existing
            // filter/configuration. Replace capture, preserving the one sender.
            stream = nil
            await retire(previous)
            guard generation == attempt, selectionGeneration == selection else { return }
            onEffect(false)
        }
        onSelection(.selected)
        guard generation == attempt, selectionGeneration == selection else { return }
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        stream = capture
        if ProcessInfo.processInfo.isiOSAppOnMac { macPicker.stream = capture }
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
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lifecycle.startStream(capture, output: self) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            guard generation == attempt, selectionGeneration == selection else { return }
            releasePicker()
        } catch {
            guard generation == attempt, selectionGeneration == selection else { return }
            let retirementGeneration = generation + 1
            await stop()
            guard generation == retirementGeneration else { return }
            let message = L("Could not share screen: %@", error.localizedDescription)
            onError(message); onEnd(message)
        }
    }
    private func retire(_ stream: SCStream) async {
        await withCheckedContinuation { continuation in
            lifecycle.retireStream(stream, output: self) { _ in continuation.resume() }
        }
    }
    private func selectionCancelled() {
        guard picking else { return }
        releasePicker(); onSelection(.cancelled)
        if stream == nil { onEnd(nil) }
    }
    private func selectionFailed(_ error: Error) {
        guard picking else { return }
        releasePicker()
        let message = L("Could not open screen sharing: %@", error.localizedDescription)
        onSelection(.cancelled)
        onError(message); onEnd(message)
    }

}

@available(iOS 27.0, *)
extension NativeGuestScreenCapture: SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                         didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [weak self] in await self?.selected(filter) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in self?.selectionCancelled() }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in self?.selectionFailed(error) }
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
