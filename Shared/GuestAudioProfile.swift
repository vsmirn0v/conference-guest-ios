import Foundation

/// Processing is selected before a physical audio owner and its source are created.
enum GuestAudioProfile: String, CaseIterable {
    case speech, music
    static let preferenceKey = "nativeDesktop.audioProfile"
    static var saved: Self { Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .speech }
    var usesPlatformVoiceProcessing: Bool { self == .speech }
    var audioConstraints: [String: String] {
        ["googEchoCancellation": "true", "googNoiseSuppression": self == .speech ? "true" : "false",
         "googAutoGainControl": self == .speech ? "true" : "false"]
    }
}
