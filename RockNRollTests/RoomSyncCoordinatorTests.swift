import XCTest
import ConferenceCore
@testable import RockNRoll

@MainActor
final class RoomSyncCoordinatorTests: XCTestCase {
    func testFavoriteOrderSyncsBothWaysWhileRecentHistoryIsExcluded() async {
        let cloud = Cloud()
        let (mac, macSync) = replica(cloud)
        let (phone, phoneSync) = replica(cloud)
        macSync.setIncludeRecent(false); phoneSync.setIncludeRecent(false)
        for index in 0..<3 {
            let url = URL(string: "https://example.test/\(index)?psw=fixture")!
            mac.record(url: url, title: "Room \(index)", identifier: "\(index)")
            mac.toggleStar(url)
        }
        macSync.setEnabled(true); await sync(macSync)
        phoneSync.setEnabled(true); await sync(phoneSync)
        XCTAssertEqual(phone.rooms.map(\.id), mac.rooms.map(\.id))
        phone.moveFavorites(from: IndexSet(integer: 2), to: 0)
        await sync(phoneSync); await sync(macSync)
        XCTAssertEqual(mac.rooms.map(\.identifier), ["0", "2", "1"])
        XCTAssertEqual(phone.rooms.map(\.id), mac.rooms.map(\.id))
        mac.moveFavorites(from: IndexSet(integer: 0), to: 3)
        await sync(macSync); await sync(phoneSync)
        XCTAssertEqual(phone.rooms.map(\.identifier), ["2", "1", "0"])
    }
    final class Storage: RoomHistoryStorage {
        var data: Data?
        var failing = false
        func read() -> Data? { data }
        func write(_ data: Data) throws {
            if failing { throw NSError(domain: "Storage", code: 1) }
            self.data = data
        }
    }
    final class Cloud: RoomCloudTransport {
        var account = "account-A"
        var generation = "generation-A"
        var available = true
        var records: [String: RoomSyncRecord] = [:]
        var saves = 0
        var conflicts = 0
        var receivedTokens: [Data?] = []
        var saveGate: (() async -> Void)?
        func connect() async throws -> RoomCloudSession {
            guard available else { throw RoomCloudError.noAccount }
            return .init(account: account, generation: generation)
        }
        func fetch(session: RoomCloudSession, after token: Data?) async throws -> RoomCloudChanges {
            receivedTokens.append(token)
            guard session.account == account, session.generation == generation else { throw RoomCloudError.generationChanged }
            return .init(records: Array(records.values), token: Data([1]))
        }
        func save(_ values: [RoomSyncRecord], session: RoomCloudSession) async throws -> [RoomSyncRecord] {
            if let gate = saveGate { await gate() }
            guard session.account == account, session.generation == generation else { throw RoomCloudError.generationChanged }
            if conflicts > 0 { conflicts -= 1; throw RoomCloudError.conflict }
            saves += 1
            return values.map { value in
                let merged = records[value.id].map { value.merging($0) } ?? value
                records[value.id] = merged; return merged
            }
        }
        func clear(session: RoomCloudSession) async throws { records = [:]; generation = UUID().uuidString }
    }
    private func preferences() -> UserDefaults {
        UserDefaults(suiteName: "RoomSyncTests-" + UUID().uuidString)!
    }
    private func replica(_ cloud: Cloud, name: String = "", state: Storage = Storage()) -> (RoomHistoryStore, RoomSyncCoordinator) {
        let history = RoomHistoryStore(storage: Storage())
        return (history, RoomSyncCoordinator(history: history, name: name, preferences: preferences(), storage: state, transport: cloud))
    }
    private func visit(_ history: RoomHistoryStore, _ code: String = "one") -> URL {
        let url = URL(string: "https://meeting.example.test/\(code)?psw=secret")!
        history.record(url: url, title: "Rehearsal", identifier: code)
        return url
    }
    private func sync(_ coordinator: RoomSyncCoordinator) async {
        if !coordinator.enabled { coordinator.setEnabled(true) }
        await coordinator.synchronizeForNotification()
    }

    func testTwoReplicasSyncFavoriteAliasDomainAndNameWithoutRepeatedWrites() async {
        let cloud = Cloud()
        let (phone, phoneSync) = replica(cloud, name: "Ani")
        let url = visit(phone); phone.toggleStar(url); phone.setAlias("Friday quartet", for: url)
        await sync(phoneSync)
        XCTAssertEqual(phoneSync.status, "Up to date")
        let (ipad, ipadSync) = replica(cloud)
        var receivedName = ""
        ipadSync.onRemoteName = { receivedName = $0 }
        await sync(ipadSync)
        XCTAssertEqual(phone.rooms, ipad.rooms)
        XCTAssertEqual(receivedName, "Ani")
        XCTAssertEqual(ipad.rooms[0].invitationURL, url)
        let count = cloud.saves
        await sync(ipadSync); await sync(phoneSync)
        XCTAssertEqual(cloud.saves, count)
    }

    func testOfflineChangesPersistAcrossRestartAndMergeIndependentEdits() async {
        let cloud = Cloud(), state = Storage()
        let (phone, firstSync) = replica(cloud, state: state)
        let url = visit(phone); await sync(firstSync)
        let (mac, macSync) = replica(cloud); await sync(macSync)
        cloud.available = false
        phone.toggleStar(url); await sync(firstSync)
        XCTAssertTrue(firstSync.status.contains("unavailable"))
        mac.setAlias("Friday quartet", for: url)
        cloud.available = true; await sync(macSync)
        let restoredSync = RoomSyncCoordinator(history: phone, name: "", preferences: preferences(), storage: state, transport: cloud)
        await sync(restoredSync); await sync(macSync)
        XCTAssertTrue(phone.rooms[0].isStarred)
        XCTAssertEqual(phone.rooms[0].alias, "Friday quartet")
        XCTAssertEqual(phone.rooms, mac.rooms)
    }

    func testInitialDifferentNamesAskOnceAndChoiceConverges() async {
        let cloud = Cloud()
        let (_, phone) = replica(cloud, name: "Ani"); await sync(phone)
        let (_, mac) = replica(cloud, name: "Aram")
        var applied = ""
        mac.onRemoteName = { applied = $0 }
        await sync(mac)
        XCTAssertNotNil(mac.nameChoice); XCTAssertEqual(applied, "")
        mac.chooseName(useCloud: false); await sync(mac); await sync(phone)
        XCTAssertNil(mac.nameChoice)
        XCTAssertEqual(applied, "Aram")
        guard case .profile(let name) = cloud.records["profile"] else { return XCTFail("Missing name") }
        XCTAssertEqual(name.value, "Aram")
    }

    func testUnresolvedNameChoiceSurvivesRestartWithOriginalCloudName() async {
        let cloud = Cloud(), persisted = Storage()
        let (_, first) = replica(cloud, name: "Ani"); await sync(first)
        let (history, second) = replica(cloud, name: "Aram", state: persisted)
        second.nameDidChange("Lilit"); second.nameDidChange("Aram")
        await sync(second)
        XCTAssertEqual(second.nameChoice?.cloud, "Ani")
        let restored = RoomSyncCoordinator(history: history, name: "Aram", preferences: preferences(), storage: persisted, transport: cloud)
        XCTAssertEqual(restored.nameChoice?.cloud, "Ani")
        XCTAssertEqual(restored.nameChoice?.local, "Aram")
        restored.chooseName(useCloud: true); await sync(restored)
        guard case .profile(let name) = cloud.records["profile"] else { return XCTFail("Missing name") }
        XCTAssertEqual(name.value, "Ani")
    }

    func testDisablingSyncDuringNameChoiceKeepsLocalName() async {
        let cloud = Cloud()
        let (_, first) = replica(cloud, name: "Ani"); await sync(first)
        let (_, second) = replica(cloud, name: "Aram")
        var applied = ""
        second.onRemoteName = { applied = $0 }
        await sync(second); XCTAssertNotNil(second.nameChoice)
        second.setEnabled(false)
        XCTAssertNil(second.nameChoice); XCTAssertEqual(applied, "")
        await sync(second)
        XCTAssertEqual(second.nameChoice?.local, "Aram")
        XCTAssertNil(cloud.receivedTokens.last!)
    }

    func testRemoteNameDoesNotOverwriteEditingAndLocalCommitWins() async {
        let cloud = Cloud()
        let (_, phone) = replica(cloud, name: "Ani"); await sync(phone)
        let (_, mac) = replica(cloud); await sync(mac)
        var applied = ""
        phone.onRemoteName = { applied = $0 }
        phone.beginNameEditing(); phone.nameDidChange("Aram")
        mac.nameDidChange("Lilit"); await sync(mac); await sync(phone)
        XCTAssertEqual(applied, "")
        phone.endNameEditing(); await sync(phone); await sync(mac)
        guard case .profile(let name) = cloud.records["profile"] else { return XCTFail("Missing name") }
        XCTAssertEqual(name.value, "Aram")
    }

    func testFavoritesOnlyDoesNotUploadNewRecentRoomsOrImportCloudHistory() async {
        let cloud = Cloud()
        let (phone, first) = replica(cloud)
        _ = visit(phone, "remote-recent"); await sync(first)
        let (ipad, second) = replica(cloud)
        second.setIncludeRecent(false)
        let local = visit(ipad, "local-recent")
        await sync(second)
        XCTAssertEqual(ipad.rooms.map(\.invitationURL), [local])
        XCTAssertNil(cloud.records[local.absoluteString])
        ipad.toggleStar(local); await sync(second); await sync(first)
        XCTAssertTrue(phone.rooms.contains { $0.invitationURL == local && $0.isStarred })
        ipad.toggleStar(local); await sync(second); await sync(first)
        XCTAssertFalse(phone.rooms.first { $0.invitationURL == local }!.isStarred)
    }

    func testAccountSwitchPausesWithoutUploadingOldInvitations() async {
        let cloud = Cloud()
        let (history, coordinator) = replica(cloud, name: "Ani")
        let url = visit(history); await sync(coordinator)
        cloud.account = "account-B"; cloud.generation = "generation-B"; cloud.records = [:]
        coordinator.requestSync(immediate: true); await coordinator.synchronizeForNotification()
        XCTAssertFalse(coordinator.enabled); XCTAssertTrue(coordinator.needsFreshAccount)
        XCTAssertTrue(cloud.records.isEmpty)
        XCTAssertEqual(history.rooms.first?.invitationURL, url)
        coordinator.startFreshForCurrentAccount(); await coordinator.synchronizeForNotification()
        XCTAssertTrue(history.rooms.isEmpty); XCTAssertFalse(coordinator.needsFreshAccount)
        XCTAssertTrue(cloud.records.isEmpty)
    }

    func testCloudDeletionFencesOutOfflineDeviceButRetainsItsLocalData() async {
        let cloud = Cloud()
        let (phone, first) = replica(cloud); let url = visit(phone); await sync(first)
        let (mac, second) = replica(cloud); await sync(second)
        second.setEnabled(false); mac.toggleStar(url)
        await first.deleteSyncedData()
        XCTAssertFalse(first.enabled); XCTAssertTrue(cloud.records.isEmpty)
        XCTAssertEqual(phone.rooms.count, 1)
        await sync(second)
        XCTAssertFalse(second.enabled)
        XCTAssertTrue(second.status.contains("deleted"))
        XCTAssertTrue(cloud.records.isEmpty)
    }

    func testConflictRetriesAndFailureToPersistDoesNotSendToCloud() async {
        let cloud = Cloud(), state = Storage()
        let (history, coordinator) = replica(cloud, state: state)
        _ = visit(history); cloud.conflicts = 1
        await sync(coordinator); XCTAssertEqual(coordinator.status, "Up to date")
        let count = cloud.saves
        state.failing = true; _ = visit(history, "unsaved")
        await coordinator.synchronizeForNotification()
        XCTAssertNotNil(coordinator.storageWarning); XCTAssertEqual(cloud.saves, count)
        state.failing = false; await coordinator.synchronizeForNotification()
        XCTAssertNil(coordinator.storageWarning); XCTAssertGreaterThan(cloud.saves, count)
    }

    func testLocalMutationDuringCloudWriteIsNotAcknowledgedAsAlreadySynced() async {
        let cloud = Cloud()
        let (history, coordinator) = replica(cloud)
        let url = visit(history)
        var didMutate = false
        cloud.saveGate = {
            if !didMutate { didMutate = true; history.setAlias("Changed during upload", for: url) }
        }
        await sync(coordinator)
        guard case .room(let room) = cloud.records[url.absoluteString] else { return XCTFail("Missing room") }
        XCTAssertEqual(room.alias.value, "Changed during upload")
        XCTAssertEqual(coordinator.status, "Up to date")
    }
}
