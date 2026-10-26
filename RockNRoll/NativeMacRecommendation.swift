import SwiftUI

/// Device-local discovery of the separately installed Mac app. No installation
/// detection, network request, meeting transfer or update mechanism is involved.
@MainActor final class NativeMacRecommendation: ObservableObject {
    static let dismissedKey = "mac.nativeAppRecommendation.dismissed"
    static let downloadPage = URL(string: "https://rock.glowsoft.ru/#download")!
    let isSupportedHost: Bool
    @Published private(set) var dismissed: Bool
    @Published private(set) var suppressedForLaunch = false
    private let preferences: UserDefaults

    init(isSupportedHost: Bool = ProcessInfo.processInfo.isiOSAppOnMac, preferences: UserDefaults = .standard) {
        self.isSupportedHost = isSupportedHost; self.preferences = preferences
        dismissed = preferences.bool(forKey: Self.dismissedKey)
    }
    func showsNotice(isIdle: Bool) -> Bool { isSupportedHost && !dismissed && !suppressedForLaunch && isIdle }
    /// Once meeting activity starts, never insert a promotional row back into
    /// an already interactive Home, even if joining or continuation fails.
    func observeMeetingActivity(_ busy: Bool) { if busy { suppressedForLaunch = true } }
    func dismiss() { dismissed = true; preferences.set(true, forKey: Self.dismissedKey) }
    func visitDownloadPage(using open: (URL) -> Void) {
        guard isSupportedHost else { return }
        open(Self.downloadPage)
    }
    static func current() -> NativeMacRecommendation {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let host = environment["CONFERENCE_TEST_MAC_RECOMMENDATION"], ["mac", "ios"].contains(host),
           let rawID = environment["CONFERENCE_TEST_MAC_RECOMMENDATION_ID"], let id = UUID(uuidString: rawID),
           let preferences = UserDefaults(suiteName: "NativeMacRecommendation.UIFixture." + id.uuidString) {
            if environment["CONFERENCE_TEST_MAC_RECOMMENDATION_RESET"] == "1" { preferences.removeObject(forKey: dismissedKey) }
            return NativeMacRecommendation(isSupportedHost: host == "mac", preferences: preferences)
        }
        #endif
        return NativeMacRecommendation()
    }
}

struct NativeMacRecommendationCard: View {
    @ObservedObject var recommendation: NativeMacRecommendation
    let getApp: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Label(L("Rock'N'Roll for Mac is ready"), systemImage: "desktopcomputer").font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button { recommendation.dismiss() } label: { Image(systemName: "xmark").frame(minWidth: 32, minHeight: 32) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .accessibilityLabel(L("Dismiss Mac app recommendation"))
                    .accessibilityIdentifier("nativeMacRecommendation.dismiss")
            }
            Text(L("We recommend the native Mac app for meetings on this Mac."))
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(action: getApp) { Label(L("Get the Mac app"), systemImage: "arrow.up.right") }
                .buttonStyle(.borderless).padding(.vertical, 4)
                .accessibilityHint(L("Opens the official download page in your browser."))
                .accessibilityIdentifier("nativeMacRecommendation.download")
        }.padding(.vertical, 4)
    }
}

struct NativeMacRecommendationDetails: View {
    let getApp: () -> Void
    var body: some View {
        Form {
            Section {
                Label(L("Rock'N'Roll for Mac is ready"), systemImage: "desktopcomputer").font(.headline)
                Text(L("We recommend the native Mac app for meetings on this Mac."))
                Text(L("Mac windows, menu-bar controls and automatic updates."))
                    .foregroundStyle(.secondary)
                Button(action: getApp) { Label(L("Get the Mac app"), systemImage: "arrow.up.right") }
                    .accessibilityHint(L("Opens the official download page in your browser."))
                    .accessibilityIdentifier("nativeMacRecommendation.settings.download")
            } footer: {
                Text(L("Requires Apple Silicon and macOS 13 or later."))
            }
            Section {
                Text(L("You can keep using this app."))
                Text(L("To sync your name and saved invitations, enable iCloud sync in both apps with the same Apple Account."))
                    .foregroundStyle(.secondary)
            }
        }.navigationTitle(L("Rock'N'Roll for Mac"))
    }
}
