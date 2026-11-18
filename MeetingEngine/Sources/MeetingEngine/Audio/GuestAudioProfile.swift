import Foundation

/// Processing is selected before a physical audio owner and its source are created.
public enum GuestAudioProfile: String, CaseIterable {
    case speech, music
    public static let preferenceKey = "nativeDesktop.audioProfile"
    public static var saved: Self { Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .speech }
    public var usesPlatformVoiceProcessing: Bool { self == .speech }
    public var audioConstraints: [String: String] {
        ["googEchoCancellation": "true", "googNoiseSuppression": self == .speech ? "true" : "false",
         "googAutoGainControl": self == .speech ? "true" : "false"]
    }
}
