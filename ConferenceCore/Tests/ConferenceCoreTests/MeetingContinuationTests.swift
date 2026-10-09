import XCTest
@testable import ConferenceCore

final class MeetingContinuationTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private func source() -> ActiveJam {
        ActiveJam(deviceID: "mac", invitation: URL(string: "https://guest.example.test/room?psw=secret")!,
                  title: "Quartet", name: "Ani", deviceLabel: "Mac", updatedAt: date)
    }
    func testPresenceSeparatesFreshStaleExpiredAndDisconnected() {
        var jam = source()
        XCTAssertTrue(jam.isRecent(at: date.addingTimeInterval(120)))
        XCTAssertFalse(jam.isRecent(at: date.addingTimeInterval(240)))
        XCTAssertTrue(jam.isVisible(at: date.addingTimeInterval(240)))
        XCTAssertFalse(jam.isVisible(at: date.addingTimeInterval(901)))
        jam.connected = false
        XCTAssertFalse(jam.isVisible(at: date))
    }
    func testExpiredOrDifferentSessionCannotEndAnotherMeeting() {
        let jam = source()
        var transfer = JamTransfer(source: jam, targetDevice: "phone", targetLabel: "iPhone", now: date)
        transfer.phase = .connected
        XCTAssertTrue(transfer.canComplete(current: jam, now: date))
        var replacement = source(); replacement.updatedAt = date
        XCTAssertFalse(transfer.canComplete(current: replacement, now: date))
        XCTAssertFalse(transfer.canComplete(current: jam, now: date.addingTimeInterval(76)))
        XCTAssertFalse(transfer.canComplete(current: nil, now: date))
    }
    func testTransitionRolesAndTerminalStatesPreventReplayedCommands() {
        var command = JamTransfer(source: source(), targetDevice: "phone", targetLabel: "iPhone", now: date)
        XCTAssertTrue(command.permitsTransition(to: .prepared, actor: "mac", now: date))
        XCTAssertFalse(command.permitsTransition(to: .prepared, actor: "phone", now: date))
        XCTAssertFalse(command.permitsTransition(to: .completed, actor: "mac", now: date))
        command.phase = .prepared
        XCTAssertTrue(command.permitsTransition(to: .connected, actor: "phone", now: date))
        XCTAssertFalse(command.permitsTransition(to: .connected, actor: "another-phone", now: date))
        command.phase = .connected
        XCTAssertTrue(command.permitsTransition(to: .finishing, actor: "mac", now: date))
        command.phase = .finishing
        XCTAssertTrue(command.permitsTransition(to: .completed, actor: "mac", now: date))
        XCTAssertFalse(command.permitsTransition(to: .cancelled, actor: "phone", now: date))
        command.phase = .completed
        XCTAssertFalse(command.permitsTransition(to: .cancelled, actor: "phone", now: date))
    }
    func testCurrentSharingRequiresExplicitTransferChoice() throws {
        var jam = source(); jam.isSharingScreen = true
        let command = JamTransfer(source: jam, targetDevice: "phone", targetLabel: "iPhone", now: date)
        XCTAssertTrue(command.allowsStoppingShare)
        XCTAssertEqual(try JSONDecoder().decode(JamTransfer.self, from: JSONEncoder().encode(command)), command)
        XCTAssertEqual(try JSONDecoder().decode(ActiveJam.self, from: JSONEncoder().encode(jam)), jam)
    }
    func testOlderPresenceWithoutQuietModeRemainsReadable() throws {
        let data = try JSONEncoder().encode(source())
        XCTAssertNil(try JSONDecoder().decode(ActiveJam.self, from: data).audioPaused)
        var quiet = source(); quiet.audioPaused = true
        XCTAssertEqual(try JSONDecoder().decode(ActiveJam.self, from: JSONEncoder().encode(quiet)).audioPaused, true)
    }
    func testTransferSupportsOlderClientsAndConnectFirstReservation() throws {
        let old = JamTransfer(source: source(), targetDevice: "phone", targetLabel: "iPhone", now: date)
        XCTAssertNil(try JSONDecoder().decode(JamTransfer.self, from: JSONEncoder().encode(old)).connectsBeforePausing)
        let new = JamTransfer(source: source(), targetDevice: "phone", targetLabel: "iPhone", now: date, connectsBeforePausing: true)
        XCTAssertEqual(try JSONDecoder().decode(JamTransfer.self, from: JSONEncoder().encode(new)).connectsBeforePausing, true)
        XCTAssertTrue(new.permitsTransition(to: .prepared, actor: "mac", now: date))
    }
}
