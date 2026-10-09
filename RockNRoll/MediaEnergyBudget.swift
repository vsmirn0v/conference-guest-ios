import Combine
import Foundation

/// Visual capture/rendering adapts to power/thermal pressure. Audio never depends on it.
@MainActor
final class MediaEnergyBudget: ObservableObject {
    enum Pressure: Int { case normal, constrained, severe }
    static let shared = MediaEnergyBudget()
    @Published private(set) var pressure: Pressure = .normal
    var previewFPS: Int { pressure == .normal ? 15 : pressure == .constrained ? 10 : 5 }
    var inlineFPS: Int { pressure == .normal ? 30 : pressure == .constrained ? 20 : 15 }
    var thumbnailInterval: TimeInterval { pressure == .normal ? 0.5 : pressure == .constrained ? 1 : 2 }
    var cameraFPS: Int { pressure == .normal ? 30 : pressure == .constrained ? 15 : 10 }
    var sharingFPS: Int { pressure == .normal ? 15 : pressure == .constrained ? 10 : 5 }
    private var observers: [NSObjectProtocol] = []
    private var recovery: Task<Void, Never>?
    private let recoveryDelay: UInt64
    init(observeSystem: Bool = true, recoveryDelay: UInt64 = 5_000_000_000) {
        self.recoveryDelay = recoveryDelay
        if observeSystem {
            update(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState)
            for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in MainActor.assumeIsolated {
                        self?.update(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState)
                    }
                })
            }
        }
    }
    func update(lowPower: Bool, thermal: ProcessInfo.ThermalState) {
        let value: Pressure = thermal == .critical ? .severe : (lowPower || thermal == .serious ? .constrained : .normal)
        recovery?.cancel(); recovery = nil
        guard value != pressure else { return }
        if value.rawValue > pressure.rawValue { pressure = value; return }
        recovery = Task { [weak self, recoveryDelay] in
            do { try await Task.sleep(nanoseconds: recoveryDelay) } catch { return }
            self?.pressure = value
        }
    }
    deinit { recovery?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }
}
