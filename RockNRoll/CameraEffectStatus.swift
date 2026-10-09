import AVFoundation

/// A selected system setting is not proof that an SDK-owned capture applies it.
struct CameraEffectStatus: Equatable, Identifiable {
    enum Effect: String, CaseIterable { case portrait, lighting, framing, background, edgeLight }
    enum State: Equatable { case unavailable, off, selected, active }
    let effect: Effect
    let state: State
    var id: Effect { effect }
    var title: String {
        switch effect {
        case .portrait: return L("Portrait blur")
        case .lighting: return L("Studio Light")
        case .framing: return L("Center Stage")
        case .background: return L("System background")
        case .edgeLight: return L("Edge Light")
        }
    }
    var value: String {
        switch state {
        case .unavailable: return L("Unavailable")
        case .off: return L("Off")
        case .selected: return L("Selected in system settings")
        case .active: return L("Active on camera")
        }
    }
    static func state(selected: Bool, supported: Bool?, active: Bool?) -> State {
        if active == true { return .active }
        if supported == false { return .unavailable }
        return selected ? .selected : .off
    }
    static func read(device: AVCaptureDevice?) -> [Self] {
        var result: [Self] = []
        func add(_ effect: Effect, _ selected: Bool, _ supported: Bool?, _ active: Bool?) {
            result.append(Self(effect: effect, state: state(selected: selected, supported: supported, active: active)))
        }
        add(.portrait, AVCaptureDevice.isPortraitEffectEnabled,
            device?.activeFormat.isPortraitEffectSupported, device?.isPortraitEffectActive)
        add(.lighting, AVCaptureDevice.isStudioLightEnabled,
            device?.activeFormat.isStudioLightSupported, device?.isStudioLightActive)
        add(.framing, AVCaptureDevice.isCenterStageEnabled,
            device?.activeFormat.isCenterStageSupported, device?.isCenterStageActive)
        if #available(iOS 18.0, *) {
            add(.background, AVCaptureDevice.isBackgroundReplacementEnabled,
                device?.activeFormat.isBackgroundReplacementSupported, device?.isBackgroundReplacementActive)
        }
        if #available(iOS 26.2, *) {
            add(.edgeLight, AVCaptureDevice.isEdgeLightEnabled,
                device?.activeFormat.isEdgeLightSupported, device == nil ? nil : AVCaptureDevice.isEdgeLightActive)
        }
        return result
    }
}

/// Center Stage is scoped to this app. After our first full-frame default,
/// system controls remain authoritative; opening Studio never reapplies a stale
/// saved value over a newer Control Center choice.
@MainActor
final class CameraFramingPolicy {
    static let shared = CameraFramingPolicy()
    static let preferenceKey = "studio.automatic-framing"
    private let preferences: UserDefaults
    private let read: () -> Bool
    private let write: (Bool) -> Void
    private let cooperate: () -> Void
    private var prepared = false

    init(preferences: UserDefaults = .standard,
         read: @escaping () -> Bool = { AVCaptureDevice.isCenterStageEnabled },
         write: @escaping (Bool) -> Void = { AVCaptureDevice.isCenterStageEnabled = $0 },
         cooperate: @escaping () -> Void = { AVCaptureDevice.centerStageControlMode = .cooperative }) {
        self.preferences = preferences; self.read = read; self.write = write; self.cooperate = cooperate
    }
    @discardableResult
    func synchronize() -> Bool {
        if !prepared {
            cooperate()
            if preferences.object(forKey: Self.preferenceKey) == nil { write(false) }
            prepared = true
        }
        let enabled = read()
        if preferences.object(forKey: Self.preferenceKey) as? Bool != enabled {
            preferences.set(enabled, forKey: Self.preferenceKey)
        }
        return enabled
    }
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        _ = synchronize()
        cooperate(); write(enabled)
        return synchronize()
    }
}
