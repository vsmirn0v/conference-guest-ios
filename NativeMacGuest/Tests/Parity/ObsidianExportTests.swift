import Foundation
import XCTest
@testable import RockNativeDesktop

/// Atomic file writes with backups, and the outbox worker end-to-end against a
/// file:// vault through an injected resolver (no security-scoped bookmark needed).
final class ObsidianExportTests: XCTestCase {
    private var temp: URL!
    private var vault: URL!
    private var backups: URL!

    override func setUp() {
        super.setUp()
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("obsidian-export-tests-\(UUID().uuidString)", isDirectory: true)
        vault = temp.appendingPathComponent("Vault", isDirectory: true)
        backups = temp.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temp)
        super.tearDown()
    }

    // MARK: ObsidianFileWriter

    func testWriterCreatesThenUpdatesWithBackup() async throws {
        let writer = ObsidianFileWriter(backupRoot: backups)
        let target = vault.appendingPathComponent("note.md")
        let outcome = try await writer.write(target: target, content: "v1", expectedIdentity: nil)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "v1")
        XCTAssertNil(outcome.backupURL)

        let fingerprint = try XCTUnwrap(ObsidianFileWriter.FileIdentity.fingerprint(target))
        let second = try await writer.write(target: target, content: "v2", expectedIdentity: fingerprint)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "v2")
        XCTAssertNotNil(second.backupURL)
        XCTAssertEqual(try String(contentsOf: second.backupURL!, encoding: .utf8), "v1")
    }

    func testWriterRefusesStaleIdentity() async throws {
        let writer = ObsidianFileWriter(backupRoot: backups)
        let target = vault.appendingPathComponent("race.md")
        _ = try await writer.write(target: target, content: "v1", expectedIdentity: nil)
        // Another writer changed the file directly: our stale fingerprint must lose.
        try "intruder".write(to: target, atomically: true, encoding: .utf8)
        let stale = ObsidianFileWriter.FileIdentity(size: 2, modificationDate: Date(), sha256: "deadbeef")
        do {
            _ = try await writer.write(target: target, content: "v3", expectedIdentity: stale)
            XCTFail("stale identity must be rejected")
        } catch let error as ObsidianExportError {
            XCTAssertEqual(error, .destinationChanged)
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "intruder")
    }

    func testWriterVerifyFaultLeavesOriginalIntact() async throws {
        let writer = ObsidianFileWriter(backupRoot: backups)
        let target = vault.appendingPathComponent("fault.md")
        _ = try await writer.write(target: target, content: "v1", expectedIdentity: nil)
        await writer.injectFaults([.beforeVerify])
        let fingerprint = try XCTUnwrap(ObsidianFileWriter.FileIdentity.fingerprint(target))
        do {
            _ = try await writer.write(target: target, content: "v2", expectedIdentity: fingerprint)
            XCTFail("verify fault must surface")
        } catch let error as ObsidianExportError {
            guard case .verifyFailed = error else {
                return XCTFail("expected verifyFailed, got \(error)")
            }
        }
    }

    func testVaultValidationRejectsEscapesAndObsidianDirectory() {
        guard case .failure = ObsidianVaultAccess.validate(relativePath: "../outside.md", in: vault) else {
            return XCTFail("parent traversal must be rejected")
        }
        guard case .failure = ObsidianVaultAccess.validate(relativePath: "/abs/path.md", in: vault) else {
            return XCTFail("absolute paths must be rejected")
        }
        guard case .failure = ObsidianVaultAccess.validate(relativePath: ".obsidian/app.json", in: vault) else {
            return XCTFail(".obsidian must never be written")
        }
        guard case .failure = ObsidianVaultAccess.validate(relativePath: "Meetings/../.obsidian/x.md", in: vault) else {
            return XCTFail("nested escapes must be rejected")
        }
        guard case .success = ObsidianVaultAccess.validate(relativePath: "Meetings/ok.md", in: vault) else {
            return XCTFail("ordinary vault-relative paths are valid")
        }
    }

    // MARK: Worker end-to-end

    private func makeStoreWithDestination() async throws -> (MeetingLibraryStore, ObsidianDestinationRecord) {
        let store = MeetingLibraryStore(root: temp.appendingPathComponent("Library", isDirectory: true))
        try await store.prepare()
        let destination = ObsidianDestinationRecord(enabled: true, configRevision: 1, vaultBookmark: Data([1]))
        try await store.saveDestination(destination)
        return (store, destination)
    }

    private func makeWorker(store: MeetingLibraryStore) -> ObsidianExportWorker {
        ObsidianExportWorker(store: store, backupRoot: backups,
            vaultResolver: { _ in .granted(self.vault) })
    }

    func testWorkerExportsNoteAndCompletesOutbox() async throws {
        let (store, destination) = try await makeStoreWithDestination()
        let session = MeetingSessionRecord(title: "Export Me", startedAt: Date())
        try await store.upsertSession(session)
        _ = try await store.saveNote(sessionID: session.id, markdown: "# Notes\n\nexported body")
        let queued = try await store.outboxCount()
        XCTAssertEqual(queued, 1)

        let worker = makeWorker(store: store)
        await worker.runOnce()
        let drained = try await store.outboxCount()
        XCTAssertEqual(drained, 0, "successful export drains the outbox")

        let fileName = MeetingMarkdownTemplate.meetingFileName(title: session.title, sessionID: session.id)
        let written = try String(contentsOf: vault.appendingPathComponent("Meetings/\(fileName)"), encoding: .utf8)
        XCTAssertTrue(written.contains("exported body"))
        XCTAssertTrue(written.contains(MeetingMarkdownTemplate.schemaVersion.description))

        let binding = try await store.binding(destinationID: destination.id, sessionID: session.id, component: .meeting)
        XCTAssertEqual(binding?.state, .exported)
        XCTAssertEqual(binding?.lastExportedRevision, 1)
    }

    func testWorkerUpdatePreservesUserEditsOutsideTheBlock() async throws {
        let (store, _) = try await makeStoreWithDestination()
        let session = MeetingSessionRecord(title: "User Edits", startedAt: Date())
        try await store.upsertSession(session)
        _ = try await store.saveNote(sessionID: session.id, markdown: "body v1")
        let worker = makeWorker(store: store)
        await worker.runOnce()
        let fileName = MeetingMarkdownTemplate.meetingFileName(title: session.title, sessionID: session.id)
        let target = vault.appendingPathComponent("Meetings/\(fileName)")
        var userText = try String(contentsOf: target, encoding: .utf8)
        userText += "\n## Journal\nmy free-form line\n"
        try userText.write(to: target, atomically: true, encoding: .utf8)

        _ = try await store.saveNote(sessionID: session.id, markdown: "body v2")
        await worker.runOnce()

        let updated = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(updated.contains("body v2"))
        XCTAssertTrue(updated.contains("my free-form line"), "user content outside the managed block survives re-export")
        let drained = try await store.outboxCount()
        XCTAssertEqual(drained, 0)
    }

    func testWorkerPausesOnManagedBlockConflict() async throws {
        let (store, destination) = try await makeStoreWithDestination()
        let session = MeetingSessionRecord(title: "Conflict", startedAt: Date())
        try await store.upsertSession(session)
        _ = try await store.saveNote(sessionID: session.id, markdown: "original")
        let worker = makeWorker(store: store)
        await worker.runOnce()

        // The user edits the managed section by hand; the next export must conflict, not clobber.
        let fileName = MeetingMarkdownTemplate.meetingFileName(title: session.title, sessionID: session.id)
        let target = vault.appendingPathComponent("Meetings/\(fileName)")
        let text = try String(contentsOf: target, encoding: .utf8)
        try text.replacingOccurrences(of: "original", with: "hand-edited").write(to: target, atomically: true, encoding: .utf8)

        _ = try await store.saveNote(sessionID: session.id, markdown: "app revision")
        await worker.runOnce()

        let binding = try await store.binding(destinationID: destination.id, sessionID: session.id, component: .meeting)
        XCTAssertEqual(binding?.state, .conflict)
        let remaining = try await store.outboxCount()
        XCTAssertEqual(remaining, 1, "conflicted row stays queued but paused")
        let rows = try await store.dueOutbox(now: .distantFuture)
        XCTAssertEqual(rows.count, 0, "paused conflict row is not due")
        // The user's hand edit is still on disk — nothing was overwritten.
        XCTAssertTrue(try String(contentsOf: target, encoding: .utf8).contains("hand-edited"))
    }

    func testWorkerSkipsExportWhenDisabled() async throws {
        let (store, _) = try await makeStoreWithDestination()
        var destination = try await store.destination()!
        destination.enabled = false
        try await store.saveDestination(destination)
        let session = MeetingSessionRecord(title: "Disabled", startedAt: Date())
        try await store.upsertSession(session)
        _ = try await store.saveNote(sessionID: session.id, markdown: "quiet")
        let worker = makeWorker(store: store)
        await worker.runOnce()
        let remaining = try await store.outboxCount()
        XCTAssertEqual(remaining, 0, "a disabled destination queues and exports nothing")
    }
}
