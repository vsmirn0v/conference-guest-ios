import ConferenceCore
import Foundation

/// Handoff advertises a private-cloud lookup key, never a meeting invitation.
enum NativeDesktopHandoff {
    static let activityType = "dev.vsmirn0v.conferenceguest.continue-jam"

    struct Reference: Equatable {
        let deviceID: String
        let sessionID: UUID
    }

    static func activity(for jam: ActiveJam, now: Date = Date()) -> NSUserActivity {
        let activity = NSUserActivity(activityType: activityType)
        activity.title = L("Continue jam")
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        activity.userInfo = ["device": jam.deviceID, "session": jam.sessionID.uuidString]
        activity.requiredUserInfoKeys = ["device", "session"]
        activity.expirationDate = now.addingTimeInterval(180)
        return activity
    }

    static func reference(in activity: NSUserActivity) -> Reference? {
        guard activity.activityType == activityType,
              let device = activity.userInfo?["device"] as? String, !device.isEmpty,
              let session = activity.userInfo?["session"] as? String,
              let id = UUID(uuidString: session) else { return nil }
        return Reference(deviceID: device, sessionID: id)
    }
}
