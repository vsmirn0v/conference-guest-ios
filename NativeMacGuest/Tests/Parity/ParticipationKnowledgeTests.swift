import Foundation
import XCTest
@testable import RockNativeDesktop

final class ParticipationKnowledgeTests: XCTestCase {
    private var root: URL!
    private var audience: ParticipationKnowledgeAudience!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Release"), withIntermediateDirectories: true)
        try "# Rollout\nStart at 10%.".write(to: root.appendingPathComponent("Release/Decision.md"), atomically: true, encoding: .utf8)
        audience = .init(sessionID: UUID(), roomIdentity: "room-a", rosterEpoch: 7)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func grant() throws -> ParticipationKnowledgeGrant {
        let source = try ParticipationKnowledgeReader.inspect(root: root, relativePath: "Release/Decision.md")
        return .init(id: UUID(), revision: 1, source: source, audience: audience,
                     allowedProcessors: ["local"], expiresAt: Date(timeIntervalSince1970: 200))
    }

    func testApprovedSnapshotIsScopedToAudienceProcessorAndExpiry() throws {
        let grant = try grant()
        let scope = ParticipationKnowledgeScope()
        scope.approve(grant)
        let source = try scope.read(root: root, id: grant.id, audience: audience, processor: "local", now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(source.markdown, "# Rollout\nStart at 10%.")
        var changedAudience = audience!
        changedAudience = .init(sessionID: changedAudience.sessionID, roomIdentity: changedAudience.roomIdentity, rosterEpoch: 8)
        XCTAssertThrowsError(try scope.read(root: root, id: grant.id, audience: changedAudience, processor: "local", now: Date(timeIntervalSince1970: 100)))
        XCTAssertThrowsError(try scope.read(root: root, id: grant.id, audience: audience, processor: "cloud", now: Date(timeIntervalSince1970: 100)))
        XCTAssertThrowsError(try scope.read(root: root, id: grant.id, audience: audience, processor: "local", now: Date(timeIntervalSince1970: 201)))
        scope.revoke(grant.id)
        XCTAssertFalse(scope.contains(grant))
        XCTAssertThrowsError(try scope.read(root: root, id: grant.id, audience: audience, processor: "local", now: Date(timeIntervalSince1970: 100)))
    }

    func testChangedSourceRequiresNewApproval() throws {
        let grant = try grant()
        let file = root.appendingPathComponent("Release/Decision.md")
        try "# Rollout\nStart at 90%.".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ParticipationKnowledgeReader.readAuthorized(root: root, grant: grant, audience: audience, processor: "local", now: Date(timeIntervalSince1970: 100))) { error in
            XCTAssertEqual(error as? ParticipationKnowledgeError, .sourceChanged)
        }
    }

    func testReplacementOfSameContentRequiresNewApproval() throws {
        let grant = try grant()
        let replacement = root.appendingPathComponent("Release/Replacement.md")
        try grant.source.markdown.write(to: replacement, atomically: true, encoding: .utf8)
        let original = root.appendingPathComponent("Release/Decision.md")
        try FileManager.default.removeItem(at: original)
        try FileManager.default.moveItem(at: replacement, to: original)
        XCTAssertThrowsError(try ParticipationKnowledgeReader.readAuthorized(root: root, grant: grant, audience: audience, processor: "local", now: Date(timeIntervalSince1970: 100))) { error in
            XCTAssertEqual(error as? ParticipationKnowledgeError, .sourceChanged)
        }
    }

    func testTraversalHiddenPathsAndSymlinksAreRejected() throws {
        XCTAssertThrowsError(try ParticipationKnowledgeReader.inspect(root: root, relativePath: "../outside.md"))
        XCTAssertThrowsError(try ParticipationKnowledgeReader.inspect(root: root, relativePath: ".obsidian/config.md"))
        let link = root.appendingPathComponent("linked.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("Release/Decision.md"))
        XCTAssertThrowsError(try ParticipationKnowledgeReader.inspect(root: root, relativePath: "linked.md"))
        let folderLink = root.appendingPathComponent("linked-folder")
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: root.appendingPathComponent("Release"))
        XCTAssertThrowsError(try ParticipationKnowledgeReader.inspect(root: root, relativePath: "linked-folder/Decision.md"))
    }

    func testHardlinksAndOversizedFilesAreRejected() throws {
        let source = root.appendingPathComponent("Release/Decision.md")
        let hardlink = root.appendingPathComponent("Release/Hard.md")
        try FileManager.default.linkItem(at: source, to: hardlink)
        XCTAssertThrowsError(try ParticipationKnowledgeReader.inspect(root: root, relativePath: "Release/Hard.md"))
        let large = root.appendingPathComponent("Large.md")
        try Data(repeating: 0x61, count: ParticipationKnowledgeReader.maxBytes + 1).write(to: large)
        XCTAssertThrowsError(try ParticipationKnowledgeReader.inspect(root: root, relativePath: "Large.md"))
        try Data([0xff, 0xff]).write(to: root.appendingPathComponent("Invalid.md"))
        XCTAssertThrowsError(try ParticipationKnowledgeReader.inspect(root: root, relativePath: "Invalid.md"))
    }
}
