import JazzSDKScreenShare
import ReplayKit
import UIKit
import Combine

/// Public screen-share sender; no SDK camera replacement or audio hook.
@MainActor
final class GuestPresenterSender: GuestScreenCapture {
    private var upload: JazzScreenShare?
    private let preview: LocalSharePreview
    private var started = false
    private var cadence = OutgoingVideoCadence()
    init(preview: LocalSharePreview, onError: @escaping (String) -> Void) {
        self.preview = preview
        upload = JazzScreenShare { error in
            #if DEBUG
            print("Presenter sender failed: domain=\((error as NSError).domain), code=\((error as NSError).code), message=\(error.localizedDescription)")
            #endif
            Task { @MainActor in onError(L("Screen sharing stopped: %@", error.localizedDescription)) }
        }
    }
    func start() {
        start(source: .presenter)
    }
    func start(source: LocalSharePreview.Source) {
        guard !started else { return }
        started = true; cadence = OutgoingVideoCadence(); preview.begin(source: source)
        upload?.broadcastStarted(withSetupInfo: nil)
    }
    func send(_ sample: CMSampleBuffer) {
        guard started, let upload, cadence.accept(sample, fps: MediaEnergyBudget.shared.sharingFPS) else { return }
        upload.processSampleBuffer(sample, with: .video)
        if let pixels = CMSampleBufferGetImageBuffer(sample) { preview.accept(pixels) }
    }
    func stop() async {
        if started { upload?.broadcastFinished() }
        started = false; upload = nil; preview.end()
    }
}

@MainActor
final class GuestPresenterCamera: PresenterCameraSource {
    private let processor = GuestVideoFrameProcessor()
    private var tap: GuestVideoFrameTap?
    private var observation: AnyCancellable?
    private var energySubscription: AnyCancellable?
    init(streams: GuestStreamViews, onFrame: @escaping (CVPixelBuffer, Int) -> Void) {
        processor.setFrameRate(min(12, MediaEnergyBudget.shared.previewFPS)); processor.setEnabled(true)
        processor.onSample = { sample, _, rotation in
            if let pixels = CMSampleBufferGetImageBuffer(sample) { onFrame(pixels, rotation) }
        }
        energySubscription = MediaEnergyBudget.shared.$pressure.sink { [weak processor] _ in
            DispatchQueue.main.async { processor?.setFrameRate(min(12, MediaEnergyBudget.shared.previewFPS)) }
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
