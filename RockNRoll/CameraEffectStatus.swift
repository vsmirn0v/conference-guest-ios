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
