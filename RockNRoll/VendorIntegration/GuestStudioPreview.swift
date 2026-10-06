import UIKit

/// A second observer of the existing local SDK renderer. Capture and publishing
/// stay under SDK ownership; observing it does not disturb stage/PiP observers.
@MainActor
final class GuestStudioPreview {
    let view = GuestSampleBufferView()
    private let source: () -> UIView?
    private let processor = GuestVideoFrameProcessor()
    private var tap: GuestVideoFrameTap?
    private var timer: Timer?

    init(source: @escaping () -> UIView?) {
        self.source = source
        processor.setFrameRate(15)
        processor.setEnabled(true)
        processor.onSample = { [weak self] sample, _, rotation in
            self?.view.enqueue(sample, rotation: rotation)
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        guard let renderer = source() else { tap?.invalidate(); tap = nil; view.clear(); return }
        if tap?.matches(renderer) == true { return }
        tap?.invalidate()
        tap = GuestVideoFrameTap(view: renderer) { [weak processor] in processor?.submit($0) }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        tap?.invalidate(); tap = nil
        processor.setEnabled(false)
        view.clear()
    }
}
