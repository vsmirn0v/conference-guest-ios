import UIKit
import CloudKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        NativeH264ColorEncoder.prepare()
        return true
    }
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let subscription = CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID
        guard subscription == "SavedJamsChanges" || subscription == "ActiveJamsChanges" else {
            completionHandler(.noData); return
        }
        Task { @MainActor in
            if subscription == "ActiveJamsChanges" {
                await MeetingContinuationCoordinator.active?.refresh()
                completionHandler(.newData); return
            }
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
