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

    /// Default input and output devices for diagnostics: transport (FourCC, e.g.
    /// "bltn", "blue", "usb ", "virt", "aggr"), nominal rate and channel counts.
    /// Device names often contain a person's name, so they are opt-in.
    static func route(names: Bool = false) -> [String: Any] {
        func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
            .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        }
        func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
            var property = address(selector, scope), value = initial, size = UInt32(MemoryLayout<T>.size)
            return AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr ? value : nil
        }
        func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
            var property = address(kAudioDevicePropertyStreamConfiguration, scope), size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr, size > 0 else { return 0 }
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { buffer.deallocate() }
            guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, buffer) == noErr else { return 0 }
            return UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
                .reduce(0) { $0 + Int($1.mNumberChannels) }
        }
        func device(_ selector: AudioObjectPropertySelector) -> [String: Any] {
            guard let id: AudioDeviceID = read(AudioObjectID(kAudioObjectSystemObject), selector, 0), id != 0 else { return ["present": false] }
            var value: [String: Any] = ["present": true, "inputChannels": channels(id, kAudioDevicePropertyScopeInput),
                "outputChannels": channels(id, kAudioDevicePropertyScopeOutput)]
            if let transport: UInt32 = read(id, kAudioDevicePropertyTransportType, 0) {
                value["transport"] = String(bytes: withUnsafeBytes(of: transport.bigEndian, Array.init), encoding: .ascii) ?? String(transport)
            }
            if let rate: Float64 = read(id, kAudioDevicePropertyNominalSampleRate, 0), rate.isFinite { value["sampleRate"] = rate }
            if let alive: UInt32 = read(id, kAudioDevicePropertyDeviceIsAlive, 0) { value["alive"] = alive != 0 }
            if names {
                var property = address(kAudioObjectPropertyName), name: Unmanaged<CFString>?
                var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                if AudioObjectGetPropertyData(id, &property, 0, nil, &size, &name) == noErr, let name {
                    value["name"] = name.takeRetainedValue() as String
                }
            }
            return value
        }
        return ["input": device(kAudioHardwarePropertyDefaultInputDevice), "output": device(kAudioHardwarePropertyDefaultOutputDevice)]
    }
}
