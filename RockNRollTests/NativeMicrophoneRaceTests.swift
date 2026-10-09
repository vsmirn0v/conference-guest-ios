#if DEBUG
import ConferenceCore
import AVFoundation
import Foundation
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class NativeMicrophoneRaceTests: XCTestCase {
    func testTelemostMuteWhileMediaUpdateIsSuspendedCannotResumeCapture() async throws {
        guard let url = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_TELEMOST_INVITE"] else { throw XCTSkip("Authorized live room required") }
        guard AVAudioSession.sharedInstance().recordPermission == .granted else { throw XCTSkip("Microphone permission is required to exercise an enabled intent") }
        let engine = TelemostCallEngine(systemCall: SystemCallCoordinator(), catchUp: store(), chat: ChatStore())
        let container = try container()
        var active = false, ended = false
        engine.onEvent = { event in switch event { case .active: active = true; case .failed, .left: ended = true; default: break } }
        try engine.join(target: TelemostTarget.parse(url), name: "Rock mute race QA", container: container, quiet: false)
        defer { engine.leave() }
        try await wait { active || ended }; XCTAssertFalse(ended)
        guard !ended else { throw NativeRTCError.disconnected }
        try await checkRace(install: { gate in engine.beforeApplyingMicrophoneForTesting = gate },
            set: { engine.setSendingForTesting(microphone: $0, camera: false) }, sending: { engine.microphoneSendingForTesting })
        try await checkTransferHold(install: { gate in engine.beforeRequestingTransferHoldForTesting = gate },
            set: { engine.setSendingForTesting(microphone: $0, camera: false) },
            transfer: { try await engine.setTransferHeld($0, restoreSending: $1) }, sending: { engine.microphoneSendingForTesting })
        engine.leave(); try await wait { ended }
    }
    func testTrueConfMuteWhileMediaUpdateIsSuspendedCannotResumeCapture() async throws {
        guard let url = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_TRUECONF_INVITE"] else { throw XCTSkip("Authorized live room required") }
        guard AVAudioSession.sharedInstance().recordPermission == .granted else { throw XCTSkip("Microphone permission is required to exercise an enabled intent") }
        let engine = TrueConfCallEngine(systemCall: SystemCallCoordinator(), catchUp: store(), chat: ChatStore())
        let container = try container()
        var active = false, ended = false
        engine.onEvent = { event in switch event { case .active: active = true; case .failed, .left: ended = true; default: break } }
        try engine.join(target: TrueConfTarget.parse(url), name: "Rock mute race QA", container: container, quiet: false)
        defer { engine.leave() }
        try await wait { active || ended }; XCTAssertFalse(ended)
        guard !ended else { throw NativeRTCError.disconnected }
        try await checkRace(install: { gate in engine.beforeApplyingMicrophoneForTesting = gate },
            set: { engine.setSendingForTesting(microphone: $0, camera: false) }, sending: { engine.microphoneSendingForTesting })
        try await checkTransferHold(install: { gate in engine.beforeRequestingTransferHoldForTesting = gate },
            set: { engine.setSendingForTesting(microphone: $0, camera: false) },
            transfer: { try await engine.setTransferHeld($0, restoreSending: $1) }, sending: { engine.microphoneSendingForTesting })
        engine.leave(); try await wait { ended }
    }
    private func checkRace(install: (@escaping () async -> Void) -> Void, set: (Bool) -> Void, sending: () -> Bool) async throws {
        // Establish an enabled intent before suspending an update. Otherwise a
        // still-pending permission callback could make the old snapshot muted.
        set(true)
        try await wait { sending() }
        let suspended = expectation(description: "Media update suspended before audio application")
        let gate = MediaGate()
        defer { gate.released = true; gate.resume?.resume(); gate.resume = nil }
        install {
            guard !gate.entered, !gate.released else { return }
            gate.entered = true; suspended.fulfill()
            await withCheckedContinuation { gate.resume = $0 }
        }
        set(true)
        await fulfillment(of: [suspended], timeout: 15)
        set(false)
        XCTAssertFalse(sending(), "Mute must stop capture immediately")
        gate.resume?.resume(); gate.resume = nil
        // Sample during the resumed negotiation, not only after the next media
        // update has corrected an obsolete snapshot.
        for _ in 0..<80 {
            XCTAssertFalse(sending(), "The suspended update resurrected muted capture")
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
    private func checkTransferHold(install: (@escaping () async -> Void) -> Void, set: (Bool) -> Void,
                                   transfer: @escaping (Bool, Bool) async throws -> Void, sending: () -> Bool) async throws {
        set(true)
        try await wait { sending() }
        let suspended = expectation(description: "Transfer hold suspended before system acknowledgement")
        let gate = MediaGate()
        defer { gate.released = true; gate.resume?.resume(); gate.resume = nil }
        install {
            guard !gate.entered, !gate.released else { return }
            gate.entered = true; suspended.fulfill()
            await withCheckedContinuation { gate.resume = $0 }
        }
        let hold = Task { @MainActor in try await transfer(true, true) }
        defer { hold.cancel() }
        await fulfillment(of: [suspended], timeout: 15)
        // The system has not received the request yet. A previously enabled
        // sender must already be gated while its hold intent is retained.
        XCTAssertFalse(sending(), "Transfer hold waited for the system before muting capture")
        gate.resume?.resume(); gate.resume = nil
        try await hold.value
        try await transfer(false, false)
        for _ in 0..<80 {
            XCTAssertFalse(sending(), "Resume with sending disabled revived capture")
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
    private func container() throws -> UIViewController {
        let root = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first { $0.isKeyWindow }?.rootViewController)
        guard root.presentedViewController == nil else { throw XCTSkip("Another test is using the call presentation") }
        return root
    }
    private func store() -> CatchUpStore { CatchUpStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(nanoseconds: 100_000_000) }
        XCTFail("Call state was not reached"); throw NativeRTCError.disconnected
    }
    @MainActor private final class MediaGate {
        var entered = false
        var released = false
        var resume: CheckedContinuation<Void, Never>?
    }
}
#endif
