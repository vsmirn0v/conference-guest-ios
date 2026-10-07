import CloudKit
import ConferenceCore
import XCTest
@testable import RockNRoll

@MainActor
final class MeetingContinuationCloudLiveTests: XCTestCase {
    func testIncrementalSnapshotCarriesClaimsUpdatesAndWithdrawal() async throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_CLOUD_ENERGY"] == "1" else { throw XCTSkip("Opt-in disposable private iCloud zone") }
        let account = try await CKContainer(identifier: CloudRoomTransport.containerIdentifier).userRecordID().recordName
        let zone = "EnergyVerification-" + UUID().uuidString
        let writer = MeetingContinuationCloud(zoneName: zone, notifications: false)
        let reader = MeetingContinuationCloud(zoneName: zone, notifications: false)
        try await writer.connect(account: account); try await reader.connect(account: account)
        do {
            let jam = ActiveJam(deviceID: "generated-source", invitation: URL(string: "https://meeting.example.test/energy-check")!,
                title: "Energy verification", name: "Generated tester", deviceLabel: "Generated Mac")
            try await writer.publish(jam)
            let first = try await reader.snapshot(sourceSession: jam.sessionID)
            XCTAssertEqual(first.jams.map(\.sessionID), [jam.sessionID]); XCTAssertNil(first.command)
            let transfer = JamTransfer(source: jam, targetDevice: "generated-target", targetLabel: "Generated iPhone")
            try await writer.claim(transfer)
            let requested = try await reader.snapshot(sourceSession: jam.sessionID)
            XCTAssertEqual(requested.command, transfer)
            let prepared = try await writer.transition(transfer, to: .prepared, actor: jam.deviceID)
            let changed = try await reader.snapshot(sourceSession: jam.sessionID)
            XCTAssertEqual(changed.command, prepared, "The zone token must include claim changes without a separate record read")
            try await writer.withdraw(deviceID: jam.deviceID, sessionID: jam.sessionID)
            let vacant = try await reader.snapshot(sourceSession: jam.sessionID)
            XCTAssertTrue(vacant.jams.isEmpty); XCTAssertEqual(vacant.command, prepared)
            reader.resetConnection(); try await reader.connect(account: account)
            let restored = try await reader.snapshot(sourceSession: jam.sessionID)
            XCTAssertEqual(restored.command, prepared)
            try await writer.clear()
        } catch {
            try? await writer.clear()
            throw error
        }
    }
}
