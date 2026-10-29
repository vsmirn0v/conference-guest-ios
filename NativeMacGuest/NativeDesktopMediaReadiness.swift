import Foundation
import IOKit.ps

enum NativeDesktopMediaReadinessMode: String, CaseIterable {
    case off, whenPluggedIn, alsoOnBattery
    var title: String {
        switch self {
        case .off: L("Off")
        case .whenPluggedIn: L("When plugged in")
        case .alsoOnBattery: L("Also on battery")
        }
    }
    func allows(_ power: NativeDesktopPowerSnapshot) -> Bool {
        !power.lowPowerMode && (self == .alsoOnBattery || (self == .whenPluggedIn && power.pluggedIn))
    }
}

struct NativeDesktopJoinReadinessPolicy {
    static let microphoneKey = "nativeDesktop.microphoneReadinessPolicy"
    static let cameraKey = "nativeDesktop.cameraReadinessPolicy"
    var microphone: NativeDesktopMediaReadinessMode = .whenPluggedIn
    var camera: NativeDesktopMediaReadinessMode = .whenPluggedIn
    var microphoneExplicit = false

    /// Read-only compatibility: a previous explicit headset opt-in keeps its
    /// battery behavior until a new microphone policy is selected.
    static func current(defaults: UserDefaults = .standard) -> Self {
        let microphone: NativeDesktopMediaReadinessMode
        if let saved = defaults.string(forKey: microphoneKey) {
            microphone = NativeDesktopMediaReadinessMode(rawValue: saved) ?? .whenPluggedIn
        } else {
            microphone = defaults.bool(forKey: "nativeDesktop.headsetMuteControls") ? .alsoOnBattery : .whenPluggedIn
        }
        return .init(microphone: microphone,
            camera: defaults.string(forKey: cameraKey).flatMap(NativeDesktopMediaReadinessMode.init(rawValue:)) ?? .whenPluggedIn,
            microphoneExplicit: defaults.object(forKey: microphoneKey) != nil || defaults.bool(forKey: "nativeDesktop.headsetMuteControls"))
    }
}

struct NativeDesktopPowerSnapshot: Equatable {
    var pluggedIn: Bool
    var lowPowerMode: Bool
    static func current() -> Self {
        let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let source = info.flatMap { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() } as String?
        // Unknown sources and UPS operation conservatively use the battery policy.
        return .init(pluggedIn: source == kIOPSACPowerValue,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}

private final class NativeDesktopPowerCallback {
    let changed: @MainActor () -> Void
    init(_ changed: @escaping @MainActor () -> Void) { self.changed = changed }
}

/// Created only by a meeting, never by Home. Both dependencies are injectable;
/// notifications trigger a fresh read without polling or changing system power.
@MainActor final class NativeDesktopPowerMonitor {
    typealias Observe = @MainActor (@escaping @MainActor () -> Void) -> (() -> Void)
    private let read: () -> NativeDesktopPowerSnapshot
    private let observe: Observe
    private var cancel: (() -> Void)?
    var snapshot: NativeDesktopPowerSnapshot { read() }

    init(read: @escaping () -> NativeDesktopPowerSnapshot = NativeDesktopPowerSnapshot.current,
         observe: @escaping Observe = NativeDesktopPowerMonitor.observeSystem) {
        self.read = read; self.observe = observe
    }
    func start(_ changed: @escaping @MainActor () -> Void) { stop(); cancel = observe(changed) }
    func stop() { cancel?(); cancel = nil }
    deinit { cancel?() }

    private static func observeSystem(_ changed: @escaping @MainActor () -> Void) -> (() -> Void) {
        let callback = NativeDesktopPowerCallback(changed)
        let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let callback = Unmanaged<NativeDesktopPowerCallback>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in callback.changed() }
        }, Unmanaged.passUnretained(callback).toOpaque())?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        let lowPower = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: .main) { _ in Task { @MainActor in changed() } }
        return {
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            NotificationCenter.default.removeObserver(lowPower)
            _ = callback // Keep the C callback context alive until its source is removed.
        }
    }
}
