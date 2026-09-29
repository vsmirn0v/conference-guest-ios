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
final class NativeGuestScreenCapture: NSObject, GuestScreenCapture {
    private var stream: SCStream?
    private var upload: JazzScreenShare?
    private var uploadStarted = false
    private var picking = false
    private var generation = 0
    private let onError: (String) -> Void

    init(onError: @escaping (String) -> Void) { self.onError = onError }

    func start() {
        guard stream == nil, !picking else { return }
        let picker = SCContentSharingPicker.shared
        guard picker.isAvailable, !picker.isActive else {
            onError("Screen sharing is unavailable. Close any other sharing chooser and try again.")
            return
        }
        generation += 1
        picking = true
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    private func releasePicker() {
        guard picking else { return }
        picking = false
        SCContentSharingPicker.shared.remove(self)
        SCContentSharingPicker.shared.isActive = false
    }

    func stop() async {
        generation += 1
        releasePicker()
        let previous = stream
        stream = nil
        // Stop forwarding frames immediately, before any suspension point.
        if uploadStarted { upload?.broadcastFinished() }
        uploadStarted = false
        upload = nil
        if let previous {
            do { try await previous.stopCapture() }
            catch { onError("Could not stop screen sharing: \(error.localizedDescription)") }
            try? previous.removeStreamOutput(self, type: .screen)
        }
    }

    private func selected(_ filter: SCContentFilter) async {
        guard picking, stream == nil else { return }
        let attempt = generation
        let config = SCStreamConfiguration()
        config.width = 1920
        config.height = 1080
        // Meeting microphone/audio remains owned by the call engine.
        config.capturesAudio = false
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        stream = capture
        do {
            try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
            let sender = JazzScreenShare { [weak self] error in
                Task { @MainActor in
                    guard let self, self.generation == attempt else { return }
                    await self.stop()
                    self.onError("Screen sharing stopped: \(error.localizedDescription)")
                }
            }
            upload = sender
            try await capture.startCapture()
            releasePicker()
            if generation != attempt { try? await capture.stopCapture() }
        } catch {
            guard generation == attempt else { return }
            await stop()
            onError("Could not share screen: \(error.localizedDescription)")
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
        Task { @MainActor [weak self] in self?.releasePicker() }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.picking else { return }
            self.releasePicker()
            self.onError("Could not open screen sharing: \(error.localizedDescription)")
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        // SCStream delivers samples on the main queue specified above. Do not
        // enqueue unbounded frame Tasks while the encoder/IPC transport is busy.
        MainActor.assumeIsolated {
            guard self.stream === stream, type == .screen, sampleBuffer.isValid,
                  CMSampleBufferGetImageBuffer(sampleBuffer) != nil, let upload else { return }
            // startCapture returns before the system countdown finishes. Match
            // ReplayKit's broadcastStarted semantics: announce only when pixels
            // are available, rather than publishing an empty stream during setup.
            if !uploadStarted {
                uploadStarted = true
                upload.broadcastStarted(withSetupInfo: nil)
            }
            upload.processSampleBuffer(sampleBuffer, with: .video)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.generation += 1
            if self.uploadStarted { self.upload?.broadcastFinished() }
            self.uploadStarted = false
            self.upload = nil
            if (error as NSError).code != SCStreamError.Code.userStopped.rawValue {
                self.onError("Screen sharing stopped: \(error.localizedDescription)")
            }
        }
    }
}
#endif
