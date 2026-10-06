import JazzSDKScreenShare
import ReplayKit
import UIKit

/// Public screen-share sender; no SDK camera replacement or audio hook.
@MainActor
final class GuestPresenterSender: GuestScreenCapture {
    private var upload: JazzScreenShare?
    private let preview: LocalSharePreview
    private var started = false
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
        guard !started else { return }
        started = true; preview.begin(source: .presenter)
        upload?.broadcastStarted(withSetupInfo: nil)
    }
    func send(_ sample: CMSampleBuffer) {
        guard started, let upload else { return }
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
    private let source: () -> UIView?
    private let processor = GuestVideoFrameProcessor()
    private var tap: GuestVideoFrameTap?
    private var timer: Timer?
    init(source: @escaping () -> UIView?, onFrame: @escaping (CVPixelBuffer, Int) -> Void) {
        self.source = source
        processor.setFrameRate(12); processor.setEnabled(true)
        processor.onSample = { sample, _, rotation in
            if let pixels = CMSampleBufferGetImageBuffer(sample) { onFrame(pixels, rotation) }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
    private func refresh() {
        guard let renderer = source() else { tap?.invalidate(); tap = nil; return }
        guard tap?.matches(renderer) != true else { return }
        tap?.invalidate()
        tap = GuestVideoFrameTap(view: renderer) { [weak processor] in processor?.submit($0) }
    }
    func stop() async {
        timer?.invalidate(); timer = nil; tap?.invalidate(); tap = nil
        processor.setEnabled(false)
    }
}
