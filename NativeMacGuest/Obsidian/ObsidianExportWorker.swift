import Foundation

/// Actor-owned export loop. One pass drains the due outbox rows; each session's file
/// is written with read → conflict check → backup → atomic replace → verify → binding
/// commit. A worker never applies an older snapshot over a newer local revision: the
/// session row is re-read at commit time and a stale desired revision discards the
/// render. Retry uses the store's exponential backoff; conflicts pause the row.
actor ObsidianExportWorker {
    private let store: MeetingLibraryStore
    private let backupRoot: URL
    private let writer: ObsidianFileWriter
    private let vaultResolver: (Data) -> ObsidianVaultAccess.Resolution
    private var running = false
    private var loopTask: Task<Void, Never>?
    private var vaultCache: (destinationID: UUID, configRevision: Int, url: URL, started: Bool)?

    var onLog: (String, [String: Any]) -> Void = { _, _ in }

    init(store: MeetingLibraryStore, backupRoot: URL, writer: ObsidianFileWriter? = nil,
         vaultResolver: ((Data) -> ObsidianVaultAccess.Resolution)? = nil,
         onLog: @escaping (String, [String: Any]) -> Void = { _, _ in }) {
        self.store = store
        self.backupRoot = backupRoot
        self.writer = writer ?? ObsidianFileWriter(backupRoot: backupRoot)
        self.vaultResolver = vaultResolver ?? { ObsidianVaultAccess.resolve($0) }
        self.onLog = onLog
    }

    /// Runs one pass over every due outbox row; used by the timer and by tests.
    func runOnce(now: Date = Date()) async {
        guard let destination = try? await store.destination(), destination.enabled else {
            vaultCache = nil
            return
        }
        guard let vault = await resolveVault(destination) else { return }
        let due = (try? await store.dueOutbox(now: now)) ?? []
        for row in due {
            await export(row: row, destination: destination, vault: vault, now: now)
        }
    }

    /// Starts the background loop: immediate pass, then a poll until stopped.
    func start() {
        guard !running else { return }
        running = true
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.runOnce()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Stops the background loop and releases any security-scoped vault access.
    /// Safe to call from any isolation context.
    nonisolated func stop() {
        Task { await self.stopIsolated() }
    }

    private func stopIsolated() {
        running = false
        loopTask?.cancel()
        loopTask = nil
        stopVaultAccess()
    }

    private func resolveVault(_ destination: ObsidianDestinationRecord) async -> URL? {
        if let cache = vaultCache, cache.destinationID == destination.id,
           cache.configRevision == destination.configRevision, cache.started {
            return cache.url
        }
        stopVaultAccess()
        guard let bookmark = destination.vaultBookmark else {
            onLog("obsidian-export-no-bookmark", [:])
            return nil
        }
        switch vaultResolver(bookmark) {
        case .granted(let url):
            vaultCache = (destination.id, destination.configRevision, url, true)
            return url
        case .stale:
            onLog("obsidian-export-stale-bookmark", ["destination": destination.id.uuidString])
            return nil
        case .missing:
            onLog("obsidian-export-vault-missing", [:])
            return nil
        case .denied(let message):
            onLog("obsidian-export-vault-denied", ["error": message])
            return nil
        }
    }

    private func stopVaultAccess() {
        vaultCache?.url.stopAccessingSecurityScopedResource()
        vaultCache = nil
    }

    private func export(row: ObsidianOutboxRecord, destination: ObsidianDestinationRecord,
                        vault: URL, now: Date) async {
        let ids = (destination.id, row.sessionID)
        do {
            // Latest snapshot at render time: never export an older revision over a newer one.
            guard let session = try await store.session(row.sessionID) else {
                try await store.completeOutbox(destinationID: ids.0, sessionID: ids.1)
                return
            }
            guard session.exportRevision >= row.desiredRevision else {
                throw ObsidianExportError.staleRevision
            }
            let note = try await store.note(row.sessionID)
            let outcome = try await store.outcomeBySession(row.sessionID)
            let outcomeState = outcome == nil ? MeetingOutcomePersistenceState.notStarted
                : (try await store.outcomeState(outcome!.id)) ?? .ready
            guard note != nil || outcome != nil else {
                // Nothing to export yet; wait for content.
                try await store.failOutbox(destinationID: ids.0, sessionID: ids.1,
                    errorCode: "empty", transient: true, now: now.addingTimeInterval(2))
                return
            }
            let folder = destination.meetingFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let fileName = MeetingMarkdownTemplate.meetingFileName(title: session.title, sessionID: session.id)
            let relativePath = folder.isEmpty ? fileName : folder + "/" + fileName
            guard case .success(let target) = ObsidianVaultAccess.validate(relativePath: relativePath, in: vault),
                  case .success(let fileTarget) = ObsidianVaultAccess.validateFileTarget(target) else {
                throw ObsidianExportError.pathEscapesVault(relativePath)
            }
            var binding = try await store.binding(destinationID: ids.0, sessionID: ids.1, component: .meeting)
            if binding == nil {
                binding = ObsidianExportBindingRecord(
                    destinationID: ids.0, sessionID: ids.1, component: .meeting, relativePath: relativePath,
                    markerID: ManagedBlock.newNonce(), lastExportedRevision: 0,
                    lastBlockSHA256: nil, lastFileSHA256: nil, state: .idle, errorCode: nil, updatedAt: now)
            }
            guard let nonce = binding?.markerID else { return }

            let content = MeetingMarkdownTemplate.managedContent(
                session: session, note: note, outcome: outcome, outcomeState: outcomeState)
            let existingText = (try? String(contentsOf: fileTarget, encoding: .utf8)) ?? ""
            if MarkdownStructureScanner.markerLikeContentExists(existingText), binding?.lastExportedRevision == 0 {
                // A pre-existing file contains marker-like content: own it with a fresh
                // nonce so note text can never forge ownership.
                binding?.markerID = ManagedBlock.newNonce()
            }
            let activeNonce = binding?.markerID ?? nonce
            let result: MarkdownFilePatcher.PatchResult
            if existingText.isEmpty {
                let frontmatter = MeetingMarkdownTemplate.frontmatter(
                    session: session, note: note, outcome: outcome, outcomeState: outcomeState,
                    exportRevision: session.exportRevision)
                result = MarkdownFilePatcher.create(sessionID: session.id, nonce: activeNonce,
                    frontmatter: frontmatter, managedContent: content)
            } else {
                result = try MarkdownFilePatcher.patch(
                    existing: existingText, sessionID: session.id, nonce: activeNonce,
                    component: .meeting, managedContent: content,
                    expectedBlockSHA256: binding?.lastBlockSHA256)
            }

            // Re-read identity right before the write; a racing external edit discards
            // this render and retries against fresh bytes.
            let expected = try ObsidianFileWriter.FileIdentity.fingerprint(fileTarget)
            let outcome2 = try await writer.write(target: fileTarget, content: result.text, expectedIdentity: expected)
            guard session.exportRevision >= row.desiredRevision else {
                throw ObsidianExportError.staleRevision
            }
            try await store.saveBinding(ObsidianExportBindingRecord(
                destinationID: ids.0, sessionID: ids.1, component: .meeting, relativePath: relativePath,
                markerID: activeNonce, lastExportedRevision: session.exportRevision,
                lastBlockSHA256: result.blockSHA256, lastFileSHA256: outcome2.identity.sha256,
                state: .exported, errorCode: nil, updatedAt: now))
            try await store.completeOutbox(destinationID: ids.0, sessionID: ids.1)
            onLog("obsidian-exported", ["session": ids.1.uuidString, "revision": session.exportRevision])
        } catch let error as ObsidianExportError {
            let code = String(describing: error)
            try? await store.failOutbox(destinationID: ids.0, sessionID: ids.1,
                errorCode: code, transient: error.isTransient, now: now)
            try? await markBinding(destinationID: ids.0, sessionID: ids.1,
                state: error == .managedBlockConflict ? .conflict : .failed, errorCode: code)
            onLog("obsidian-export-failed", ["session": ids.1.uuidString, "error": code])
        } catch {
            let code = String(describing: error)
            try? await store.failOutbox(destinationID: ids.0, sessionID: ids.1,
                errorCode: code, transient: true, now: now)
            try? await markBinding(destinationID: ids.0, sessionID: ids.1, state: .failed, errorCode: code)
            onLog("obsidian-export-failed", ["session": ids.1.uuidString, "error": code])
        }
    }

    private func markBinding(destinationID: UUID, sessionID: UUID, state: ObsidianBindingState, errorCode: String?) async throws {
        guard var binding = try await store.binding(destinationID: destinationID, sessionID: sessionID, component: .meeting) else { return }
        binding.state = state
        binding.errorCode = errorCode
        try await store.saveBinding(binding)
    }
}
