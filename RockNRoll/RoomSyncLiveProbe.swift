#if DEBUG
import ConferenceCore
import UIKit

/// Opt-in real-cloud probe for runtimes that cannot host XCTest (iOS app on Mac).
@MainActor
enum RoomSyncLiveProbe {
    static func runIfRequested(window: UIWindow) -> Bool {
        guard ProcessInfo.processInfo.environment["ROCK_CLOUD_SMOKE"] == "1" else { return false }
        let controller = UIViewController()
        let label = UILabel(); label.numberOfLines = 0; label.textAlignment = .center
        label.text = "Checking private iCloud round trip…"
        label.accessibilityIdentifier = "Cloud round trip result"
        controller.view.backgroundColor = .systemBackground
        controller.view.addSubview(label); label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor)
        ])
        window.rootViewController = controller
        Task {
            do {
                let marker = UUID().uuidString
                let url = URL(string: "https://sync-fixture.example.test/\(marker)?psw=generated-fixture")!
                let writer = CloudRoomTransport(zoneName: "SyncVerification-" + marker, notifications: false)
                let reader = CloudRoomTransport(zoneName: "SyncVerification-" + marker, notifications: false)
                let session = try await writer.connect()
                var document = RoomSyncDocument()
                document.setName("Sync fixture musician")
                var room = RecentRoom(invitationURL: url, title: "Cloud sync fixture", identifier: "fixture",
                                      isStarred: true, lastJoined: Date())
                room.alias = "Friday sync check"
                room.favoritePosition = 0
                document.upsert(room, visited: true)
                _ = try await writer.save(document.records, session: session)
                let readerSession = try await reader.connect()
                guard readerSession == session else { throw RoomCloudError.noAccount }
                let changes = try await reader.fetch(session: readerSession, after: nil)
                var restored = RoomSyncDocument(); restored.merge(changes.records)
                guard restored.visibleRooms.contains(room), restored.name?.value == "Sync fixture musician" else {
                    throw RoomCloudError.incompatibleData
                }
                document.remove(url.absoluteString)
                _ = try await writer.save(document.records, session: session)
                let delta = try await reader.fetch(session: readerSession, after: changes.token)
                restored.merge(delta.records)
                guard !restored.visibleRooms.contains(where: { $0.invitationURL == url }) else { throw RoomCloudError.incompatibleData }
                try await writer.deleteVerificationZone()
                label.text = "Private iCloud round trip passed\nEncrypted invitation, favorite, room alias, display name and deletion verified.\nTemporary verification zone removed."
            } catch {
                let ns = error as NSError
                label.text = "Cloud check failed\n\(ns.domain) (\(ns.code))\n\(ns.localizedDescription)"
            }
        }
        return true
    }
}
#endif
