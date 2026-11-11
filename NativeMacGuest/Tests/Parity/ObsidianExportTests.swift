import Foundation
import XCTest
@testable import RockNativeDesktop

/// Atomic file writes with backups, and the outbox worker end-to-end against a
/// file:// vault through an injected resolver (no security-scoped bookmark needed).
final class ObsidianExportTests: XCTestCase {
    private var temp: URL!
    private var vault: URL!
    private var backups: URL!
    private var stores: [MeetingLibraryStore] = []

    override func setUp() {
        super.setUp()
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("obsidian-export-tests-\(UUID().uuidString)", isDirectory: true)
        vault = temp.appendingPathComponent("Vault", isDirectory: true)
        backups = temp.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for store in stores { await store.close() }
        stores.removeAll()
        try? FileManager.default.removeItem(at: temp)
        try await super.tearDown()
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

    func testWriterPreservesExternalEditAfterBackupBeforeReplacement() async throws {
        let writer = ObsidianFileWriter(backupRoot: backups)
        let target = vault.appendingPathComponent("race-after-backup.md")
        try "original".write(to: target, atomically: true, encoding: .utf8)
        let identity = try XCTUnwrap(ObsidianFileWriter.FileIdentity.fingerprint(target))
        await writer.injectBeforeReplace { target in
            try "external edit".write(to: target, atomically: true, encoding: .utf8)
        }
        do {
            _ = try await writer.write(target: target, content: "app update", expectedIdentity: identity)
            XCTFail("A racing external edit must prevent replacement")
        } catch let error as ObsidianExportError {
            XCTAssertEqual(error, .destinationChanged)
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "external edit")
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

    private func makeStoreWithDestination(after: Bool = true, sync: Bool = true,
                                          enabled: Bool = true) async throws -> (MeetingLibraryStore, ObsidianDestinationRecord) {
        let store = MeetingLibraryStore(root: temp.appendingPathComponent("Library", isDirectory: true))
        stores.append(store)
        try await store.prepare()
        let destination = ObsidianDestinationRecord(enabled: enabled, saveAfterMeeting: after, syncChanges: sync,
            configRevision: 1, vaultBookmark: Data([1]))
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
        let beforeEnd = try await store.outboxCount()
        XCTAssertEqual(beforeEnd, 0)
        try await store.endSession(session.id, at: Date(), awaitingOutcome: false)
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
        XCTAssertEqual(binding?.lastExportedRevision, 2)
    }

    func testWorkerUpdatePreservesUserEditsOutsideTheBlock() async throws {
        let (store, _) = try await makeStoreWithDestination()
        let session = MeetingSessionRecord(title: "User Edits", startedAt: Date())
        try await store.upsertSession(session)
        _ = try await store.saveNote(sessionID: session.id, markdown: "body v1")
        try await store.saveInObsidian(session.id)
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
        try await store.saveInObsidian(session.id)
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

    func testRenameKeepsExistingExportPath() async throws {
        let (store, destination) = try await makeStoreWithDestination()
        let session = MeetingSessionRecord(title: "Original title", startedAt: Date())
        try await store.upsertSession(session)
        _ = try await store.saveNote(sessionID: session.id, markdown: "note")
        try await store.saveInObsidian(session.id)
        let worker = makeWorker(store: store)
        await worker.runOnce()
        let before = try await store.binding(destinationID: destination.id, sessionID: session.id, component: .meeting)
        try await store.renameSession(session.id, title: "Updated title")
        let updated = try await store.updateSession(session.id, title: "Provider title")
        XCTAssertEqual(updated?.title, "Updated title")
        await worker.runOnce()
        let after = try await store.binding(destinationID: destination.id, sessionID: session.id, component: .meeting)
        XCTAssertEqual(before?.relativePath, after?.relativePath)
        let path = try XCTUnwrap(after?.relativePath)
        let content = try String(contentsOf: vault.appendingPathComponent(path), encoding: .utf8)
        XCTAssertTrue(content.contains("Updated title"))
        _ = try await store.saveNote(sessionID: session.id, markdown: "another revision")
        await worker.runOnce()
        let final = try String(contentsOf: vault.appendingPathComponent(path), encoding: .utf8)
        XCTAssertTrue(final.contains("another revision"))
        XCTAssertEqual(MarkdownStructureScanner.scan(final).managedBlocks.count, 1)
    }

    func testAcknowledgingOldRevisionPreservesNewerOutboxRow() async throws {
        let (store, destination) = try await makeStoreWithDestination()
        let session = MeetingSessionRecord(title: "Queued", startedAt: Date())
        try await store.upsertSession(session)
        let first = try await store.saveNote(sessionID: session.id, markdown: "first")
        try await store.saveInObsidian(session.id)
        _ = try await store.saveNote(sessionID: session.id, markdown: "second")
        try await store.saveInObsidian(session.id)
        try await store.completeOutbox(destinationID: destination.id, sessionID: session.id, throughRevision: first.exportRevision)
        let remaining = try await store.outboxCount()
        XCTAssertEqual(remaining, 1)
    }

    func testFourPolicyCombinationsAndMasterOverride() async throws {
        let (store, destination) = try await makeStoreWithDestination()
        for (master, after, sync) in [(true, false, false), (true, true, false), (true, false, true), (true, true, true), (false, true, true)] {
            var config = destination
            config.enabled = master
            config.saveAfterMeeting = after
            config.syncChanges = sync
            try await store.saveDestination(config)
            let meeting = MeetingSessionRecord(title: "Policy", startedAt: Date())
            try await store.upsertSession(meeting)
            _ = try await store.saveNote(sessionID: meeting.id, markdown: "initial")
            let unlinked = try await store.dueOutbox()
            XCTAssertFalse(unlinked.contains { $0.sessionID == meeting.id })
            try await store.endSession(meeting.id, at: Date(), awaitingOutcome: false)
            let ended = try await store.dueOutbox().first { $0.sessionID == meeting.id }
            XCTAssertEqual(ended?.intent, master && after ? .initialEnd : nil)
            try await store.saveInObsidian(meeting.id)
            await makeWorker(store: store).runOnce()
            _ = try await store.saveNote(sessionID: meeting.id, markdown: "update")
            let update = try await store.dueOutbox().first { $0.sessionID == meeting.id }
            XCTAssertEqual(update?.intent, master && sync ? .linkedUpdate : nil)
            await makeWorker(store: store).runOnce()
        }
    }

    func testInitialAndFirstReadyRemainFrozenAcrossRestart() async throws {
        let (store, destination) = try await makeStoreWithDestination(after: true, sync: false)
        let meeting = MeetingSessionRecord(title: "Frozen", startedAt: Date())
        try await store.upsertSession(meeting)
        _ = try await store.saveNote(sessionID: meeting.id, markdown: "at end")
        try await store.endSession(meeting.id, at: Date(), awaitingOutcome: true)
        _ = try await store.saveNote(sessionID: meeting.id, markdown: "when ready")
        let initial = try await store.dueOutbox().first
        XCTAssertEqual(initial?.intent, .initialEnd)
        XCTAssertEqual(initial?.snapshot?.outcomeState, .pending)
        XCTAssertEqual(initial?.snapshot?.note?.markdown, "at end")
        _ = try await store.saveOutcome(.init(meetingID: meeting.id, meetingTitle: meeting.title,
            endedAt: Date(), summary: "first outcome"), state: .ready)
        _ = try await store.saveNote(sessionID: meeting.id, markdown: "much later")
        await store.close()
        try await store.prepare()
        let ready = try await store.dueOutbox().first
        XCTAssertEqual(ready?.intent, .initialFirstReady)
        XCTAssertEqual(ready?.snapshot?.note?.markdown, "when ready")
        XCTAssertEqual(ready?.snapshot?.outcome?.summary, "first outcome")
        await makeWorker(store: store).runOnce()
        let binding = try await store.binding(destinationID: destination.id, sessionID: meeting.id, component: .meeting)
        let text = try String(contentsOf: vault.appendingPathComponent(try XCTUnwrap(binding?.relativePath)), encoding: .utf8)
        XCTAssertTrue(text.contains("when ready"))
        XCTAssertFalse(text.contains("much later"))
    }

    func testDisablingAfterMeetingHoldsFirstReadyAcrossReenable() async throws {
        let (store, initial) = try await makeStoreWithDestination(after: true, sync: false)
        var destination = initial
        let meeting = MeetingSessionRecord(title: "Pause", startedAt: Date())
        try await store.upsertSession(meeting)
        try await store.endSession(meeting.id, at: Date(), awaitingOutcome: true)
        let authorized = try await store.dueOutbox().first
        destination.saveAfterMeeting = false
        destination.configRevision += 1
        try await store.saveDestination(destination)
        let remainsAuthorized = try await store.isAuthorizedForWrite(try XCTUnwrap(authorized))
        XCTAssertFalse(remainsAuthorized)
        destination.saveAfterMeeting = true
        destination.configRevision += 1
        try await store.saveDestination(destination)
        _ = try await store.saveOutcome(.init(meetingID: meeting.id, meetingTitle: meeting.title,
            endedAt: Date(), summary: "first outcome"), state: .ready)
        let due = try await store.dueOutbox()
        XCTAssertTrue(due.isEmpty)
        let held = try await store.outboxRows(destinationID: destination.id).first
        XCTAssertEqual(held?.policyHeld, true)
        XCTAssertEqual(held?.snapshot?.outcome?.summary, "first outcome")
        try await store.sendHeldObsidianRows()
        let manual = try await store.dueOutbox().first
        XCTAssertEqual(manual?.intent, .manualSave)
    }

    func testSendAccumulatedOnlyReleasesSelectedMeetings() async throws {
        let (store, initial) = try await makeStoreWithDestination(after: true, sync: false)
        let first = MeetingSessionRecord(title: "First", startedAt: Date())
        let second = MeetingSessionRecord(title: "Second", startedAt: Date())
        try await store.upsertSession(first)
        try await store.upsertSession(second)
        try await store.endSession(first.id, at: Date(), awaitingOutcome: true)
        try await store.endSession(second.id, at: Date(), awaitingOutcome: true)
        var disabled = initial
        disabled.saveAfterMeeting = false
        disabled.configRevision += 1
        try await store.saveDestination(disabled)
        let held = try await store.heldObsidianMeetings(destinationID: initial.id)
        XCTAssertEqual(Set(held.map(\.id)), Set([first.id, second.id]))
        let firstPreview = try XCTUnwrap(held.first(where: { $0.id == first.id }))
        XCTAssertEqual(firstPreview.date?.fromEnd, false)
        XCTAssertFalse(firstPreview.snapshots.isEmpty)
        do {
            try await store.sendHeldObsidianRows(sessionIDs: [first.id], expectedDestination: UUID(),
                                                 expectedConfigRevision: disabled.configRevision)
            XCTFail("A changed destination must not release queued work")
        } catch { XCTAssertEqual(error as? ObsidianExportError, .destinationChanged) }
        do {
            try await store.sendHeldObsidianRows(sessionIDs: [first.id], expectedDestination: disabled.id,
                                                 expectedConfigRevision: initial.configRevision)
            XCTFail("A changed destination configuration must not release queued work")
        } catch { XCTAssertEqual(error as? ObsidianExportError, .destinationChanged) }
        let stillHeld = try await store.outboxRows(destinationID: initial.id)
        XCTAssertTrue(stillHeld.allSatisfy(\.policyHeld))
        do {
            try await store.sendHeldObsidianRows(sessionIDs: [first.id], expectedDestination: disabled.id,
                expectedConfigRevision: disabled.configRevision, expectedSnapshots: [first.id: []])
            XCTFail("Changed queued content must require a fresh preview")
        } catch { XCTAssertEqual(error as? ObsidianExportError, .staleRevision) }
        do {
            try await store.sendHeldObsidianRows(sessionIDs: [first.id, second.id], expectedDestination: disabled.id,
                expectedConfigRevision: disabled.configRevision, expectedSnapshots: [first.id: firstPreview.snapshots])
            XCTFail("Every selected meeting must have a reviewed snapshot")
        } catch { XCTAssertEqual(error as? ObsidianExportError, .staleRevision) }
        try await store.sendHeldObsidianRows(sessionIDs: [first.id], expectedDestination: disabled.id,
            expectedConfigRevision: disabled.configRevision, expectedSnapshots: [first.id: firstPreview.snapshots])
        let rows = try await store.outboxRows(destinationID: initial.id)
        XCTAssertEqual(rows.first(where: { $0.sessionID == first.id })?.policyHeld, false)
        XCTAssertEqual(rows.first(where: { $0.sessionID == second.id })?.policyHeld, true)
    }

    func testManualAuthorityDoesNotExtendToDeferredAutomaticEdit() async throws {
        let (store, initial) = try await makeStoreWithDestination(after: true, sync: true)
        var destination = initial
        let meeting = MeetingSessionRecord(title: "Manual revision", startedAt: Date())
        try await store.upsertSession(meeting)
        _ = try await store.saveNote(sessionID: meeting.id, markdown: "binding baseline")
        try await store.saveInObsidian(meeting.id)
        let worker = makeWorker(store: store)
        await worker.runOnce()
        _ = try await store.saveNote(sessionID: meeting.id, markdown: "explicitly authorized")
        try await store.saveInObsidian(meeting.id)
        _ = try await store.saveNote(sessionID: meeting.id, markdown: "automatic only")
        destination.syncChanges = false
        destination.configRevision += 1
        try await store.saveDestination(destination)
        await worker.runOnce()
        let binding = try await store.binding(destinationID: destination.id, sessionID: meeting.id, component: .meeting)
        let text = try String(contentsOf: vault.appendingPathComponent(try XCTUnwrap(binding?.relativePath)), encoding: .utf8)
        XCTAssertTrue(text.contains("explicitly authorized"))
        XCTAssertFalse(text.contains("automatic only"))
        let held = try await store.heldDeferredObsidianCount(destinationID: destination.id)
        XCTAssertEqual(held, 1)
    }

    func testAfterEndAuthoritySurvivesDisablingDeferredLinkedUpdates() async throws {
        let (store, initial) = try await makeStoreWithDestination(after: true, sync: true)
        var destination = initial
        let meeting = MeetingSessionRecord(title: "End revision", startedAt: Date())
        try await store.upsertSession(meeting)
        _ = try await store.saveNote(sessionID: meeting.id, markdown: "at end")
        try await store.saveInObsidian(meeting.id)
        let worker = makeWorker(store: store)
        await worker.runOnce()
        try await store.endSession(meeting.id, at: Date(), awaitingOutcome: false)
        _ = try await store.saveNote(sessionID: meeting.id, markdown: "after end")
        destination.syncChanges = false
        destination.configRevision += 1
        try await store.saveDestination(destination)
        let due = try await store.dueOutbox().first
        XCTAssertEqual(due?.intent, .initialEnd)
        XCTAssertEqual(due?.snapshot?.note?.markdown, "at end")
    }

    func testRetryRecoversExistingFileWriteThatWasNotAcknowledged() async throws {
        let (store, destination) = try await makeStoreWithDestination()
        let meeting = MeetingSessionRecord(title: "Write receipt", startedAt: Date())
        try await store.upsertSession(meeting)
        _ = try await store.saveNote(sessionID: meeting.id, markdown: "acknowledged revision")
        try await store.saveInObsidian(meeting.id)
        let writer = ObsidianFileWriter(backupRoot: backups)
        let worker = ObsidianExportWorker(store: store, backupRoot: backups, writer: writer,
            vaultResolver: { _ in .granted(self.vault) })
        await worker.runOnce()
        let original = try await store.binding(destinationID: destination.id, sessionID: meeting.id, component: .meeting)
        let path = try XCTUnwrap(original?.relativePath)
        let target = vault.appendingPathComponent(path)

        _ = try await store.saveNote(sessionID: meeting.id, markdown: "unacknowledged revision")
        await writer.injectFaults([.afterReplace])
        await worker.runOnce()
        let journal = try await store.preparedExportWrite(destinationID: destination.id,
            sessionID: meeting.id, component: .meeting)
        XCTAssertEqual(journal?.lastExportedRevision, 2)
        let replaced = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(replaced.contains("unacknowledged revision"))
        try (replaced + "\nManual edit outside the managed block.\n").write(to: target, atomically: true, encoding: .utf8)

        await store.close()
        try await store.prepare()
        await writer.injectFaults([])
        await worker.runOnce(now: Date().addingTimeInterval(100))
        let final = try await store.binding(destinationID: destination.id, sessionID: meeting.id, component: .meeting)
        XCTAssertEqual(final?.lastExportedRevision, 2)
        XCTAssertEqual(final?.state, .exported)
        let pending = try await store.outboxCount()
        XCTAssertEqual(pending, 0)
        let text = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(text.contains("Manual edit outside the managed block."))
        XCTAssertEqual(MarkdownStructureScanner.scan(text).managedBlocks.count, 1)
    }

    func testConflictReplacementUsesReviewedBytesAndPreservesOutsideEdits() async throws {
        let (store, destination) = try await makeStoreWithDestination()
        let meeting = MeetingSessionRecord(title: "Review conflict", startedAt: Date())
        try await store.upsertSession(meeting)
        _ = try await store.saveNote(sessionID: meeting.id, markdown: "original revision")
        try await store.saveInObsidian(meeting.id)
        let worker = makeWorker(store: store)
        await worker.runOnce()
        let binding = try await store.binding(destinationID: destination.id, sessionID: meeting.id, component: .meeting)
        let target = vault.appendingPathComponent(try XCTUnwrap(binding?.relativePath))
        let initial = try String(contentsOf: target, encoding: .utf8)
        let external = initial.replacingOccurrences(of: "original revision", with: "reviewed external revision")
            .replacingOccurrences(of: "title: \"Review conflict\"", with: "title: \"External metadata\"") + "\nExternal journal\n"
        try external.write(to: target, atomically: true, encoding: .utf8)

        _ = try await store.saveNote(sessionID: meeting.id, markdown: "queued local revision")
        await worker.runOnce()
        let conflicts = try await worker.conflicts()
        let review = try await worker.compare(try XCTUnwrap(conflicts.first))
        XCTAssertTrue(review.external.contains("reviewed external revision"))
        XCTAssertTrue(review.external.contains("External metadata"))
        XCTAssertTrue(review.local.contains("queued local revision"))
        XCTAssertNotNil(review.observedBlockHash)

        let changed = external.replacingOccurrences(of: "reviewed external revision", with: "newer external revision")
        try changed.write(to: target, atomically: true, encoding: .utf8)
        try await worker.replaceConflictingBlock(review)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), changed)

        let updatedConflicts = try await worker.conflicts()
        let updated = try await worker.compare(try XCTUnwrap(updatedConflicts.first))
        try await worker.replaceConflictingBlock(updated)
        let final = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(final.contains("queued local revision"))
        XCTAssertTrue(final.contains("External journal"))
        XCTAssertFalse(final.contains("newer external revision"))
        XCTAssertFalse(final.contains("External metadata"))
        let remaining = try await worker.conflicts()
        XCTAssertTrue(remaining.isEmpty)
        let backupFolder = backups.appendingPathComponent(ObsidianFileWriter.safeBackupName(for: target))
        let savedBackups = try FileManager.default.contentsOfDirectory(at: backupFolder, includingPropertiesForKeys: nil)
        XCTAssertTrue(savedBackups.contains { (try? String(contentsOf: $0, encoding: .utf8)) == changed })
    }

    func testCoordinatedWriterRevalidatesVaultContainment() async throws {
        let outside = temp.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let linked = vault.appendingPathComponent("Changed folder")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        let target = linked.appendingPathComponent("Meeting.md")
        let writer = ObsidianFileWriter(backupRoot: backups)
        do {
            _ = try await writer.write(target: target, content: "must stay within vault", expectedIdentity: nil,
                vaultRoot: vault, relativePath: "Changed folder/Meeting.md")
            XCTFail("A newly inserted vault symlink must block the write")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("Meeting.md").path))
        }
    }

    func testEditedLegacyFrontmatterDoesNotBecomeOwnedAfterBodySync() async throws {
        let (store, destination) = try await makeStoreWithDestination()
        let meeting = MeetingSessionRecord(title: "Legacy YAML", startedAt: Date())
        try await store.upsertSession(meeting)
        _ = try await store.saveNote(sessionID: meeting.id, markdown: "initial")
        try await store.saveInObsidian(meeting.id)
        let worker = makeWorker(store: store)
        await worker.runOnce()
        let stored = try await store.binding(destinationID: destination.id, sessionID: meeting.id, component: .meeting)
        var legacy = try XCTUnwrap(stored)
        legacy.lastMetadataSHA256 = nil
        legacy.metadataOwnershipEvaluated = nil
        try await store.saveBinding(legacy)
        let file = vault.appendingPathComponent(legacy.relativePath)
        let original = try String(contentsOf: file, encoding: .utf8)
        let userTitle = "title: \"Manually edited YAML\""
        try original.replacingOccurrences(of: "title: \"Legacy YAML\"", with: userTitle)
            .write(to: file, atomically: true, encoding: .utf8)
        _ = try await store.saveNote(sessionID: meeting.id, markdown: "one")
        await worker.runOnce()
        _ = try await store.saveNote(sessionID: meeting.id, markdown: "two")
        await worker.runOnce()
        let updated = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(updated.contains(userTitle))
        XCTAssertTrue(updated.contains("two"))
    }
}
