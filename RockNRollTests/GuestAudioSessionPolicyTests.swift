import AVFoundation
import WebRTC
import XCTest
@testable import RockNRoll

final class GuestAudioSessionPolicyTests: XCTestCase {
    func testEveryPlaybackConfigurationPreservesRoutesAndMixes() {
        for category in [AVAudioSession.Category.playAndRecord, .playback] {
            for requested: AVAudioSession.CategoryOptions in [[], [.allowBluetoothHFP, .allowBluetoothA2DP], [.defaultToSpeaker]] {
                let actual = GuestAudioSessionPolicy.options(category: category.rawValue, requested: requested)
                XCTAssertEqual(actual, requested.union(.mixWithOthers))
                XCTAssertFalse(actual.contains(.duckOthers))
            }
        }
        XCTAssertEqual(GuestAudioSessionPolicy.options(category: AVAudioSession.Category.record.rawValue, requested: []), [])
    }

    func testPublicSDKConfigurationKeepsMixingBeforeActivation() throws {
        GuestAudioSessionPolicy.prepare()
        let rtc = RTCAudioSession.sharedInstance(), audio = AVAudioSession.sharedInstance()
        let old = (audio.category, audio.mode, audio.categoryOptions)
        rtc.lockForConfiguration()
        defer {
            try? audio.setCategory(old.0, mode: old.1, options: old.2)
            rtc.unlockForConfiguration()
        }
        let configuration = RTCAudioSessionConfiguration()
        configuration.category = AVAudioSession.Category.playAndRecord.rawValue
        configuration.mode = AVAudioSession.Mode.voiceChat.rawValue
        configuration.categoryOptions = [.allowBluetoothHFP, .allowBluetoothA2DP]
        try rtc.setConfiguration(configuration)
        XCTAssertTrue(audio.categoryOptions.contains(.mixWithOthers))
        XCTAssertTrue(audio.categoryOptions.contains(.allowBluetoothA2DP))
        XCTAssertFalse(configuration.categoryOptions.contains(.mixWithOthers), "Caller-owned settings are not mutated")
        let mixed = GuestAudioSessionPolicy.mixing(configuration, currentMode: .voiceChat)
        XCTAssertEqual(mixed.mode, configuration.mode)
        XCTAssertEqual(mixed.sampleRate, configuration.sampleRate)
        XCTAssertEqual(mixed.ioBufferDuration, configuration.ioBufferDuration)
        XCTAssertEqual(mixed.inputNumberOfChannels, configuration.inputNumberOfChannels)
        XCTAssertEqual(mixed.outputNumberOfChannels, configuration.outputNumberOfChannels)
        XCTAssertTrue(GuestAudioSessionPolicy.mixing(mixed, currentMode: .voiceChat) === mixed)
    }

    func testSDKDefaultsCannotUndoAnExplicitCommunicationRouteMode() {
        let configuration = RTCAudioSessionConfiguration()
        configuration.category = AVAudioSession.Category.playAndRecord.rawValue
        configuration.mode = AVAudioSession.Mode.voiceChat.rawValue
        let speaker = GuestAudioSessionPolicy.mixing(configuration, currentMode: .videoChat)
        XCTAssertEqual(speaker.mode, AVAudioSession.Mode.videoChat.rawValue)
        XCTAssertEqual(configuration.mode, AVAudioSession.Mode.voiceChat.rawValue)
        XCTAssertEqual(GuestAudioSessionPolicy.mixing(speaker, currentMode: .voiceChat).mode, AVAudioSession.Mode.voiceChat.rawValue)
        configuration.mode = AVAudioSession.Mode.default.rawValue
        XCTAssertEqual(GuestAudioSessionPolicy.mixing(configuration, currentMode: .videoChat).mode, configuration.mode)
    }
}
