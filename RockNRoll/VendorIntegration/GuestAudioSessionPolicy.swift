import AVFoundation
import ObjectiveC
import WebRTC

/// Normalize the guest SDK's public configuration requests before comparison
/// and activation. A later repair has already interrupted the other app, and
/// decorating individual setters makes the SDK repeatedly retry the old options.
/// Activation, locking, errors and interruption ownership remain unchanged.
enum GuestAudioSessionPolicy {
    static func prepare() { _ = installed }

    static func options(category: String, requested: AVAudioSession.CategoryOptions) -> AVAudioSession.CategoryOptions {
        guard category == AVAudioSession.Category.playAndRecord.rawValue ||
              category == AVAudioSession.Category.playback.rawValue else { return requested }
        return requested.union(.mixWithOthers)
    }

    static func mixing(_ source: RTCAudioSessionConfiguration,
                       currentMode: AVAudioSession.Mode = AVAudioSession.sharedInstance().mode) -> RTCAudioSessionConfiguration {
        let desired = options(category: source.category, requested: source.categoryOptions)
        // Speaker/receiver selection belongs to AudioCoordinator. The provider's
        // automatic voice-chat default must not undo that choice on activation.
        let voiceModes = [AVAudioSession.Mode.voiceChat.rawValue, AVAudioSession.Mode.videoChat.rawValue]
        let mode = source.category == AVAudioSession.Category.playAndRecord.rawValue &&
            voiceModes.contains(source.mode) && voiceModes.contains(currentMode.rawValue) ? currentMode.rawValue : source.mode
        guard desired != source.categoryOptions || mode != source.mode else { return source }
        // The caller can reuse its object. Never mutate its shared configuration.
        let copy = RTCAudioSessionConfiguration()
        copy.category = source.category; copy.mode = mode; copy.categoryOptions = desired
        copy.sampleRate = source.sampleRate; copy.ioBufferDuration = source.ioBufferDuration
        copy.inputNumberOfChannels = source.inputNumberOfChannels
        copy.outputNumberOfChannels = source.outputNumberOfChannels
        return copy
    }

    private static let installed: Void = {
        let configuration = RTCAudioSessionConfiguration()
        configuration.category = AVAudioSession.Category.playAndRecord.rawValue
        configuration.mode = AVAudioSession.Mode.videoChat.rawValue
        configuration.categoryOptions = AudioCoordinator.communicationOptions
        configuration.sampleRate = 48_000
        RTCAudioSessionConfiguration.setWebRTC(configuration)
        let configure = NSSelectorFromString("setConfiguration:error:")
        if let method = class_getInstanceMethod(RTCAudioSession.self, configure) {
            typealias Set = @convention(c) (AnyObject, Selector, RTCAudioSessionConfiguration, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
            let original = unsafeBitCast(method_getImplementation(method), to: Set.self)
            let forward: @convention(block) (AnyObject, RTCAudioSessionConfiguration, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool = { session, configuration, error in
                original(session, configure, mixing(configuration), error)
            }
            method_setImplementation(method, imp_implementationWithBlock(forward))
        }
        let activate = NSSelectorFromString("setConfiguration:active:error:")
        if let method = class_getInstanceMethod(RTCAudioSession.self, activate) {
            typealias Set = @convention(c) (AnyObject, Selector, RTCAudioSessionConfiguration, Bool, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
            let original = unsafeBitCast(method_getImplementation(method), to: Set.self)
            let forward: @convention(block) (AnyObject, RTCAudioSessionConfiguration, Bool, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool = { session, configuration, active, error in
                original(session, activate, mixing(configuration), active, error)
            }
            method_setImplementation(method, imp_implementationWithBlock(forward))
        }
    }()
}
