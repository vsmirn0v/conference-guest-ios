import UIKit
import CloudKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID == "SavedJamsChanges" else {
            completionHandler(.noData); return
        }
        Task { @MainActor in
            guard let sync = RoomSyncCoordinator.active, sync.enabled else { completionHandler(.noData); return }
            await sync.synchronizeForNotification()
            completionHandler(.newData)
        }
    }
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}
