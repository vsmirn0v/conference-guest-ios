import Darwin
import Foundation
import XCTest
@testable import RockNRoll

final class NativeGuestCompanionProtocolTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var temporary: URL!
    private var store: NativeGuestSessionStore!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        store = NativeGuestSessionStore(rootURL: temporary.appendingPathComponent("NativeGuestSessions"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private func ticket(at date: Date? = nil) -> NativeGuestTicket {
        NativeGuestTicket(invitationURL: URL(string: "https://meeting.example/room?psw=private")!,
                          displayName: "Guest", roomTitle: "Meeting", now: date ?? now)
    }
    private func file(_ name: String, _ ticket: NativeGuestTicket) -> URL {
        store.rootURL.appendingPathComponent(ticket.metadata.sessionID.uuidString).appendingPathComponent(name)
    }

    func testTicketHasOneAdmissionAndPrivateFiles() throws {
        let ticket = ticket(); try store.create(ticket, now: now)
        let admitted = try store.consumeTicket(ticket.metadata.sessionID, now: now)
        XCTAssertEqual(admitted, ticket)
        XCTAssertThrowsError(try store.consumeTicket(ticket.metadata.sessionID, now: now))
        for url in [store.rootURL, file("ticket.json", ticket).deletingLastPathComponent()] {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o700)
        }
        let mode = try FileManager.default.attributesOfItem(atPath: file("ticket.json", ticket).path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertThrowsError(try store.create(ticket, now: now), "A reused UUID must not replace a ticket")
    }

    func testPendingLaunchRequiresFreshOwnerAndSingleUnclaimedRequest() throws {
        let first = ticket(); try store.create(first, now: now)
        XCTAssertNil(try store.pendingLaunchTicket(now: now))
        try store.writeCommand(NativeGuestCommand(metadata: first.metadata), now: now)
        try store.writeHeartbeat(NativeGuestHeartbeat(metadata: first.metadata, updatedAt: now), now: now)
        XCTAssertEqual(try store.pendingLaunchTicket(now: now), first)
        XCTAssertNil(try store.pendingLaunchTicket(now: now.addingTimeInterval(11)))
        let second = ticket(); try store.create(second, now: now)
        try store.writeCommand(NativeGuestCommand(metadata: second.metadata), now: now)
        try store.writeHeartbeat(NativeGuestHeartbeat(metadata: second.metadata, updatedAt: now), now: now)
        XCTAssertThrowsError(try store.pendingLaunchTicket(now: now), "Ambiguous startup must fail closed")
        _ = try store.consumeTicket(second.metadata.sessionID, now: now)
        XCTAssertEqual(try store.pendingLaunchTicket(now: now), first, "Already admitted sessions are never rediscovered")
        var leaving = NativeGuestCommand(metadata: first.metadata); leaving.leave = true
        try store.writeCommand(leaving, now: now)
        XCTAssertNil(try store.pendingLaunchTicket(now: now), "A canceled join must never start")
    }

    func testProcessBindingPrecedesTicketAdmission() throws {
        let ticket = ticket(); try store.create(ticket, now: now)
        try store.writeHeartbeat(NativeGuestHeartbeat(metadata: ticket.metadata, updatedAt: now), now: now)
        var command = NativeGuestCommand(metadata: ticket.metadata)
        try store.writeCommand(command, now: now)
        XCTAssertThrowsError(try store.consumeTicket(ticket.metadata.sessionID, boundTo: 123, now: now))
        command.expectedHelperPID = 124; try store.writeCommand(command, now: now)
        XCTAssertThrowsError(try store.consumeTicket(ticket.metadata.sessionID, boundTo: 123, now: now))
        command.expectedHelperPID = 123; try store.writeCommand(command, now: now)
        XCTAssertThrowsError(try store.consumeTicket(ticket.metadata.sessionID, boundTo: 123, now: now.addingTimeInterval(11)))
        XCTAssertEqual(try store.consumeTicket(ticket.metadata.sessionID, boundTo: 123, now: now), ticket)
        XCTAssertThrowsError(try store.consumeTicket(ticket.metadata.sessionID, boundTo: 123, now: now), "Even the correct process cannot replay admission")
    }

    func testExpiredLaunchCannotBeReplayedButActiveMeetingCanContinue() throws {
        let ticket = ticket(at: now.addingTimeInterval(-NativeGuestProtocol.maximumSessionLifetime - 1))
        try store.create(ticket, now: ticket.metadata.createdAt)
        XCTAssertThrowsError(try store.consumeTicket(ticket.metadata.sessionID, now: now))
        let status = NativeGuestStatus(metadata: ticket.metadata, state: .active, updatedAt: now, helperPID: 42)
        try store.writeStatus(status, now: now)
        try store.writeHeartbeat(NativeGuestHeartbeat(metadata: ticket.metadata, updatedAt: now), now: now)
        XCTAssertEqual(try store.readStatus(ticket.metadata.sessionID, now: now), status)
        XCTAssertEqual(try store.cleanupExpiredSessions(now: now), [])
    }

    func testLaunchWindowRejectsUnusedOldTicket() throws {
        let ticket = ticket(); try store.create(ticket, now: now)
        XCTAssertThrowsError(try store.consumeTicket(ticket.metadata.sessionID, now: now.addingTimeInterval(46)))
    }

    func testGateRejectsReplayWrongMetadataAndAllCommandsAfterLeave() {
        let ticket = ticket()
        var gate = NativeGuestCommandGate(metadata: ticket.metadata)
        var command = NativeGuestCommand(metadata: ticket.metadata)
        XCTAssertTrue(gate.accept(command))
        XCTAssertFalse(gate.accept(command))
        let foreignMetadata = NativeGuestMetadata(sessionID: ticket.metadata.sessionID, now: now.addingTimeInterval(1))
        XCTAssertFalse(gate.accept(NativeGuestCommand(metadata: foreignMetadata, sequence: 2)))
        command.sequence = 3; command.leave = true
        XCTAssertTrue(gate.accept(command)); XCTAssertTrue(gate.terminalLeave)
        command.sequence = 4; command.leave = false; command.microphoneOn = true
        XCTAssertFalse(gate.accept(command)); XCTAssertEqual(gate.acknowledgedSequence, 3)
    }

    func testMediaMasksCoalescePendingRequestsAndClearAfterAcknowledgement() throws {
        let ticket = ticket()
        var command = NativeGuestCommand(metadata: ticket.metadata)
        XCTAssertEqual(command.mediaFields, [], "Initial commands must preserve native startup intent")
        var applied = NativeGuestStatus(metadata: ticket.metadata, acknowledgedSequence: 1, updatedAt: now)
        try command.advance(changing: [.microphone], acknowledged: applied)
        command.microphoneOn = true
        try command.advance(changing: [.camera], acknowledged: applied)
        command.cameraOn = true
        XCTAssertEqual(command.mediaFields, [.microphone, .camera])
        XCTAssertTrue(command.microphoneOn); XCTAssertTrue(command.cameraOn)
        try command.advance(changing: [], acknowledged: applied)
        command.showWindowSequence += 1
        XCTAssertEqual(command.mediaFields, [.microphone, .camera], "Show must retain requests not yet consumed")
        applied.acknowledgedSequence = command.sequence
        applied.microphoneOn = true; applied.cameraOn = true
        try command.advance(changing: [], acknowledged: applied)
        command.showWindowSequence += 1
        XCTAssertTrue(command.mediaFields.isEmpty, "Show alone must not cancel native permission requests")
        applied.acknowledgedSequence = command.sequence
        try command.advance(changing: [.output], acknowledged: applied)
        command.outputOn = false
        XCTAssertEqual(command.mediaFields, [.output], "An output request cannot override native mic or camera intent")
        try command.advance(changing: [], acknowledged: applied)
        command.leave = true
        XCTAssertEqual(command.mediaFields, [.output], "Leave carries only existing unacknowledged media fields")
        XCTAssertTrue(command.microphoneOn); XCTAssertTrue(command.cameraOn)
        XCTAssertThrowsError(try command.advance(changing: [.microphone], acknowledged: nil))
    }

    func testCapabilitiesAndMediaMaskRoundTripWithoutImplicitDefaults() throws {
        let ticket = ticket(); try store.create(ticket, now: now)
        var command = NativeGuestCommand(metadata: ticket.metadata, microphoneOn: true, mediaFields: [.microphone])
        try store.writeCommand(command, now: now)
        XCTAssertEqual(try store.readCommand(ticket.metadata.sessionID, now: now), command)
        let status = NativeGuestStatus(metadata: ticket.metadata, state: .active, updatedAt: now,
                                       canShareMicrophone: true, canShareCamera: false)
        try store.writeStatus(status, now: now)
        XCTAssertEqual(try store.readStatus(ticket.metadata.sessionID, now: now), status)
        let foreign = NativeGuestStatus(metadata: NativeGuestMetadata(sessionID: UUID(), now: now), updatedAt: now)
        XCTAssertThrowsError(try command.advance(changing: [.camera], acknowledged: foreign))
    }

    func testSymlinkRecordCannotBeReadOrOverwritten() throws {
        let ticket = ticket(); try store.create(ticket, now: now)
        let destination = temporary.appendingPathComponent("protected")
        try Data("keep".utf8).write(to: destination)
        try FileManager.default.createSymbolicLink(at: file("command.json", ticket), withDestinationURL: destination)
        XCTAssertThrowsError(try store.readCommand(ticket.metadata.sessionID, now: now))
        XCTAssertThrowsError(try store.writeCommand(NativeGuestCommand(metadata: ticket.metadata), now: now))
        XCTAssertEqual(try Data(contentsOf: destination), Data("keep".utf8))
    }

    func testSymlinkSessionAndRootAreRejected() throws {
        let ticket = ticket(); try store.create(ticket, now: now)
        let otherID = UUID()
        try FileManager.default.createSymbolicLink(at: store.rootURL.appendingPathComponent(otherID.uuidString),
                                                 withDestinationURL: file("ticket.json", ticket).deletingLastPathComponent())
        XCTAssertThrowsError(try store.readTicket(otherID, now: now))
        let rootLink = temporary.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: store.rootURL)
        XCTAssertThrowsError(try NativeGuestSessionStore(rootURL: rootLink).readTicket(ticket.metadata.sessionID, now: now))
        XCTAssertEqual(try store.readTicket(ticket.metadata.sessionID, now: now), ticket)
    }

    func testHardLinkAndPublicPermissionsAreRejected() throws {
        let ticket = ticket(); try store.create(ticket, now: now)
        let command = NativeGuestCommand(metadata: ticket.metadata)
        try store.writeCommand(command, now: now)
        let path = file("command.json", ticket)
        let hardLink = temporary.appendingPathComponent("hard-link")
        XCTAssertEqual(link(path.path, hardLink.path), 0)
        XCTAssertThrowsError(try store.readCommand(ticket.metadata.sessionID, now: now))
        try FileManager.default.removeItem(at: hardLink)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        XCTAssertThrowsError(try store.readCommand(ticket.metadata.sessionID, now: now))
    }

    func testSizeVersionAndSessionLimitsAreEnforcedOnRead() throws {
        let ticket = ticket(); try store.create(ticket, now: now)
        let path = file("command.json", ticket)
        try store.writeCommand(NativeGuestCommand(metadata: ticket.metadata), now: now)
        let valid = try Data(contentsOf: path)
        try Data(repeating: 0x20, count: NativeGuestProtocol.maximumRecordBytes + 1).write(to: path)
        XCTAssertThrowsError(try store.readCommand(ticket.metadata.sessionID, now: now)) { error in
            XCTAssertEqual(error as? NativeGuestStoreError, .oversizedRecord)
        }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var metadata = try XCTUnwrap(json["metadata"] as? [String: Any])
        metadata["protocolVersion"] = 99; json["metadata"] = metadata
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        XCTAssertThrowsError(try store.readCommand(ticket.metadata.sessionID, now: now)) { error in
            XCTAssertEqual(error as? NativeGuestStoreError, .incompatibleRecord)
        }
        metadata["protocolVersion"] = NativeGuestProtocol.version
        metadata["sessionID"] = UUID().uuidString; json["metadata"] = metadata
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        XCTAssertThrowsError(try store.readCommand(ticket.metadata.sessionID, now: now))
    }

    func testCleanupRetiresAbandonedOwnerWithoutTouchingLiveOrUnrelatedFiles() throws {
        let stale = ticket(); try store.create(stale, now: now)
        _ = try store.consumeTicket(stale.metadata.sessionID, now: now)
        let interruptedWrite = file(".command.json.\(UUID().uuidString).tmp", stale)
        try Data().write(to: interruptedWrite)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: interruptedWrite.path)
        let live = ticket(); try store.create(live, now: now)
        let later = now.addingTimeInterval(90)
        try store.writeHeartbeat(NativeGuestHeartbeat(metadata: live.metadata, updatedAt: later), now: later)
        let unrelated = store.rootURL.appendingPathComponent("unrelated")
        try Data("preserve".utf8).write(to: unrelated)
        XCTAssertEqual(try store.cleanupExpiredSessions(now: later), [stale.metadata.sessionID])
        XCTAssertEqual(try store.readTicket(live.metadata.sessionID, now: later), live)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("preserve".utf8))
    }

    func testHeartbeatFreshnessAndFutureStatusAreDeterministic() throws {
        let ticket = ticket(); try store.create(ticket, now: now)
        let beat = NativeGuestHeartbeat(metadata: ticket.metadata, updatedAt: now)
        XCTAssertTrue(beat.isFresh(now: now.addingTimeInterval(10)))
        XCTAssertFalse(beat.isFresh(now: now.addingTimeInterval(10.001)))
        var status = NativeGuestStatus(metadata: ticket.metadata, updatedAt: now.addingTimeInterval(6))
        XCTAssertThrowsError(try store.writeStatus(status, now: now))
        status.updatedAt = now; status.remoteVideoFrames = -1
        XCTAssertThrowsError(try store.writeStatus(status, now: now))
    }
}
