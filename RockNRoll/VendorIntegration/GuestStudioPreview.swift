import UIKit
import Combine

/// A second observer of the existing local SDK renderer. Capture and publishing
/// stay under SDK ownership; observing it does not disturb stage/PiP observers.
@MainActor
final class GuestStudioPreview {
    let view = GuestSampleBufferView()
    private let processor = GuestVideoFrameProcessor()
    private var tap: GuestVideoFrameTap?
    private var observation: AnyCancellable?
    private var energySubscription: AnyCancellable?

    init(streams: GuestStreamViews) {
        processor.setFrameRate(MediaEnergyBudget.shared.previewFPS)
        processor.setEnabled(true)
        processor.onSample = { [weak self] sample, _, rotation in
            self?.view.enqueue(sample, rotation: rotation)
        }
        energySubscription = MediaEnergyBudget.shared.$pressure.sink { [weak processor] _ in
            DispatchQueue.main.async { processor?.setFrameRate(MediaEnergyBudget.shared.previewFPS) }
        }
        observation = streams.localCameraChanges.sink { [weak self] in self?.refresh($0) }
    }

    private func refresh(_ source: UIView?) {
        guard let renderer = source else { tap?.invalidate(); tap = nil; processor.setEnabled(false); view.clear(); return }
        if tap?.matches(renderer) == true { return }
        tap?.invalidate()
        let generation = processor.replaceSource()
        processor.setEnabled(true)
        tap = GuestVideoFrameTap(view: renderer) { [weak processor] in processor?.submit($0, source: generation) }
    }

    func stop() {
        observation = nil; energySubscription = nil
        tap?.invalidate(); tap = nil
        processor.setEnabled(false)
        view.clear()
    }
}
