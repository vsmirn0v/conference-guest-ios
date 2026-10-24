import CoreAudio
import Darwin
import Foundation

/// Reversible fixture route only. Never changes volumes, device formats or app preferences.
@main enum MacCaptureRoute {
    enum Failure: Error { case property(OSStatus), ambiguousBuiltIn, missingOriginal, arguments }
    struct Saved: Codable { let input: String; let output: String }
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func number(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
        var a = address(selector), value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        let result = AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value)
        guard result == noErr else { throw Failure.property(result) }; return value
    }
    static func uid(_ device: AudioObjectID) throws -> String {
        var a = address(kAudioDevicePropertyDeviceUID), value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let result = AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value)
        guard result == noErr else { throw Failure.property(result) }; return value as String
    }
    static func devices() throws -> [AudioDeviceID] {
        var a = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
        let result = AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size)
        guard result == noErr else { throw Failure.property(result) }
        var values = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = values.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &a, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { throw Failure.property(status) }; return values
    }
    static func hasStreams(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var a = address(kAudioDevicePropertyStreams, scope), size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr && size > 0
    }
    static func select(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) throws {
        var value = device, a = address(selector)
        let result = AudioObjectSetPropertyData(system, &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        guard result == noErr else { throw Failure.property(result) }
        guard try uid(number(system, selector)) == uid(device) else { throw Failure.missingOriginal }
    }
    static func verify(input: String, output: String) throws {
        guard try uid(number(system, kAudioHardwarePropertyDefaultInputDevice)) == input,
              try uid(number(system, kAudioHardwarePropertyDefaultOutputDevice)) == output else { throw Failure.missingOriginal }
    }
    static func restore(_ file: URL) throws {
        let marker = file.appendingPathExtension("restored")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file)), all = try devices()
        guard let input = try all.first(where: { try uid($0) == saved.input }),
              let output = try all.first(where: { try uid($0) == saved.output }) else { throw Failure.missingOriginal }
        try select(input, selector: kAudioHardwarePropertyDefaultInputDevice)
        try select(output, selector: kAudioHardwarePropertyDefaultOutputDevice)
        try verify(input: saved.input, output: saved.output)
        try Data("restored".utf8).write(to: marker, options: .atomic)
        print("PASS: original default audio routes restored")
    }
    static func main() {
        do {
            let args = CommandLine.arguments
            guard args.count >= 3 else { throw Failure.arguments }
            let file = URL(fileURLWithPath: args[2])
            switch args[1] {
            case "--builtins":
                guard !FileManager.default.fileExists(atPath: file.path) else { throw Failure.arguments }
                let saved = try Saved(input: uid(number(system, kAudioHardwarePropertyDefaultInputDevice)), output: uid(number(system, kAudioHardwarePropertyDefaultOutputDevice)))
                try JSONEncoder().encode(saved).write(to: file, options: .atomic)
                let all = try devices().filter { try number($0, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn }
                let inputs = all.filter { hasStreams($0, scope: kAudioObjectPropertyScopeInput) }
                let outputs = all.filter { hasStreams($0, scope: kAudioObjectPropertyScopeOutput) }
                guard inputs.count == 1, outputs.count == 1 else { throw Failure.ambiguousBuiltIn }
                do {
                    try select(inputs[0], selector: kAudioHardwarePropertyDefaultInputDevice)
                    try select(outputs[0], selector: kAudioHardwarePropertyDefaultOutputDevice)
                    try verify(input: uid(inputs[0]), output: uid(outputs[0]))
                    print("PASS: built-in fixture routes selected")
                } catch { try? restore(file); throw error }
            case "--inspect":
                let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file)), all = try devices()
                let input = try uid(number(system, kAudioHardwarePropertyDefaultInputDevice))
                let output = try uid(number(system, kAudioHardwarePropertyDefaultOutputDevice))
                let values: [String: Bool] = ["originalInputAvailable": try all.contains { try uid($0) == saved.input },
                    "originalOutputAvailable": try all.contains { try uid($0) == saved.output },
                    "originalInputSelected": input == saved.input, "originalOutputSelected": output == saved.output]
                print(String(decoding: try JSONEncoder().encode(values), as: UTF8.self))
            case "--restore": try restore(file)
            case "--guard":
                guard args.count == 4, let owner = Int32(args[3]) else { throw Failure.arguments }
                let end = Date().addingTimeInterval(420)
                while Date() < end && Darwin.kill(owner, 0) == 0 && !FileManager.default.fileExists(atPath: file.appendingPathExtension("restored").path) { Thread.sleep(forTimeInterval: 0.2) }
                try restore(file)
            default: throw Failure.arguments
            }
        } catch { fputs("FAIL: capture route fixture \(error)\n", stderr); exit(1) }
    }
}
