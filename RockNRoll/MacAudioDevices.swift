import Combine
import Darwin
import Foundation

// AudioHardware.h defines an address as three consecutive UInt32 fields. The
// declarations are excluded from the iOS SDK; retain the public C layout.
private struct MacAudioPropertyAddress {
    var mSelector: UInt32
    var mScope: UInt32
    var mElement: UInt32
}

#if DEBUG
/// Verify the actual Mac app's HAL write permissions without changing routes.
@MainActor
enum MacAudioLiveProbe {
    static func verifyCurrentDefaults() {
        do {
            guard let hardware = MacCoreAudioHardware() else { throw MacAudioError.unavailable }
            let before = try hardware.snapshot()
            for direction in MacAudioDirection.allCases {
                let id = before.selectedID(for: direction)
                if id != 0 { try hardware.select(id, for: direction) }
            }
            let after = try hardware.snapshot()
            guard before.outputID == after.outputID, before.inputID == after.inputID else {
                throw MacAudioError.unavailable
            }
            NSLog("Mac audio HAL current-default write verified: output=%u input=%u", after.outputID, after.inputID)
        } catch {
            NSLog("Mac audio HAL verification failed: %@", String(describing: error))
        }
    }
}
#endif

enum MacAudioDirection: CaseIterable, Hashable {
    case output, input

    var scope: UInt32 {
        self == .output ? 0x6F757470 /* outp */ : 0x696E7074 /* inpt */
    }

    // Public AudioHardware.h selectors are absent from the iOS SDK.
    var defaultSelector: UInt32 {
        self == .output ? 0x644F7574 /* dOut */ : 0x64496E20 /* dIn  */
    }
}

struct MacAudioDevice: Equatable {
    let id: UInt32
    let name: String
    let directions: Set<MacAudioDirection>
}

struct MacAudioSnapshot: Equatable {
    var devices: [MacAudioDevice] = []
    var outputID: UInt32 = 0
    var inputID: UInt32 = 0

    func devices(for direction: MacAudioDirection) -> [MacAudioDevice] {
        devices.filter { $0.directions.contains(direction) }
    }

    func selectedID(for direction: MacAudioDirection) -> UInt32 {
        direction == .output ? outputID : inputID
    }

    var outputName: String? { devices.first { $0.id == outputID }?.name }
}

@MainActor
protocol MacAudioHardware: AnyObject {
    func snapshot() throws -> MacAudioSnapshot
    func select(_ id: UInt32, for direction: MacAudioDirection) throws
    func observe(_ changed: @escaping @MainActor () -> Void)
}

@MainActor
final class MacAudioDevices {
    static let shared = MacAudioDevices()
    @Published private(set) var snapshot = MacAudioSnapshot()
    @Published private(set) var unavailable = false
    private let hardware: MacAudioHardware?

    init(isMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac, hardware: MacAudioHardware? = nil) {
        self.hardware = isMac ? (hardware ?? MacCoreAudioHardware()) : nil
        self.hardware?.observe { [weak self] in self?.refresh() }
        refresh()
    }

    func refresh() {
        do {
            guard let hardware else { unavailable = true; return }
            snapshot = try hardware.snapshot()
            unavailable = false
        } catch {
            snapshot = MacAudioSnapshot()
            unavailable = true
        }
    }

    func select(_ id: UInt32, for direction: MacAudioDirection) throws {
        guard let hardware else { throw MacAudioError.unavailable }
        // Recheck membership at click time: a disconnected device must not be
        // selected from a stale popup, nor an input-only device used as output.
        let current = try hardware.snapshot()
        guard current.devices(for: direction).contains(where: { $0.id == id }) else {
            refresh()
            throw MacAudioError.unavailable
        }
        guard current.selectedID(for: direction) != id else { refresh(); return }
        try hardware.select(id, for: direction)
        // HAL setters may complete asynchronously. Checkmarks follow observed
        // state, never an optimistic selection that could fail to take effect.
        refresh()
    }
}

enum MacAudioError: Error {
    case unavailable
    case status(OSStatus)
}

/// Public Core Audio HAL access for Designed-for-iPad on Mac. The iOS SDK
/// omits the HAL declarations. Resolve their exact C ABI only on Mac; do not
/// load or change hardware on iOS.
@MainActor
private final class MacCoreAudioHardware: MacAudioHardware {
    typealias Size = @convention(c) (UInt32, UnsafeRawPointer, UInt32,
        UnsafeRawPointer?, UnsafeMutablePointer<UInt32>) -> OSStatus
    typealias Get = @convention(c) (UInt32, UnsafeRawPointer, UInt32,
        UnsafeRawPointer?, UnsafeMutablePointer<UInt32>, UnsafeMutableRawPointer) -> OSStatus
    typealias Write = @convention(c) (UInt32, UnsafeRawPointer, UInt32,
        UnsafeRawPointer?, UInt32, UnsafeRawPointer) -> OSStatus
    typealias Listener = @convention(block) (UInt32, UnsafeRawPointer) -> Void
    typealias Observe = @convention(c) (UInt32, UnsafeRawPointer,
        OpaquePointer?, Listener) -> OSStatus

    private let handle: UnsafeMutableRawPointer
    private let size: Size
    private let get: Get
    private let set: Write
    private let addListener: Observe
    private let removeListener: Observe
    private var listener: Listener?
    private var observed: [MacAudioPropertyAddress] = []
    private let system: UInt32 = 1 // kAudioObjectSystemObject
    private let devicesSelector: UInt32 = 0x64657623 // dev#

    init?() {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              let handle = dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio", RTLD_LAZY | RTLD_LOCAL)
        else { return nil }
        guard let size = dlsym(handle, "AudioObjectGetPropertyDataSize"),
              let get = dlsym(handle, "AudioObjectGetPropertyData"),
              let set = dlsym(handle, "AudioObjectSetPropertyData"),
              let add = dlsym(handle, "AudioObjectAddPropertyListenerBlock"),
              let remove = dlsym(handle, "AudioObjectRemovePropertyListenerBlock") else {
            dlclose(handle)
            return nil
        }
        self.handle = handle
        self.size = unsafeBitCast(size, to: Size.self)
        self.get = unsafeBitCast(get, to: Get.self)
        self.set = unsafeBitCast(set, to: Write.self)
        addListener = unsafeBitCast(add, to: Observe.self)
        removeListener = unsafeBitCast(remove, to: Observe.self)
    }

    deinit {
        if let listener {
            for var address in observed { _ = removeListener(system, &address, nil, listener) }
        }
        dlclose(handle)
    }

    func snapshot() throws -> MacAudioSnapshot {
        var address = property(devicesSelector)
        var byteCount: UInt32 = 0
        try check(size(system, &address, 0, nil, &byteCount))
        guard byteCount % UInt32(MemoryLayout<UInt32>.size) == 0 else { throw MacAudioError.unavailable }
        var ids = [UInt32](repeating: 0, count: Int(byteCount) / MemoryLayout<UInt32>.size)
        if !ids.isEmpty {
            try ids.withUnsafeMutableBytes { bytes in
                try check(get(system, &address, 0, nil, &byteCount, bytes.baseAddress!))
            }
            ids = Array(ids.prefix(Int(byteCount) / MemoryLayout<UInt32>.size))
        }
        let devices = ids.compactMap { id -> MacAudioDevice? in
            guard (try? number(id, 0x6C69766E /* livn */)) == 1,
                  let name = try? name(id) else { return nil }
            let directions = Set(MacAudioDirection.allCases.filter { direction in
                (try? number(id, 0x64666C74 /* dflt */, scope: direction.scope)) == 1
            })
            return directions.isEmpty ? nil : MacAudioDevice(id: id, name: name, directions: directions)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return MacAudioSnapshot(devices: devices,
            outputID: try number(system, MacAudioDirection.output.defaultSelector),
            inputID: try number(system, MacAudioDirection.input.defaultSelector))
    }

    func select(_ id: UInt32, for direction: MacAudioDirection) throws {
        var address = property(direction.defaultSelector)
        var value = id
        try check(set(system, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value))
    }

    func observe(_ changed: @escaping @MainActor () -> Void) {
        guard listener == nil else { return }
        let block: Listener = { _, _ in Task { @MainActor in changed() } }
        listener = block
        for selector in [devicesSelector] + MacAudioDirection.allCases.map(\.defaultSelector) {
            var address = property(selector)
            if addListener(system, &address, nil, block) == noErr { observed.append(address) }
        }
    }

    private func property(_ selector: UInt32,
                          scope: UInt32 = 0x676C6F62 /* glob */) -> MacAudioPropertyAddress {
        MacAudioPropertyAddress(mSelector: selector, mScope: scope, mElement: 0)
    }

    private func number(_ id: UInt32, _ selector: UInt32,
                        scope: UInt32 = 0x676C6F62 /* glob */) throws -> UInt32 {
        var address = property(selector, scope: scope)
        var value: UInt32 = 0
        var count = UInt32(MemoryLayout.size(ofValue: value))
        try check(get(id, &address, 0, nil, &count, &value))
        guard count == MemoryLayout.size(ofValue: value) else { throw MacAudioError.unavailable }
        return value
    }

    private func name(_ id: UInt32) throws -> String {
        var address = property(0x6C6E616D /* lnam */)
        var value: Unmanaged<CFString>?
        var count = UInt32(MemoryLayout.size(ofValue: value))
        try check(get(id, &address, 0, nil, &count, &value))
        guard let value else { throw MacAudioError.unavailable }
        // AudioObjectPropertyName transfers ownership to the caller.
        return value.takeRetainedValue() as String
    }

    private func check(_ status: OSStatus) throws {
        if status != noErr { throw MacAudioError.status(status) }
    }
}
