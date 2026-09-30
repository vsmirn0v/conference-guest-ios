import CloudKit
import Combine
import ConferenceCore
import Foundation
import Network
import UIKit

@MainActor
final class RoomSyncCoordinator: ObservableObject {
    static weak var active: RoomSyncCoordinator?
    struct NameChoice: Identifiable {
        let id = UUID()
        let local: String
        let cloud: String
    }
    private struct State: Codable {
        var document = RoomSyncDocument()
        var enabled = false
        var includeRecent = true
        var owner: String?
        var generation: String?
        var token: Data?
        var acknowledged: [String: RoomSyncRecord] = [:]
        var needsInitialNameCheck = true
        var conflictingLocalName: String?
        var conflictingCloudName: String?
    }
    @Published private(set) var enabled = false
    @Published private(set) var includeRecent = true
    @Published private(set) var status = "Stored on this device"
    @Published private(set) var nameChoice: NameChoice?
    @Published private(set) var needsFreshAccount = false
    @Published private(set) var busy = false
    @Published private(set) var storageWarning: String?
    @Published private(set) var offerSync = false
    private var state: State
    private let history: RoomHistoryStore
    private let storage: any RoomHistoryStorage
    private let transport: any RoomCloudTransport
    private let preferences: UserDefaults
    private var task: Task<Void, Never>?
    private var revision = 0
    private var anotherPass = false
    private var nameDraft: String
    private var nameAtEditStart: String?
    private var observers: [NSObjectProtocol] = []
    private var networkMonitor: NWPathMonitor?
    private var networkWasAvailable = false
    var onRemoteName: ((String) -> Void)?
    var canDeleteSyncedData: Bool { state.owner != nil && state.generation != nil && !needsFreshAccount }

    init(history: RoomHistoryStore, name: String, preferences: UserDefaults = .standard,
         storage: any RoomHistoryStorage = KeychainRoomHistoryStorage(service: "dev.vsmirn0v.conferenceguest.icloud-replica"),
         transport: (any RoomCloudTransport)? = nil) {
        self.history = history; self.storage = storage; self.transport = transport ?? CloudRoomTransport()
        self.preferences = preferences; nameDraft = name
        if let data = storage.read(), let restored = try? JSONDecoder().decode(State.self, from: data) {
            state = restored
        } else {
            state = State()
            for room in history.rooms { state.document.upsert(room, visited: true) }
            if !name.isEmpty { state.document.setName(name) }
        }
        enabled = state.enabled; includeRecent = state.includeRecent
        status = enabled ? "Changes pending" : "Stored on this device"
        if let local = state.conflictingLocalName {
            nameChoice = NameChoice(local: local, cloud: state.conflictingCloudName ?? state.document.name?.value ?? "")
        }
        history.onLocalChange = { [weak self] change in self?.localChange(change) }
        observers.append(NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.requestSync(immediate: true) }
        })
        Self.active = self
        if enabled {
            monitorNetwork()
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    deinit {
        task?.cancel()
        networkMonitor?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func nameDidChange(_ name: String) {
        nameDraft = name
        guard nameAtEditStart == nil else { return }
        state.document.setName(name)
        resolveNameChoiceIfNeeded()
        changed()
    }

    func beginNameEditing() { nameAtEditStart = nameDraft }
    func endNameEditing() {
        guard let original = nameAtEditStart else { return }
        nameAtEditStart = nil
        if nameDraft != original { nameDidChange(nameDraft) }
        else { applyName() }
    }

    func chooseName(useCloud: Bool) {
        guard let choice = nameChoice else { return }
        state.document.setName(useCloud ? choice.cloud : choice.local)
        nameDraft = useCloud ? choice.cloud : choice.local
        resolveNameChoiceIfNeeded(); changed(); onRemoteName?(nameDraft)
    }

    private func resolveNameChoiceIfNeeded() {
        nameChoice = nil; state.conflictingLocalName = nil; state.conflictingCloudName = nil
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        revision += 1; task?.cancel(); task = nil
        enabled = value; state.enabled = value
        if value {
            status = "Connecting to iCloud…"
            state.needsInitialNameCheck = state.needsInitialNameCheck || state.generation == nil
            UIApplication.shared.registerForRemoteNotifications()
            monitorNetwork()
        } else {
            status = "Stored on this device"
            networkMonitor?.cancel(); networkMonitor = nil
            keepLocalNameWhenPausing()
        }
        _ = persist()
        if value { requestSync(immediate: true) }
    }

    func setIncludeRecent(_ value: Bool) {
        guard value != includeRecent else { return }
        includeRecent = value; state.includeRecent = value
        changed()
    }

    func startFreshForCurrentAccount() {
        revision += 1; task?.cancel(); task = nil
        state = State(); enabled = false; includeRecent = true
        history.applySyncedRooms([])
        nameDraft = ""; onRemoteName?("")
        needsFreshAccount = false; nameChoice = nil
        _ = persist(); setEnabled(true)
    }

    func dismissOffer() {
        offerSync = false
        preferences.set(true, forKey: "iCloudSyncOfferSeen")
    }

    func foregrounded() { requestSync(immediate: true) }

    private func monitorNetwork() {
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        networkWasAvailable = true
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let available = path.status == .satisfied
                if available && !self.networkWasAvailable { self.requestSync(immediate: true) }
                self.networkWasAvailable = available
            }
        }
        networkMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "dev.vsmirn0v.conferenceguest.sync-network", qos: .utility))
    }

    func synchronizeForNotification() async {
        requestSync(immediate: true)
        await task?.value
    }

    func requestSync(immediate: Bool = false) {
        guard enabled, !needsFreshAccount else { return }
        if busy { anotherPass = true; return }
        task?.cancel()
        let expected = revision
        task = Task { [weak self] in
            if !immediate {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            guard let self, expected == self.revision, self.enabled else { return }
            await self.synchronize(revision: expected)
        }
    }

    private func localChange(_ change: RoomHistoryChange) {
        switch change {
        case .upsert(let room, let visited): state.document.upsert(room, visited: visited)
        case .remove(let id): state.document.remove(id)
        }
        if includeRecent { state.document.trimHistory() }
        changed()
        if !enabled && !preferences.bool(forKey: "iCloudSyncOfferSeen") { offerSync = true }
    }

    private func changed() {
        if enabled { status = "Changes pending" }
        if persist() { requestSync() }
    }

    @discardableResult private func persist() -> Bool {
        do {
            try storage.write(JSONEncoder().encode(state))
            storageWarning = nil; return true
        } catch {
            storageWarning = "Sync changes are not saved on this device yet. Retry before closing the app."
            return false
        }
    }

    private func valid(_ expected: Int) -> Bool { expected == revision && enabled && !Task.isCancelled }

    private func synchronize(revision expected: Int) async {
        guard persist() else { return }
        busy = true; anotherPass = false
        defer {
            busy = false
            if expected == revision {
                task = nil
                if anotherPass { requestSync() }
            } else if enabled {
                requestSync(immediate: true)
            }
        }
        do {
            let session = try await transport.connect()
            guard valid(expected) else { return }
            if let owner = state.owner, owner != session.account {
                needsFreshAccount = true
                pause("Apple Account changed. Start fresh to sync with this account.")
                return
            }
            if let generation = state.generation, generation != session.generation {
                state.generation = nil; state.token = nil; state.acknowledged = [:]
                pause("Synced data was deleted. Sync is off; your local data remains.")
                return
            }
            state.owner = session.account; state.generation = session.generation
            for attempt in 0..<3 {
                let changes = try await transport.fetch(session: session, after: state.token)
                guard valid(expected) else { return }
                let localName = nameDraft
                let incomingName = changes.records.compactMap { record -> SyncValue<String>? in
                    if case .profile(let name) = record { return name }; return nil
                }.max { $0.version < $1.version }?.value
                state.document.merge(changes.records)
                if state.needsInitialNameCheck {
                    state.needsInitialNameCheck = false
                    if let cloud = incomingName, !localName.isEmpty, localName != cloud {
                        state.conflictingLocalName = localName
                        state.conflictingCloudName = cloud
                        nameChoice = NameChoice(local: localName, cloud: cloud)
                    }
                } else if let local = state.conflictingLocalName, let cloud = incomingName,
                          cloud != state.conflictingCloudName {
                    state.conflictingCloudName = cloud
                    nameChoice = NameChoice(local: local, cloud: cloud)
                }
                for record in changes.records {
                    state.acknowledged[record.id] = record
                }
                state.token = changes.token
                if includeRecent { state.document.trimHistory() }
                guard persist() else { return }
                applyRooms(); applyName()
                let outgoing = pendingRecords
                guard !outgoing.isEmpty else {
                    status = nameChoice == nil ? "Up to date" : "Choose the name to use across devices"
                    return
                }
                do {
                    let saved = try await transport.save(outgoing, session: session)
                    guard valid(expected) else { return }
                    state.document.merge(saved)
                    for record in saved { state.acknowledged[record.id] = record }
                    guard persist() else { return }
                    applyRooms(); applyName()
                    if pendingRecords.isEmpty {
                        status = nameChoice == nil ? "Up to date" : "Choose the name to use across devices"
                        return
                    }
                } catch RoomCloudError.conflict where attempt < 2 {
                    continue
                }
            }
            status = "Changes pending. Sync again when convenient."
        } catch {
            guard expected == revision else { return }
            switch error {
            case RoomCloudError.noAccount: status = "iCloud unavailable. Your changes stay on this device."
            case RoomCloudError.restricted: status = "iCloud is restricted on this device."
            case RoomCloudError.generationChanged:
                state.generation = nil; state.token = nil; state.acknowledged = [:]
                pause("Synced data was deleted. Sync is off; your local data remains.")
            case RoomCloudError.incompatibleData: status = "Update the app on all devices before syncing."
            default: status = "Changes pending. iCloud will retry when the app opens or you tap Sync now."
            }
            _ = persist()
        }
    }

    private var pendingRecords: [RoomSyncRecord] {
        state.document.records.filter { record in
            if state.acknowledged[record.id] == record { return false }
            switch record {
            case .profile: return nameChoice == nil
            case .room(let room):
                if includeRecent || room.starred.value { return true }
                if case .room(let previous) = state.acknowledged[room.id] { return previous.starred.value }
                return false
            }
        }
    }

    private func applyRooms() {
        let incoming: [RecentRoom]
        if includeRecent { incoming = state.document.visibleRooms }
        else {
            let favorites = state.document.visibleRooms.filter(\.isStarred)
            let favoriteIDs = Set(favorites.map(\.id))
            incoming = favorites + history.rooms.filter { room in
                !favoriteIDs.contains(room.id) &&
                (state.document.rooms[room.id]?.exists.value ?? true)
            }.map { room in
                var local = room; local.isStarred = false; return local
            }
        }
        history.applySyncedRooms(incoming)
    }

    private func applyName() {
        guard nameAtEditStart == nil, nameChoice == nil, let name = state.document.name?.value,
              nameDraft != name else { return }
        nameDraft = name; onRemoteName?(name)
    }

    private func pause(_ message: String) {
        enabled = false; state.enabled = false; status = message
        networkMonitor?.cancel(); networkMonitor = nil
        keepLocalNameWhenPausing()
        _ = persist()
    }

    private func keepLocalNameWhenPausing() {
        guard nameChoice != nil else { return }
        state.document.setName(nameDraft)
        state.needsInitialNameCheck = true
        state.token = nil
        resolveNameChoiceIfNeeded()
    }

    func deleteSyncedData() async {
        guard !busy else { return }
        revision += 1; task?.cancel(); task = nil
        let expected = revision
        busy = true
        defer { busy = false }
        do {
            let session = try await transport.connect()
            guard expected == revision, let owner = state.owner, owner == session.account,
                  state.generation == session.generation else { throw RoomCloudError.generationChanged }
            try await transport.clear(session: session)
            guard expected == revision else { return }
            state.generation = nil; state.token = nil; state.acknowledged = [:]
            pause("Synced data deleted. Your local rooms and name remain on this device.")
        } catch { status = "Could not delete synced data. Check iCloud and try again." }
    }
}
