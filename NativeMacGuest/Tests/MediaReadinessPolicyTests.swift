import Foundation

@main private enum MediaReadinessPolicyTests {
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
    }
    @MainActor static func main() {
        for mode in NativeDesktopMediaReadinessMode.allCases {
            for pluggedIn in [false, true] {
                for lowPower in [false, true] {
                    let power = NativeDesktopPowerSnapshot(pluggedIn: pluggedIn, lowPowerMode: lowPower)
                    let allowed = !lowPower && (mode == .alsoOnBattery || (mode == .whenPluggedIn && pluggedIn))
                    expect(mode.allows(power) == allowed, "Power policy matrix failed")
                }
            }
        }
        let name = "media-readiness-policy-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let initial = NativeDesktopJoinReadinessPolicy.current(defaults: defaults)
        expect(initial.microphone == .whenPluggedIn && initial.camera == .whenPluggedIn && !initial.microphoneExplicit,
            "New users default to preparation while plugged in")
        defaults.set(true, forKey: "nativeDesktop.joinMicrophoneReady")
        defaults.set(true, forKey: "nativeDesktop.joinCameraPrime")
        expect(NativeDesktopJoinReadinessPolicy.current(defaults: defaults).microphone == .whenPluggedIn,
            "Prototype switches must not override the real selectors")
        defaults.set(true, forKey: "nativeDesktop.headsetMuteControls")
        let before = defaults.persistentDomain(forName: name)! as NSDictionary
        let legacy = NativeDesktopJoinReadinessPolicy.current(defaults: defaults)
        expect(legacy.microphone == .alsoOnBattery && legacy.microphoneExplicit, "Legacy opt-in keeps battery behavior")
        expect(before == defaults.persistentDomain(forName: name)! as NSDictionary, "Reading migration may not write preferences")
        for mode in NativeDesktopMediaReadinessMode.allCases {
            defaults.set(mode.rawValue, forKey: NativeDesktopJoinReadinessPolicy.microphoneKey)
            defaults.set(mode.rawValue, forKey: NativeDesktopJoinReadinessPolicy.cameraKey)
            let selected = NativeDesktopJoinReadinessPolicy.current(defaults: defaults)
            expect(selected.microphone == mode && selected.camera == mode && selected.microphoneExplicit,
                "New selections override legacy opt-in")
        }
        var state = NativeDesktopPowerSnapshot(pluggedIn: true, lowPowerMode: false)
        var notify: (@MainActor () -> Void)?, events = 0, cancellations = 0, reads = 0
        let monitor = NativeDesktopPowerMonitor(read: { reads += 1; return state }, observe: {
            notify = $0
            return { notify = nil; cancellations += 1 }
        })
        monitor.start { events += 1 }
        expect(reads == 0, "Observation must not poll power")
        expect(monitor.snapshot.pluggedIn, "Injected AC state was not read")
        state = .init(pluggedIn: false, lowPowerMode: false); notify?()
        expect(events == 1 && !monitor.snapshot.pluggedIn, "Battery notification must expose fresh state")
        state.lowPowerMode = true; notify?()
        expect(events == 2 && monitor.snapshot.lowPowerMode, "Low Power notification must expose fresh state")
        monitor.stop()
        expect(cancellations == 1 && notify == nil, "Stopping meeting observation must remove notifications")
        print("Media readiness: 12 power combinations, preference compatibility and injected notifications passed")
    }
}
