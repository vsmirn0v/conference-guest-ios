import AVFoundation
import Combine
import Network
import UIKit

/// Path cost is a restriction, never evidence that a Wi-Fi uplink is excellent.
@MainActor
final class CameraEnvironment: ObservableObject {
    static let shared = CameraEnvironment()
    @Published private(set) var power: CameraQualityPolicy.Power = .unknown
    @Published private(set) var constrained = false
    @Published private(set) var route: String = ""
    private let path = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []
    private init() {
        refreshPower()
        if !ProcessInfo.processInfo.isiOSAppOnMac {
            UIDevice.current.isBatteryMonitoringEnabled = true
            refreshPower()
            observers.append(NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification,
                object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refreshPower() } })
        }
        path.pathUpdateHandler = { [weak self] path in
            let route = path.availableInterfaces.filter { path.usesInterfaceType($0.type) }.map(\.index).sorted().description +
                String(describing: path.status) + String(describing: path.gateways)
            Task { @MainActor [weak self] in
                self?.constrained = path.isConstrained || path.status != .satisfied
                self?.route = route
            }
        }
        path.start(queue: DispatchQueue(label: "dev.vsmirn0v.camera-path"))
    }
    func refreshPower() {
        if ProcessInfo.processInfo.isiOSAppOnMac {
            let value = MacExternalPower.current
            if value != power { power = value }
            return
        }
        let value: CameraQualityPolicy.Power
        switch UIDevice.current.batteryState {
        case .charging, .full: value = .connected
        case .unplugged: value = .battery
        default: value = .unknown
        }
        if value != power { power = value }
    }
    deinit { path.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }
}

struct CameraUplinkSample {
    let identity: String
    let timestamp: Double
    let network: CameraQualityPolicy.Network
    static func classify(limited: Bool, roundTrip: Double?, availableBitrate: Double?, loss: Double?) -> CameraQualityPolicy.Network {
        let rtt = roundTrip.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let bitrate = availableBitrate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let loss = loss.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
        if limited || (rtt.map { $0 > 0.4 } ?? false) || (loss.map { $0 > 0.05 } ?? false) ||
            (bitrate.map { $0 < 600_000 } ?? false) { return .poor }
        if let rtt, let bitrate, rtt <= 0.15, bitrate >= 2_000_000,
           loss.map({ $0 <= 0.02 }) ?? true { return .excellent }
        return rtt != nil || bitrate != nil || loss != nil ? .ordinary : .unknown
    }
}

/// One monitor per camera source. Missing/stale samples cannot qualify an upgrade.
@MainActor
final class CameraQualityMonitor {
    private(set) var profile: CameraQualityPolicy.Profile
    var onChange: ((CameraQualityPolicy.Profile) -> Void)?
    private var policy = CameraQualityPolicy()
    private let environment: CameraEnvironment
    private var subscriptions: Set<AnyCancellable> = []
    private var task: Task<Void, Never>?
    private var evidence = CameraUplinkEvidence()
    private var network: CameraQualityPolicy.Network = .unknown
    init(environment: CameraEnvironment = .shared) {
        self.environment = environment
        route = environment.route
        profile = policy.update(power: environment.power, network: .unknown, pressure: MediaEnergyBudget.shared.pressure,
            constrainedPath: environment.constrained, at: ProcessInfo.processInfo.systemUptime)
        environment.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.refreshEnvironment() }
        }.store(in: &subscriptions)
        MediaEnergyBudget.shared.$pressure.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }.store(in: &subscriptions)
    }
    private var route = ""
    private func refreshEnvironment() {
        if route != environment.route {
            route = environment.route; policy.reset(); network = .unknown
            evidence.reset()
        }
        refresh()
    }
    private func refresh() {
        let next = policy.update(power: environment.power, network: network, pressure: MediaEnergyBudget.shared.pressure,
            constrainedPath: environment.constrained, at: ProcessInfo.processInfo.systemUptime)
        if next != profile { profile = next; onChange?(next) }
    }
    func start(sample: @escaping @MainActor () async -> CameraUplinkSample?) {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                let value = await sample()
                guard !Task.isCancelled, let self else { return }
                self.environment.refreshPower()
                let result = self.evidence.consume(value)
                if result.changed { self.policy.reset(); self.network = .unknown; self.refresh() }
                self.network = result.network
                self.refresh()
            }
        }
    }
    deinit { task?.cancel() }
}

/// Configure before starting capture; runtime support governs older devices.
enum CameraBackgroundAccess {
    @discardableResult static func configure(_ session: AVCaptureSession) -> Bool {
        guard session.isMultitaskingCameraAccessSupported else { return false }
        if !session.isMultitaskingCameraAccessEnabled, !session.isRunning {
            session.isMultitaskingCameraAccessEnabled = true
        }
        return session.isMultitaskingCameraAccessEnabled
    }
}
