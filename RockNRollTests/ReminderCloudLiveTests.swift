import CloudKit
import ConferenceCore
import XCTest
@testable import RockNRoll

@MainActor final class ReminderCloudLiveTests: XCTestCase {
    func testOptionalCloudProfileExchangeIsSeparateFromLocalEnableAndCalendarState() async throws {
        guard ProcessInfo.processInfo.environment["CONFERENCE_TEST_REMINDER_CLOUD_LIVE"] == "1" else {
            throw XCTSkip("Opt-in isolated private iCloud preferences-zone check.")
        }
        let container = CKContainer(identifier: CloudRoomTransport.containerIdentifier)
        guard try await container.accountStatus() == .available else { throw XCTSkip("No Apple Account on this test target") }
        let account = try await container.userRecordID().recordName
        let cloud = ReminderProfileCloud(zoneName: "ReminderVerification-" + UUID().uuidString)
        let session = try await cloud.session(account: account)
        do {
            var first = ReminderProfileEnvelope(); first.counter = 1; first.device = "device-a"; first.value.timing.before = 30
            let saved = try await cloud.exchange(first, acknowledged: nil, session: session)
            XCTAssertEqual(saved, first)
            let second = try await cloud.exchange(ReminderProfileEnvelope(), acknowledged: nil, session: session)
            XCTAssertEqual(second, first)
            var edited = second; edited.counter += 1; edited.device = "device-b"; edited.value.details = false
            let updated = try await cloud.exchange(edited, acknowledged: second, session: session)
            XCTAssertEqual(updated, edited)
            let stale = try await cloud.exchange(first, acknowledged: saved, session: session)
            XCTAssertEqual(stale, edited)
            let json = String(data: try JSONEncoder().encode(stale), encoding: .utf8)!
            XCTAssertFalse(json.contains("calendarID")); XCTAssertFalse(json.contains("invitation")); XCTAssertFalse(json.contains("enabled"))
            try await cloud.delete()
        } catch {
            try? await cloud.delete(); throw error
        }
    }
    func testSchemaOneUpgradeFencesAStaleWriterWithoutTouchingSavedRooms() async throws {
        guard ProcessInfo.processInfo.environment["CONFERENCE_TEST_REMINDER_CLOUD_LIVE"] == "1" else { throw XCTSkip("Opt-in isolated private cloud migration test") }
        let container = CKContainer(identifier: CloudRoomTransport.containerIdentifier)
        guard try await container.accountStatus() == .available else { throw XCTSkip("No Apple Account") }
        let account = try await container.userRecordID().recordName
        let zoneName = "ReminderMigration-" + UUID().uuidString
        let cloud = ReminderProfileCloud(zoneName: zoneName)
        let session = try await cloud.session(account: account)
        let recordID = CKRecord.ID(recordName: "Profile-v1", zoneID: .init(zoneName: zoneName, ownerName: CKCurrentUserDefaultName))
        let database = container.privateCloudDatabase
        do {
            var legacy = ReminderProfileEnvelope(); legacy.schema = 1; legacy.counter = 5
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
            var value = try XCTUnwrap(object["value"] as? [String: Any])
            value["timing"] = ["before": 120, "atStart": false, "after": 90, "rememberedAfter": 90]
            object["value"] = value
            let payload: [String: Any] = ["schema": 1, "generation": session.generation, "profile": object]
            let record = CKRecord(recordType: "RoomPreference", recordID: recordID)
            record.encryptedValues["payload"] = try JSONSerialization.data(withJSONObject: payload) as CKRecordValue
            let stale = try await database.save(record)
            let upgraded = try await cloud.exchange(.init(), acknowledged: nil, session: session)
            XCTAssertEqual(upgraded.schema, 2); XCTAssertEqual(upgraded.value.timing.followUp, .init(mode: .always, delay: 90))
            stale.encryptedValues["payload"] = try JSONSerialization.data(withJSONObject: payload) as CKRecordValue
            do {
                let results = try await database.modifyRecords(saving: [stale], deleting: [], savePolicy: .ifServerRecordUnchanged)
                _ = try results.saveResults[recordID]?.get(); XCTFail("Stale schema-one writer was accepted")
            } catch let error as CKError { XCTAssertEqual(error.code, .serverRecordChanged) }
            let current = try await database.record(for: recordID)
            let data = try XCTUnwrap(current.encryptedValues["payload"] as? Data)
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(saved["schema"] as? Int, 2)
            try await cloud.delete()
        } catch { try? await cloud.delete(); throw error }
    }

}
