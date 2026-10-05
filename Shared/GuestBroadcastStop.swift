import Foundation

/// App-to-extension control; independent of the provider's picker UI.
enum GuestBroadcastStop {
    static let notification = CFNotificationName("dev.vsmirn0v.conferenceguest.stop-broadcast" as CFString)

    private static var permissionURL: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "RTCAppGroupIdentifier") as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("guest-broadcast-permission")
    }

    static var isPermitted: Bool {
        guard let permissionURL else { return false }
        return FileManager.default.fileExists(atPath: permissionURL.path)
    }

    static func prepare() -> Bool {
        guard let permissionURL else { return false }
        do {
            try Data([1]).write(to: permissionURL, options: .atomic)
            #if DEBUG
            OutgoingShareExperiment.prepareBroadcastConfiguration()
            #endif
            return true
        } catch { return false }
    }

    static func request() {
        // Persistent revocation closes the race where Leave is tapped during
        // ReplayKit's countdown, before the extension registers its observer.
        if let permissionURL { try? FileManager.default.removeItem(at: permissionURL) }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             notification, nil, nil, true)
    }
}
