import UIKit

/// Audio/roster are independent of visual demand. Preserve automatic PiP startup.
@MainActor
final class MeetingVideoDemand {
    private(set) var foreground = true
    private(set) var floating = false
    private var backgroundGrace = false
    private var grace: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    var onChange: (() -> Void)?
    var wantsVideo: Bool { foreground || floating || backgroundGrace }
    init(observeLifecycle: Bool = true) {
        if observeLifecycle {
            foreground = UIApplication.shared.applicationState != .background
            for (name, visible) in [(UIApplication.didEnterBackgroundNotification, false),
                                    (UIApplication.willEnterForegroundNotification, true)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in MainActor.assumeIsolated { self?.setForeground(visible) }
                })
            }
        }
    }
    func setForeground(_ value: Bool, graceNanoseconds: UInt64 = 3_000_000_000) {
        grace?.cancel(); grace = nil; foreground = value
        backgroundGrace = !value && FloatingVideoPreference.enabled
        onChange?()
        if backgroundGrace {
            grace = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: graceNanoseconds) } catch { return }
                self?.backgroundGrace = false; self?.onChange?()
            }
        }
    }
    func setFloating(_ value: Bool) {
        guard floating != value else { return }
        floating = value
        if !value { backgroundGrace = false }
        onChange?()
    }
    deinit { grace?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }
}
