import Foundation

/// All descriptor IO/fsync is kept off the UI actor.
actor CompanionFiles {
    private let store: NativeGuestSessionStore
    init(store: NativeGuestSessionStore) { self.store = store }
    func admit(_ id: UUID?, processID: Int32) async throws -> NativeGuestTicket? {
        // Snapshot the candidate once; an idle helper never watches future joins.
        let ticket: NativeGuestTicket?
        if let id { ticket = try store.readTicket(id) }
        else { ticket = try store.pendingLaunchTicket() }
        guard let ticket else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            let command = try store.readCommand(ticket.metadata.sessionID)
            guard command?.leave == false else { throw NativeGuestStoreError.incompatibleRecord }
            if let expected = command?.expectedHelperPID {
                guard expected == processID else { throw NativeGuestStoreError.incompatibleRecord }
                return try store.consumeTicket(ticket.metadata.sessionID, boundTo: processID)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NativeGuestStoreError.expiredRecord
    }
    func command(_ id: UUID) throws -> NativeGuestCommand? { try store.readCommand(id) }
    func heartbeat(_ id: UUID) throws -> NativeGuestHeartbeat? { try store.readHeartbeat(id) }
    func status(_ status: NativeGuestStatus) throws { try store.writeStatus(status) }
}
