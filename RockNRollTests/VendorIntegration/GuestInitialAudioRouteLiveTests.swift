#if DEBUG
import AVFoundation
import ConferenceCore
import UIKit
import XCTest
@testable import RockNRoll

/// Run alone in a physical-device test process with an authorized invitation.
/// The test observes the selected headset; it never selects an audio port.
@MainActor
final class GuestInitialAudioRouteLiveTests: XCTestCase {
    func testFreshGuestJoinsKeepTheActiveBluetoothHeadset() async throws {
        guard let invitation = ProcessInfo.processInfo.environment["ROCK_INITIAL_ROUTE_INVITE"], !invitation.isEmpty else {
            throw XCTSkip("Set ROCK_INITIAL_ROUTE_INVITE to an authorized guest meeting")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires an actual Bluetooth output on a physical iPhone")
        #else
        guard !ProcessInfo.processInfo.isiOSAppOnMac, UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("Requires a physical iPhone")
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("Requires existing microphone permission; this test does not request permission or unmute")
        }
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 44
        var attempt = 0, routeChanges = 0
        let initial = record("before-configuration", attempt: attempt, changes: routeChanges, started: started)
        guard let headset = initial.first(where: \.isBluetooth) else {
            throw XCTSkip("Select AirPods or another Bluetooth headset before starting the test; no route will be forced")
        }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow })
        let original = window.rootViewController, host = UIViewController()
        let idle = UIApplication.shared.isIdleTimerDisabled
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("initial-route-" + UUID().uuidString)
        let engine = NativeConferenceEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore(storageURL: storeURL))
        var active = false, left = false, failed = false
        engine.onEvent = { event in
            if event == .active { active = true }
            if event == .left { left = true }
            if [.failed, .canceled, .evicted].contains(event) { failed = true }
        }
        let observer = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    routeChanges += 1
                    _ = self?.record("route-change", attempt: attempt, changes: routeChanges, started: started)
                }
            }
        window.rootViewController = host; window.makeKeyAndVisible()
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            NotificationCenter.default.removeObserver(observer)
            engine.leave(); window.rootViewController = original; window.makeKeyAndVisible()
            UIApplication.shared.isIdleTimerDisabled = idle
        }
        func wait(_ stage: String, until limit: TimeInterval, _ condition: () -> Bool) async throws {
            while !condition(), !failed, ProcessInfo.processInfo.systemUptime < min(limit, deadline) {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard !failed, condition() else {
                throw NSError(domain: "GuestInitialAudioRoute", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Initial route check could not reach \(stage); failed=\(failed)"])
            }
        }
        func leave() async -> Bool {
            let awaitingDeparture = engine.hasJoinStarted
            engine.leave()
            let limit = min(deadline + 5, ProcessInfo.processInfo.systemUptime + 5)
            while engine.hasJoinStarted || (awaitingDeparture && !left && !failed), ProcessInfo.processInfo.systemUptime < limit {
                try? await Task.sleep(for: .milliseconds(100))
            }
            _ = record("after-leave", attempt: attempt, changes: routeChanges, started: started)
            return !engine.hasJoinStarted
        }
        do {
            let target = try JoinTarget.parse(invitation)
            // Keep the production discovery/trust contract, with a resource
            // timeout inside the overall 44-second test-work budget.
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForResource = 8
            let session = URLSession(configuration: configuration, delegate: AdditionalRootTrust(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let endpoint = try await ConferenceEndpointResolver(serviceName: "jazz", session: session).resolve(for: target)
            for current in 1...2 {
                attempt = current; active = false; left = false; failed = false
                try engine.configure(container: host, networkURL: endpoint, displayName: "Initial route QA")
                _ = record("before-join", attempt: attempt, changes: routeChanges, started: started)
                try engine.join(target: target, displayName: "Initial route QA")
                try await wait("join \(attempt) media ready", until: ProcessInfo.processInfo.systemUptime + 14) {
                    active && engine.mediaReadyForTesting
                }
                guard !engine.studioForTesting.microphoneOn, !engine.studioForTesting.cameraOn else {
                    throw NSError(domain: "GuestInitialAudioRoute", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Fresh guest join did not keep microphone and camera off"])
                }
                let ready = ProcessInfo.processInfo.systemUptime
                for offset: TimeInterval in [2, 3] {
                    try await wait("join \(attempt) settled +\(offset)s", until: ready + offset + 0.5) {
                        ProcessInfo.processInfo.systemUptime >= ready + offset
                    }
                    let outputs = record("joined-plus-\(Int(offset))s", attempt: attempt, changes: routeChanges, started: started)
                    XCTAssertFalse(engine.studioForTesting.microphoneOn, "The live route test must remain muted")
                    XCTAssertFalse(engine.studioForTesting.cameraOn, "The live route test must not capture video")
                    XCTAssertFalse(left)
                    guard outputs.contains(where: { $0.isBluetooth && headset.matches($0) }) else {
                        throw NSError(domain: "GuestInitialAudioRoute", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Join \(attempt) lost the initial Bluetooth headset \(headset.name) (\(headset.uid))"])
                    }
                }
                guard await leave(), left else {
                    throw NSError(domain: "GuestInitialAudioRoute", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Join \(attempt) did not complete Leave"])
                }
            }
            print("INITIAL_AUDIO_ROUTE_RESULT joins=2 route_changes=\(routeChanges) elapsed_s=\(ProcessInfo.processInfo.systemUptime - started)")
        } catch {
            _ = await leave()
            throw error
        }
        #endif
    }

    private struct Output {
        let uid: String
        let name: String
        let type: AVAudioSession.Port
        var isBluetooth: Bool { [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains(type) }
        func matches(_ other: Output) -> Bool {
            // A2DP and HFP may expose different UIDs for the same headset.
            // Both exact identities are recorded; never guess from a brand name.
            uid == other.uid || name == other.name
        }
        var evidence: [String: String] { ["uid": uid, "name": name, "type": type.rawValue] }
    }

    @discardableResult
    private func record(_ stage: String, attempt: Int, changes: Int, started: TimeInterval) -> [Output] {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let outputs = route.outputs.map { Output(uid: $0.uid, name: $0.portName, type: $0.portType) }
        let evidence: [String: Any] = ["stage": stage, "attempt": attempt, "routeChanges": changes,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
            "outputs": outputs.map(\.evidence),
            "inputs": route.inputs.map { ["uid": $0.uid, "name": $0.portName, "type": $0.portType.rawValue] },
            "preferredInputUID": session.preferredInput?.uid ?? "", "category": session.category.rawValue,
            "mode": session.mode.rawValue, "options": session.categoryOptions.rawValue, "sampleRate": session.sampleRate]
        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print("INITIAL_AUDIO_ROUTE \(text)")
            let attachment = XCTAttachment(string: text)
            attachment.name = "Initial audio route — join \(attempt) — \(stage)"
            attachment.lifetime = .keepAlways; add(attachment)
        }
        return outputs
    }
}
#endif
