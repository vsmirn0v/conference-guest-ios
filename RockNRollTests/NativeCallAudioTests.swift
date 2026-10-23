import AVFoundation
import XCTest
@testable import RockNRoll

@MainActor
final class NativeCallAudioTests: XCTestCase {
    private final class Audio: NativeRTCAudioControl {
        var useManualAudio = false
        var rejectsEnable = false
        var isAudioEnabled = true { didSet { if rejectsEnable && isAudioEnabled { isAudioEnabled = false } } }
        var activations = 0, deactivations = 0
        func audioSessionDidActivate(_ audioSession: AVAudioSession) { activations += 1 }
        func audioSessionDidDeactivate(_ audioSession: AVAudioSession) { deactivations += 1 }
    }
    private var connected: NativeCallAudioState {
        .init(joined: true, connected: true, leaving: false, held: false, quiet: false, microphoneIntent: true)
    }
    private func owner() -> SystemCallCoordinator {
        let owner = SystemCallCoordinator(transactionRequester: { _, _ in XCTFail("Unexpected transaction") },
            callSnapshot: { [] }, systemCallRegistration: false, activateAudioSession: {})
        owner.start(); owner.markConnected(); return owner
    }
    func testSessionLifecycleIsIdempotentAndRestoresPreviousSettings() {
        let owner = owner(), rtc = Audio()
        defer { owner.end() }
        let session = NativeCallAudio(owner: owner, audio: AudioCoordinator(), rtc: rtc)
        session.begin(); session.begin()
        XCTAssertTrue(rtc.useManualAudio); XCTAssertFalse(rtc.isAudioEnabled)
        session.activate(); session.activate()
        XCTAssertEqual(rtc.activations, 1)
        XCTAssertEqual(session.restore(connected), .reconnect)
        XCTAssertEqual(session.restore(connected), .updateMedia)
        session.pause(); session.deactivate(); session.deactivate()
        XCTAssertEqual(rtc.deactivations, 1)
        session.finish(); session.finish()
        XCTAssertFalse(rtc.useManualAudio); XCTAssertTrue(rtc.isAudioEnabled)
    }
    func testIntentCannotAdvertiseMicrophoneBeforePublisherSends() {
        let owner = owner(), rtc = Audio()
        defer { owner.end() }
        let session = NativeCallAudio(owner: owner, audio: AudioCoordinator(), rtc: rtc)
        XCTAssertTrue(session.shouldSendMicrophone(connected))
        XCTAssertEqual(session.microphoneStatus(connected, sending: false), .muted)
        XCTAssertEqual(session.microphoneStatus(connected, sending: true), .on)
        var state = connected; state.microphoneIntent = false
        XCTAssertFalse(session.shouldSendMicrophone(state))
        XCTAssertEqual(session.microphoneStatus(state, sending: true), .muted)
        for keyPath in [\NativeCallAudioState.held, \.quiet, \.leaving] {
            state = connected; state[keyPath: keyPath] = true
            XCTAssertFalse(session.shouldSendMicrophone(state))
            XCTAssertEqual(session.microphoneStatus(state, sending: true), .unavailable)
            XCTAssertEqual(session.restore(state), .blocked)
        }
        state = connected; state.connected = false
        XCTAssertEqual(session.microphoneStatus(state, sending: true), .unavailable)
        session.pause()
        XCTAssertFalse(session.shouldSendMicrophone(connected))
        XCTAssertEqual(session.microphoneStatus(connected, sending: true), .unavailable)
    }
    func testFailedDeviceActivationCannotAdvertiseWorkingAudio() {
        let owner = owner(), rtc = Audio()
        defer { owner.end() }
        let session = NativeCallAudio(owner: owner, audio: AudioCoordinator(), rtc: rtc)
        session.begin(); rtc.rejectsEnable = true
        XCTAssertEqual(session.restore(connected), .blocked)
        XCTAssertFalse(session.shouldSendMicrophone(connected))
        XCTAssertEqual(session.microphoneStatus(connected, sending: true), .unavailable)
        rtc.rejectsEnable = false
        XCTAssertEqual(session.restore(connected), .reconnect)
        XCTAssertTrue(session.shouldSendMicrophone(connected))
        session.finish()
    }
    func testInterruptionOwnershipBlocksSendingUntilFreshRelease() {
        let owner = owner(), rtc = Audio()
        defer { owner.end() }
        let session = NativeCallAudio(owner: owner, audio: AudioCoordinator(), rtc: rtc)
        owner.audioSessionInterrupted(true)
        XCTAssertEqual(session.restore(connected), .blocked)
        XCTAssertFalse(session.shouldSendMicrophone(connected))
        XCTAssertEqual(session.microphoneStatus(connected, sending: true), .unavailable)
        owner.audioSessionInterrupted(false)
        XCTAssertEqual(session.restore(connected), .updateMedia)
        XCTAssertEqual(session.microphoneStatus(connected, sending: true), .on)
    }
}
