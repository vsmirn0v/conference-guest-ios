import SwiftUI

/// Local preference, deliberately absent from synced meeting/provider identities.
enum NativeGuestPreference {
    static let key = "mac.nativeGuestPreview.enabled"
    static func enabled(isMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac,
                        companionSupported: Bool = NativeGuestCompanionBridge.isSupported(),
                        defaults: UserDefaults = .standard) -> Bool {
        isMac && companionSupported && defaults.bool(forKey: key)
    }
}

struct NativeGuestSettingsView: View {
    @AppStorage(NativeGuestPreference.key) private var enabled = false
    @State private var companionReady = false
    var body: some View {
        Form {
            Section {
                Toggle(L("Native guest engine (Preview)"), isOn: $enabled)
                    .accessibilityIdentifier("settings.nativeGuest.enabled")
                Text(L("Applies to the next guest meeting on this Mac. The native companion opens its own meeting window."))
            }
            Section(L("Available in this preview")) {
                Label(L("Meeting audio and camera"), systemImage: "video")
                Label(L("Incoming video and screen shares"), systemImage: "rectangle.on.rectangle")
                Text(L("Sending screen shares, Presenter, chat, reactions and transcription are not available yet. Use the standard engine when you need these features."))
            }
            Section(L("Companion app")) {
                Text(L("Install the separately signed Rock'N'Roll for Mac companion on this Mac before enabling the preview."))
                Text(companionStatus).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.nativeGuest.companionStatus")
            }
        }.navigationTitle(L("Native guest preview"))
            .task { companionReady = await NativeGuestCompanionEngine.companionAvailable() }
    }
    private var companionStatus: String {
        return companionReady ?
            L("Companion is ready") : L("Companion is not installed or could not be verified")
    }
}
