#if DEBUG
import CloudKit
import ConferenceCore
import Foundation
import UIKit

/// Explicit live-media/cloud test mode uses only generated QA meetings. It does
/// not enable preference/history sync or change the user's saved display name.
@MainActor
enum MeetingContinuationLiveFixture {
    static func configure(_ model: ConferenceModel) {
        guard let marker = ProcessInfo.processInfo.environment["CONFERENCE_TEST_HANDOFF_CLOUD"] else { return }
        let preferences = UserDefaults(suiteName: "ContinuationLive-" + marker)!
        preferences.set(true, forKey: "shareActiveJams")
        let coordinator = model.makeContinuationCoordinator(preferences: preferences)
        model.installContinuationFixture(coordinator)
        Task { [weak model] in
            do {
                let account = try await CKContainer(identifier: CloudRoomTransport.containerIdentifier).userRecordID().recordName
                coordinator.setCloudAccount(account)
                UIApplication.shared.registerForRemoteNotifications()
                await coordinator.refresh()
                if let link = ProcessInfo.processInfo.environment["CONFERENCE_TEST_HANDOFF_SOURCE_LINK"], let url = URL(string: link) {
                    let jam = ActiveJam(deviceID: "generated-source", invitation: url, title: "Handoff QA", name: "Transfer QA " + marker.prefix(6), deviceLabel: "Mac")
                    model?.joinFromContinuation(jam, quiet: false)
                }
            } catch { coordinator.setCloudAccount(nil) }
        }
    }
}
#else
@MainActor enum MeetingContinuationLiveFixture { static func configure(_ model: ConferenceModel) {} }
#endif
