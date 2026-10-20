import Foundation
import UIKit

@MainActor
protocol MeetingActivityDriver: AnyObject {
    var available: Bool { get }
    var onDismiss: ((String) -> Void)? { get set }
    func existingIDs() -> [String]
    func start(_ snapshot: MeetingActivitySnapshot, staleDate: Date) throws -> String
    func update(_ id: String, snapshot: MeetingActivitySnapshot, staleDate: Date) async
    func end(_ id: String) async
}

/// One serialized writer. A late update can never recreate an ended meeting.
@MainActor
final class MeetingActivityCoordinator {
    static let enabledKey = "MeetingLiveActivityEnabled"
    static let titleKey = "MeetingLiveActivityShowTitle"
    private let driver: any MeetingActivityDriver
    private let now: () -> Date
    private let foreground: () -> Bool
    private var desired: MeetingActivitySnapshot?
    private var current: (id: String, snapshot: MeetingActivitySnapshot, sentAt: Date)?
    private var dismissedSession: UUID?
    private var failedSession: UUID?
    private var revision = 0
    private var initialCleanupDone = false
    private(set) var task: Task<Void, Never>?
    var isRunning: Bool { current != nil }

    init(driver: any MeetingActivityDriver, now: @escaping () -> Date = Date.init,
         foreground: @escaping () -> Bool = { UIApplication.shared.applicationState == .active }) {
        self.driver = driver; self.now = now; self.foreground = foreground
        driver.onDismiss = { [weak self] id in
            guard let self, self.current?.id == id else { return }
            self.dismissedSession = self.current?.snapshot.sessionID
            self.current = nil
        }
    }

    func update(_ snapshot: MeetingActivitySnapshot?) {
        if desired?.sessionID != snapshot?.sessionID { failedSession = nil }
        desired = snapshot
        revision &+= 1
        guard task == nil else { return }
        task = Task { [weak self] in await self?.drain() }
    }

    func foregrounded() { failedSession = nil }

    private func drain() async {
        if !initialCleanupDone {
            initialCleanupDone = true
            for id in driver.existingIDs() { await driver.end(id) }
        }
        var processed: Int
        repeat {
            processed = revision
            let target = desired
            if let owned = current, owned.snapshot.sessionID != target?.sessionID || !driver.available {
                current = nil
                await driver.end(owned.id)
                if processed != revision { continue }
            }
            guard let target, driver.available,
                  target.sessionID != dismissedSession, target.sessionID != failedSession else { continue }
            let date = now()
            if let owned = current {
                guard owned.snapshot != target || date.timeIntervalSince(owned.sentAt) >= 60 else { continue }
                await driver.update(owned.id, snapshot: target, staleDate: date.addingTimeInterval(150))
                if current?.id == owned.id { current = (owned.id, target, date) }
            } else if foreground() {
                do {
                    let id = try driver.start(target, staleDate: date.addingTimeInterval(150))
                    current = (id, target, date)
                } catch { failedSession = target.sessionID }
            }
        } while processed != revision
        task = nil
    }
}

@MainActor
final class UnavailableMeetingActivityDriver: MeetingActivityDriver {
    var available: Bool { false }
    var onDismiss: ((String) -> Void)?
    func existingIDs() -> [String] { [] }
    func start(_ snapshot: MeetingActivitySnapshot, staleDate: Date) throws -> String { throw CocoaError(.featureUnsupported) }
    func update(_ id: String, snapshot: MeetingActivitySnapshot, staleDate: Date) async {}
    func end(_ id: String) async {}
}
