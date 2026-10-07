import Combine
import Foundation
import UIKit

/// The meeting service owns recording and storage. Requests never imply success.
@MainActor
final class MeetingRecording: ObservableObject {
    enum State: Equatable { case unavailable, available, starting, recording, stopping }
    @Published private(set) var state: State = .unavailable
    @Published private(set) var error: String?
    var start: (() -> Void)?
    var stop: (() -> Void)?
    private var timeout: Task<Void, Never>?
    private var active = true
    var canStart: Bool { active && state == .available && start != nil }
    var canStop: Bool { active && state == .recording && stop != nil }
    var isRecording: Bool { state == .recording || state == .stopping }

    func observe(_ next: State) {
        guard active else { return }
        // An unchanged available snapshot must not cancel an in-flight request.
        if state == .starting && next == .available { return }
        if state == .stopping && next == .recording { return }
        timeout?.cancel(); timeout = nil
        state = next; error = nil
    }

    func requestStart() {
        guard canStart else { return }
        state = .starting; error = nil
        awaitConfirmation(fallback: .available)
        start?()
    }
    func requestStop() {
        guard canStop else { return }
        state = .stopping; error = nil
        awaitConfirmation(fallback: .recording)
        stop?()
    }
    private func awaitConfirmation(fallback: State) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self, self.active else { return }
            self.state = fallback
            self.error = L("The meeting service did not confirm the recording change. Try again.")
        }
    }
    func end() {
        active = false; timeout?.cancel(); timeout = nil
        state = .unavailable; error = nil; start = nil; stop = nil
        // Leaving this client does not stop a room-wide server recording.
    }
    func present(from view: UIView) {
        guard var host = view.window?.rootViewController else { return }
        while let presented = host.presentedViewController { host = presented }
        let panel = UIAlertController(title: L("Recording"),
            message: error ?? (state == .unavailable ? L("Recording is unavailable in this meeting.") :
                L("Recordings are stored by the meeting service. The organizer manages access and downloads on the meeting website.")),
            preferredStyle: .actionSheet)
        if canStart {
            panel.message = L("The meeting service will record participants and shared content. Make sure everyone knows before starting.") + "\n\n" + (panel.message ?? "")
            panel.addAction(UIAlertAction(title: L("Start recording"), style: .default) { [weak self] _ in self?.requestStart() })
        }
        if canStop { panel.addAction(UIAlertAction(title: L("Stop recording"), style: .destructive) { [weak self] _ in self?.requestStop() }) }
        panel.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        panel.popoverPresentationController?.sourceView = view
        panel.popoverPresentationController?.sourceRect = view.bounds
        host.present(panel, animated: true)
    }
}
