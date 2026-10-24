import Foundation
import LiveKitWebRTC

@main @MainActor struct DesktopHeadsetMuteTests {
    static func main() async {
        latestConfirmationOnly()
        programmaticAndFailedWrites()
        reconfigurationAndReplacement()
        reentrantRegistrationFailure()
        delayedMuteAndAtomicOpen()
        await deinitialization()
        print("PASS: headset intent/confirmation epochs, stale callbacks, metadata, programmatic/failed writes, owner replacement and deinit; no physical capture")
        if CommandLine.arguments.contains("--registration") {
            let live = NativeDesktopHeadsetMute()
            guard live.begin(onRequestedMute: { _ in }) else {
                print("UNAVAILABLE: actual AVAudioApplication registration: \(live.lastError ?? "macOS 14 required")")
                exit(2)
            }
            precondition(LKRTCApplicationCaptureMuted() == 1)
            live.end()
            precondition(LKRTCApplicationCaptureMuted() == 1 && LKRTCApplicationInputMuteReconfiguring() == 0)
            print("PASS: actual macOS AVAudioApplication handler registration/unregistration with native gate closed; no physical media")
        }
    }

    static func latestConfirmationOnly() {
        let fake = Fake(), controller = NativeDesktopHeadsetMute(platform: fake.platform)
        precondition(controller.begin(onRequestedMute: { _ in }))
        let old = controller.requestIntent(muted: false)
        _ = controller.requestIntent(muted: true)
        let latest = controller.requestIntent(muted: false)
        controller.confirm(muted: false, request: old)
        precondition(fake.gate.muted, "ABA confirmation opened the latest pending unmute")
        controller.confirm(muted: false)
        precondition(fake.gate.muted, "Untagged confirmation granted capture")
        controller.confirm(muted: false, request: latest)
        precondition(!fake.gate.muted)
        let callback = fake.handlers.last!, note = fake.observers.last!
        controller.end()
        precondition(!callback(false))
        precondition(controller.begin(onRequestedMute: { _ in }))
        controller.confirm(muted: false, request: latest)
        precondition(fake.gate.muted, "Previous owner confirmation opened replacement")
        let writes = fake.gate.writes
        precondition(!callback(true)); note(false)
        precondition(fake.gate.writes == writes, "Old callback/notification mutated replacement")
        controller.end()
    }

    static func programmaticAndFailedWrites() {
        let fake = Fake(), controller = NativeDesktopHeadsetMute(platform: fake.platform)
        var requests: [Bool] = []
        precondition(controller.begin(onRequestedMute: { requests.append($0) }))
        // Programmatic writes deliberately emit no notification.
        let request = controller.requestIntent(muted: false)
        controller.confirm(muted: false, request: request)
        precondition(!fake.gate.muted && requests.isEmpty)
        fake.gesture(true)
        precondition(requests == [true] && fake.gate.muted, "Missing own notification swallowed genuine gesture")
        fake.gesture(false)
        precondition(requests == [true, false] && fake.gate.muted, "Gesture unmute opened before engine confirmation")
        let next = controller.requestIntent(muted: false)
        controller.confirm(muted: false, request: next)
        precondition(!fake.gate.muted)
        fake.failWrites = true
        _ = controller.requestIntent(muted: true)
        let count = requests.count
        fake.observers.last?(false)
        precondition(fake.gate.muted && requests.count == count, "Failed write became an unmute gesture")
        fake.failWrites = false
        fake.observers.last?(false)  // Resynchronize first; do not infer an action.
        precondition(fake.muted && requests.count == count)
        fake.gesture(false)
        precondition(requests.last == false && requests.count == count + 1)
        controller.end()
    }

    static func reconfigurationAndReplacement() {
        let sharedGate = Gate(), a = Fake(gate: sharedGate), b = Fake(gate: sharedGate)
        let first = NativeDesktopHeadsetMute(platform: a.platform), second = NativeDesktopHeadsetMute(platform: b.platform)
        var requests: [Bool] = []
        precondition(first.begin(onRequestedMute: { requests.append($0) }))
        a.reconfiguring = true; a.gesture(false)
        precondition(requests.isEmpty && a.muted && sharedGate.muted)
        a.reconfiguring = false
        a.observers.last?(false)  // Metadata disagrees with current bit: stale event.
        precondition(requests.isEmpty)
        let oldHandler = a.handlers.last!
        precondition(second.begin(onRequestedMute: { _ in }))
        let request = second.requestIntent(muted: false)
        second.confirm(muted: false, request: request)
        let unregisters = b.unregistered
        first.end()
        precondition(b.unregistered == unregisters && !sharedGate.muted)
        precondition(!oldHandler(true) && !sharedGate.muted)
        second.end()
    }

    static func reentrantRegistrationFailure() {
        let gate = Gate(), a = Fake(gate: gate), b = Fake(gate: gate)
        a.failInstall = true
        let first = NativeDesktopHeadsetMute(platform: a.platform), second = NativeDesktopHeadsetMute(platform: b.platform)
        first.onError = { _ in precondition(second.begin(onRequestedMute: { _ in })) }
        precondition(!first.begin(onRequestedMute: { _ in }))
        precondition(second.isActive && gate.muted, "Failed registration opened new owner's gate")
        precondition(!first.useEngineOnlyFallback(confirmedMuted: true))
        second.end()
        precondition(first.useEngineOnlyFallback(confirmedMuted: true))
        precondition(!gate.muted)
    }

    static func deinitialization() async {
        let fake = Fake()
        var controller: NativeDesktopHeadsetMute? = .init(platform: fake.platform)
        precondition(controller!.begin(onRequestedMute: { _ in }))
        let request = controller!.requestIntent(muted: false)
        controller!.confirm(muted: false, request: request)
        precondition(!fake.gate.muted)
        weak var weakController = controller
        controller = nil
        precondition(weakController == nil && fake.gate.muted, "Current deinit did not immediately close PCM")
        for _ in 0..<100 where fake.unregistered == 0 { await Task.yield() }
        precondition(fake.unregistered == 1 && fake.intent == -1)

        let gate = Gate(), a = Fake(gate: gate), b = Fake(gate: gate)
        var old: NativeDesktopHeadsetMute? = .init(platform: a.platform)
        let next = NativeDesktopHeadsetMute(platform: b.platform)
        precondition(old!.begin(onRequestedMute: { _ in }))
        precondition(next.begin(onRequestedMute: { _ in }))
        let newRequest = next.requestIntent(muted: false)
        next.confirm(muted: false, request: newRequest)
        old = nil
        await Task.yield()
        precondition(!gate.muted && next.isActive && b.unregistered == 0, "Obsolete deinit affected replacement")
        next.end()
    }

    static func delayedMuteAndAtomicOpen() {
        let fake = Fake(), controller = NativeDesktopHeadsetMute(platform: fake.platform)
        var requests: [Bool] = []
        precondition(controller.begin(onRequestedMute: { requests.append($0) }))
        let pending = controller.requestIntent(muted: false)
        fake.muted = true; precondition(fake.handlers.last?(true) == true)
        controller.confirm(muted: false, request: pending)
        precondition(fake.gate.muted && fake.muted, "Queued notification let old confirmation overwrite OS mute")
        fake.reconfiguring = true
        fake.observers.last?(true)
        precondition(requests == [true] && fake.gate.muted && fake.muted)
        fake.reconfiguring = false
        let next = controller.requestIntent(muted: false)
        fake.gate.beforeConditionalOpen = { [gate = fake.gate] in gate.set(true) }
        controller.confirm(muted: false, request: next)
        precondition(fake.gate.muted, "Mute racing final conditional open was overwritten")
        controller.end()
    }

    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 1
        private var count = 0
        var beforeConditionalOpen: (() -> Void)?
        var muted: Bool { lock.lock(); defer { lock.unlock() }; return value & 1 != 0 }
        var state: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
        var writes: Int { lock.lock(); defer { lock.unlock() }; return count }
        func set(_ muted: Bool) {
            lock.lock(); value = ((value & ~1) + 2) | (muted ? 1 : 0); count += 1; lock.unlock()
        }
        func unmuteIfState(_ expected: UInt64) -> Bool {
            let action = beforeConditionalOpen; beforeConditionalOpen = nil; action?()
            lock.lock(); defer { lock.unlock() }
            guard value == expected else { return false }
            value = value & 1 != 0 ? ((value & ~1) + 2) : value
            count += 1; return true
        }
    }
    @MainActor final class Fake {
        let gate: Gate
        var muted = false, failWrites = false, failInstall = false, reconfiguring = false
        var intent: Int32 = -1, unregistered = 0
        var handlers: [@Sendable (Bool) -> Bool] = []
        var observers: [@MainActor (Bool) -> Void] = []
        init(gate: Gate = Gate()) { self.gate = gate }
        var platform: NativeDesktopHeadsetMute.Platform {
            .init(available: true, readMuted: { self.muted }, writeMuted: {
                if self.failWrites { throw NSError(domain: "FixtureWrite", code: 1) }
                self.muted = $0
                precondition(self.handlers.last?($0) == true)
            }, install: {
                if self.failInstall { throw NSError(domain: "FixtureInstall", code: 1) }
                self.handlers.append($0)
            }, uninstall: { self.unregistered += 1 }, observe: { self.observers.append($0); return NSObject() },
            removeObserver: { _ in }, setCaptureMuted: { [gate] in gate.set($0) },
            captureState: { [gate] in gate.state }, unmuteIfState: { [gate] in gate.unmuteIfState($0) },
            setIntent: { self.intent = $0 }, isReconfiguring: { self.reconfiguring })
        }
        func gesture(_ muted: Bool) {
            self.muted = muted
            precondition(handlers.last?(muted) == true)
            observers.last?(muted)
        }
    }
}
