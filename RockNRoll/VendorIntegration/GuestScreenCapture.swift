import JazzSDKScreenShare
import ReplayKit

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
    private var stream: SCStream?
    private var upload: JazzScreenShare?
    private var uploadStarted = false
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
        guard !picking else { return }
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
        #if DEBUG
        if let deliveryExperiment, deliveryExperiment.received > 0 { print(deliveryExperiment.summary) }
        deliveryExperiment?.reset()
        #endif
        generation += 1
        selectionGeneration += 1
        if onFrame == nil { preview.end() }
        let previous = stream
        stream = nil
        releasePicker()
        // Stop forwarding frames immediately, before any suspension point.
        if uploadStarted { upload?.broadcastFinished() }
        uploadStarted = false
        upload = nil
        if let previous {
            do { try await previous.stopCapture() }
            catch { onError(L("Could not stop screen sharing: %@", error.localizedDescription)) }
            try? previous.removeStreamOutput(self, type: .screen)
        }
    }

    private func selected(_ filter: SCContentFilter) async {
        guard picking || stream != nil else { return }
        let attempt = generation
        selectionGeneration += 1
        let selection = selectionGeneration
        let source: LocalSharePreview.Source
        switch filter.style {
        case .window: source = .window
        case .application: source = .application
        default: source = .screen
        }
        captureSource = source
        let config = SCStreamConfiguration()
        let content = filter.contentRect.size
        let aspect = content.height > 0 ? content.width / content.height : 16 / 9
        config.width = aspect >= 1 ? 1920 : max(2, Int(1080 * aspect / 2) * 2)
        config.height = aspect >= 1 ? max(2, Int(1920 / aspect / 2) * 2) : 1080
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
        do {
            try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
            if onFrame == nil && upload == nil {
                let sender = JazzScreenShare { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.generation == attempt else { return }
                        await self.stop()
                        self.onError(L("Screen sharing stopped: %@", error.localizedDescription))
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
                preview.begin(source: captureSource)
                upload.broadcastStarted(withSetupInfo: nil)
            }
            #if DEBUG
            if let deliveryExperiment {
                deliveryExperiment.deliver(sampleBuffer,
                    send: { upload.processSampleBuffer(sampleBuffer, with: .video) },
                    preview: { if let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) { preview.accept(pixels) } })
                return
            }
            #endif
            guard cadence.accept(sampleBuffer, fps: MediaEnergyBudget.shared.sharingFPS) else { return }
            if let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) { preview.accept(pixels) }
            upload.processSampleBuffer(sampleBuffer, with: .video)
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
            self.releasePicker()
            if self.onFrame == nil { self.preview.end() }
            self.generation += 1
            if self.uploadStarted { self.upload?.broadcastFinished() }
            self.uploadStarted = false
            self.upload = nil
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
