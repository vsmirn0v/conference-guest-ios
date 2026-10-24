import UIKit

/// A separate signed app ID exercises CloudKit without loading the product's
/// models, preferences, keychain, reminders, calendars, transcripts or media.
@main final class CloudProbeAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool { true }
}
