import JazzSDKScreenShare
import ReplayKit
import UIKit
import Combine

/// Public screen-share sender; no SDK camera replacement or audio hook.
@MainActor
final class GuestPresenterSender: GuestScreenCapture {
    private var upload: BoundedScreenShareUpload?
    private var stopping: BoundedScreenShareUpload?
    private let preview: LocalSharePreview
    private let onError: (String) -> Void
    private var started = false
    private var retired = false
    private var cadence = OutgoingVideoCadence()
    init(preview: LocalSharePreview, onError: @escaping (String) -> Void) {
        self.preview = preview; self.onError = onError
    }
    deinit { upload?.retire() }
    func start() {
        start(source: .presenter)
    }
    func start(source: LocalSharePreview.Source) {
        guard !started, !retired else { return }
        started = true; cadence = OutgoingVideoCadence()
        let upload = BoundedScreenShareUpload { [weak self] in
            let sender = JazzScreenShare { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, self.started, !self.retired else { return }
                    #if DEBUG
                    print("Presenter sender failed: domain=\((error as NSError).domain), code=\((error as NSError).code), message=\(error.localizedDescription)")
                    #endif
                    self.onError(L("Screen sharing stopped: %@", error.localizedDescription))
                }
            }
            return .init(start: { sender.broadcastStarted(withSetupInfo: nil) },
                         send: { sender.processSampleBuffer($0, with: .video) },
                         finish: { sender.broadcastFinished() })
        }
        self.upload = upload
        upload.start()
        preview.begin(source: source)
    }
    func send(_ sample: CMSampleBuffer, applyCadence: Bool = true, updatePreview: Bool = true) {
        guard started, let upload,
              !applyCadence || cadence.accept(sample, fps: MediaEnergyBudget.shared.sharingFPS) else { return }
        upload.submit(sample)
        if updatePreview, let pixels = CMSampleBufferGetImageBuffer(sample) { preview.accept(pixels) }
    }
    func stop() async {
        if retired { await stopping?.waitUntilStopped(); return }
        started = false; retired = true
        if let upload {
            self.upload = nil; stopping = upload
            upload.retire()
        }
        preview.end()
        await stopping?.waitUntilStopped()
        stopping = nil
    }
}

@MainActor
final class GuestPresenterCamera: PresenterCameraSource {
    private let processor = GuestVideoFrameProcessor()
    private var tap: GuestVideoFrameTap?
    private var observation: AnyCancellable?
    private var energySubscription: AnyCancellable?
    init(streams: GuestStreamViews, onFrame: @escaping (CVPixelBuffer, Int) -> Void) {
        processor.setFrameRate(min(12, MediaEnergyBudget.shared.sharingFPS)); processor.setEnabled(true)
        processor.onSample = { sample, _, rotation in
            if let pixels = CMSampleBufferGetImageBuffer(sample) { onFrame(pixels, rotation) }
        }
        energySubscription = MediaEnergyBudget.shared.$pressure.sink { [weak processor] _ in
            DispatchQueue.main.async { processor?.setFrameRate(min(12, MediaEnergyBudget.shared.sharingFPS)) }
        }
        observation = streams.localCameraChanges.sink { [weak self] in self?.refresh($0) }
    }
    private func refresh(_ source: UIView?) {
        guard let renderer = source else { tap?.invalidate(); tap = nil; processor.setEnabled(false); return }
        guard tap?.matches(renderer) != true else { return }
        tap?.invalidate()
        let generation = processor.replaceSource()
        processor.setEnabled(true)
        tap = GuestVideoFrameTap(view: renderer) { [weak processor] in processor?.submit($0, source: generation) }
    }
    func stop() async {
        observation = nil; energySubscription = nil; tap?.invalidate(); tap = nil
        processor.setEnabled(false)
    }
}
