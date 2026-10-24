import CloudKit
import ConferenceCore
import CryptoKit
import XCTest
@testable import RockNativeDesktop

/// Opt-in signed-app checks use only generated private zones and invitations.
/// They never enable the library, reminders or active-jam sharing preferences.
@MainActor final class NativeCloudServiceTests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }
    private var container: CKContainer { CKContainer(identifier: CloudRoomTransport.containerIdentifier) }

    func testSignedAccountBaseline() async throws {
        guard environment["ROCK_NATIVE_CLOUD_ACCOUNT_PROBE"] == "1" else {
            throw XCTSkip("Read-only signed iCloud account probe is explicitly selected")
        }
        let status = try await container.accountStatus()
        XCTAssertEqual(status, .available)
        let account = try await container.userRecordID().recordName
        XCTAssertFalse(account.isEmpty)
        let digest = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        print("NATIVE_CLOUD_ACCOUNT,available=true,accountSHA256=\(digest)")
    }

    func testEncryptedCloudRoundtrip() async throws {
        guard environment["ROCK_CLOUD_LIVE_TEST"] == "1" else {
            throw XCTSkip("Requires explicitly selected signed app and generated private zone")
        }
        let marker: String
        if let value = environment["ROCK_CLOUD_TEST_MARKER"] {
            _ = try XCTUnwrap(UUID(uuidString: value), "A cross-device marker must be a generated UUID")
            marker = value
        } else { marker = UUID().uuidString }
        let zoneName = "SyncVerification-" + marker
        let zone = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        if environment["ROCK_CLOUD_TEST_PHASE"] == "cleanup" {
            try await deleteGeneratedZone(zone)
            print("NATIVE_CLOUD_CLEANUP,marker=\(marker),deleted=true")
            return
        }
        let transport = CloudRoomTransport(zoneName: zoneName, notifications: false)
        let session = try await transport.connect()
        if let phase = environment["ROCK_CLOUD_TEST_PHASE"] {
            try await crossDevice(phase: phase, marker: marker, transport: transport, session: session)
            if phase == "verify" { try await deleteGeneratedZone(zone) }
            return
        }
        do {
            let url = URL(string: "https://sync-fixture.example.test/\(marker)?psw=generated-fixture")!
            var document = RoomSyncDocument()
            document.setName("Generated native cloud tester")
            var room = RecentRoom(invitationURL: url, title: "Generated native fixture", identifier: marker,
                isStarred: true, lastJoined: Date())
            room.alias = "Generated personal alias"
            document.upsert(room, visited: true)
            _ = try await transport.save(document.records, session: session)
            let reader = CloudRoomTransport(zoneName: zoneName, notifications: false)
            let readerSession = try await reader.connect()
            XCTAssertEqual(readerSession, session)
            let changes = try await reader.fetch(session: readerSession, after: nil)
            var restored = RoomSyncDocument(); restored.merge(changes.records)
            XCTAssertEqual(restored.visibleRooms.map(\.invitationURL), [url])
            XCTAssertEqual(restored.visibleRooms.first?.alias, room.alias)
            XCTAssertEqual(restored.name?.value, "Generated native cloud tester")
            XCTAssertNotNil(changes.token)
            let recordName = "item-" + SHA256.hash(data: Data(room.id.utf8)).map { String(format: "%02x", $0) }.joined()
            try await assertEncryptedPayload(.init(recordName: recordName, zoneID: zone))
            document.remove(room.id)
            _ = try await transport.save(document.records, session: session)
            let delta = try await reader.fetch(session: readerSession, after: changes.token)
            restored.merge(delta.records)
            XCTAssertTrue(restored.visibleRooms.isEmpty, "A token-based reader applies the production tombstone")
            try await transport.clear(session: session)
            do {
                _ = try await reader.save(document.records, session: readerSession)
                XCTFail("An offline replica must not republish across the deletion generation")
            } catch RoomCloudError.generationChanged { }
            let fresh = try await transport.connect()
            XCTAssertNotEqual(fresh.generation, session.generation)
            let empty = try await transport.fetch(session: fresh, after: nil)
            XCTAssertTrue(empty.records.isEmpty)
            try await deleteGeneratedZone(zone)
            print("NATIVE_CLOUD_ROUNDTRIP,marker=\(marker),encryption=true,tombstone=true,deletionFence=true")
        } catch {
            try? await deleteGeneratedZone(zone)
            throw error
        }
    }

    func testContinuationClaimsTransitionsAndReplacementWithdrawal() async throws {
        guard environment["ROCK_NATIVE_CONTINUATION_LIVE_TEST"] == "1" else {
            throw XCTSkip("Requires explicitly selected signed app and generated continuation zone")
        }
        let account = try await container.userRecordID().recordName
        let zoneName = "NativeContinuationVerification-" + UUID().uuidString
        let zone = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        let writer = MeetingContinuationCloud(zoneName: zoneName, notifications: false)
        let reader = MeetingContinuationCloud(zoneName: zoneName, notifications: false)
        do {
            try await writer.connect(account: account); try await reader.connect(account: account)
            let jam = ActiveJam(deviceID: UUID().uuidString,
                invitation: URL(string: "https://sync-fixture.example.test/native-continuation?psw=generated-fixture")!,
                title: "Generated continuation", name: "Generated tester", deviceLabel: "Generated Mac",
                supportsCompanion: true, engine: .guest)
            try await writer.publish(jam)
            let initial = try await reader.snapshot(sourceSession: jam.sessionID)
            XCTAssertEqual(initial.jams, [jam]); XCTAssertNil(initial.command)
            try await assertEncryptedPayload(.init(recordName: "device-" + jam.deviceID, zoneID: zone))
            let transfer = JamTransfer(source: jam, targetDevice: UUID().uuidString, targetLabel: "Generated iPhone")
            try await reader.claim(transfer)
            try await reader.claim(transfer)
            do {
                try await reader.claim(JamTransfer(source: jam, targetDevice: UUID().uuidString, targetLabel: "Other generated target"))
                XCTFail("A different target cannot overwrite an active claim")
            } catch ContinuationError.conflict { }
            do {
                _ = try await reader.transition(transfer, to: .prepared, actor: transfer.targetDevice)
                XCTFail("Only the source may acknowledge preparation")
            } catch ContinuationError.expired { }
            let prepared = try await writer.transition(transfer, to: .prepared, actor: jam.deviceID)
            let snapshot = try await reader.snapshot(sourceSession: jam.sessionID)
            XCTAssertEqual(snapshot.command, prepared, "Incremental snapshots include claim changes")
            let connected = try await reader.transition(prepared, to: .connected, actor: transfer.targetDevice)
            let finishing = try await writer.transition(connected, to: .finishing, actor: jam.deviceID)
            _ = try await writer.transition(finishing, to: .completed, actor: jam.deviceID)
            let replacement = ActiveJam(deviceID: jam.deviceID, invitation: jam.invitation,
                title: "Generated replacement", name: jam.name, deviceLabel: jam.deviceLabel, engine: .guest)
            try await writer.publish(replacement)
            try await reader.withdraw(deviceID: jam.deviceID, sessionID: jam.sessionID)
            reader.resetConnection(); try await reader.connect(account: account)
            let restored = try await reader.snapshot(sourceSession: jam.sessionID)
            XCTAssertEqual(restored.jams, [replacement], "A delayed withdrawal cannot erase a replacement session")
            XCTAssertEqual(restored.command?.phase, .completed)
            try await writer.withdraw(deviceID: jam.deviceID, sessionID: replacement.sessionID)
            let withdrawn = try await reader.snapshot(sourceSession: jam.sessionID)
            XCTAssertTrue(withdrawn.jams.isEmpty)
            try await writer.clear()
            do {
                try await reader.publish(replacement)
                XCTFail("A cleared generation must fence a cached continuation adapter")
            } catch ContinuationError.expired { }
            print("NATIVE_CONTINUATION_ROUNDTRIP,claims=true,transitions=true,incremental=true,replacementFence=true,deletionFence=true")
        } catch {
            try? await deleteGeneratedZone(zone)
            throw error
        }
    }

    private func assertEncryptedPayload(_ id: CKRecord.ID) async throws {
        let record = try await container.privateCloudDatabase.record(for: id)
        XCTAssertEqual(record.recordType, "RoomPreference")
        XCTAssertNil(record["payload"], "Invitations must not enter unencrypted CloudKit fields")
        XCTAssertTrue(record.encryptedValues["payload"] is Data)
        XCTAssertTrue(record.allKeys().allSatisfy { record[$0] == nil }, "Generated invitation metadata must remain encrypted")
    }

    private func deleteGeneratedZone(_ zone: CKRecordZone.ID) async throws {
        let prefixes = ["SyncVerification-", "NativeContinuationVerification-"]
        XCTAssertTrue(prefixes.contains { zone.zoneName.hasPrefix($0) && UUID(uuidString: String(zone.zoneName.dropFirst($0.count))) != nil })
        guard prefixes.contains(where: { zone.zoneName.hasPrefix($0) && UUID(uuidString: String(zone.zoneName.dropFirst($0.count))) != nil }) else {
            throw RoomCloudError.incompatibleData
        }
        do { _ = try await container.privateCloudDatabase.deleteRecordZone(withID: zone) }
        catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone { }
    }

    /// Matches the shipping iOS fixture so either platform can write or verify.
    private func crossDevice(phase: String, marker: String, transport: CloudRoomTransport, session: RoomCloudSession) async throws {
        let url = URL(string: "https://sync-fixture.example.test/\(marker)?psw=generated-fixture")!
        let second = url.appendingPathComponent("second")
        switch phase {
        case "write":
            var document = RoomSyncDocument(); document.setName("Cross-device fixture musician")
            for (index, invitation) in [url, second].enumerated() {
                var room = RecentRoom(invitationURL: invitation, title: "Cloud fixture \(index)", identifier: "\(marker)-\(index)",
                    isStarred: true, lastJoined: Date())
                room.alias = "Device fixture \(index)"; document.upsert(room, visited: true)
            }
            document.setFavoriteOrder([second.absoluteString, url.absoluteString])
            _ = try await transport.save(document.records, session: session)
        case "reorder", "verify":
            let changes = try await transport.fetch(session: session, after: nil)
            var document = RoomSyncDocument(); document.merge(changes.records)
            XCTAssertEqual(document.visibleRooms.map(\.id), phase == "reorder" ? [second.absoluteString, url.absoluteString] : [url.absoluteString, second.absoluteString])
            XCTAssertEqual(document.name?.value, phase == "reorder" ? "Cross-device fixture musician" : "Updated device fixture musician")
            XCTAssertEqual(document.visibleRooms.first { $0.id == url.absoluteString }?.alias, "Device fixture 0")
            XCTAssertTrue(document.visibleRooms.allSatisfy(\.isStarred))
            if phase == "reorder" {
                document.setFavoriteOrder([url.absoluteString, second.absoluteString]); document.setName("Updated device fixture musician")
                _ = try await transport.save(document.records, session: session)
            }
        default: XCTFail("Unknown cross-device fixture phase")
        }
        print("NATIVE_CROSS_DEVICE_CLOUD,phase=\(phase),marker=\(marker),completed=true")
    }
}
