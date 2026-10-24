import CoreAudio

/// Read-only calibration guard: never selects routes or changes the user's volume.
struct GuestAcousticEnvironment: Equatable {
    let input: AudioDeviceID
    let output: AudioDeviceID
    let volume: [Float]
    let muted: UInt32
    static let unavailable = Self(input: 0, output: 0, volume: [], muted: 0)
    var audibleOutputConfigured: Bool { input != 0 && output != 0 && muted == 0 && volume.contains { $0 > 0 } }

    static func capture() -> Self {
        func integer(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
        }
        guard let input = integer(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice),
              let output = integer(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice),
              input != 0, output != 0,
              let muted = integer(output, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) else { return .unavailable }
        func volume(_ element: AudioObjectPropertyElement) -> Float? {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            var value: Float = 0, size = UInt32(MemoryLayout<Float>.size)
            guard AudioObjectGetPropertyData(output, &address, 0, nil, &size, &value) == noErr, value.isFinite else { return nil }
            return value
        }
        let volumes: [Float]
        if let main = volume(kAudioObjectPropertyElementMain) { volumes = [main] }
        else if let left = volume(1), let right = volume(2) { volumes = [left, right] }
        else { return .unavailable }
        return Self(input: input, output: output, volume: volumes, muted: muted)
    }
}
