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
    private var processing = false
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
        guard !processing else { return }
        processing = true
        defer { processing = false }
        guard let destination = try? await store.destination() else {
            stopVaultAccess()
            return
        }
        let due = ((try? await store.dueOutbox(now: now)) ?? []).filter {
            $0.destinationID == destination.id && $0.intent.permitted(by: destination)
        }
        guard !due.isEmpty else { return }
        guard let vault = await resolveVault(destination) else { return }
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
                try? await Task.sleep(for: .milliseconds(500))
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
        var component = ObsidianExportComponent.meeting
        do {
            guard let snapshot = row.snapshot, snapshot.session.exportRevision == row.desiredRevision else {
                throw ObsidianExportError.staleRevision
            }
            var meetingRelativePath: String?
            for required in destination.mode.requiredComponents {
                component = required
                guard let receipt = try await exportComponent(required, row: row, destination: destination, vault: vault,
                    snapshot: snapshot, meetingRelativePath: meetingRelativePath, now: now) else { return }
                if required == .meeting { meetingRelativePath = receipt.relativePath }
            }
            try await store.completeOutbox(destinationID: ids.0, sessionID: ids.1,
                throughRevision: row.desiredRevision, configRevision: row.desiredConfigRevision)
            onLog("obsidian-exported", ["session": ids.1.uuidString, "revision": row.desiredRevision])
        } catch {
            let failure = error as? ObsidianExportError
            let code = failure.map { String(describing: $0) } ?? "fileAccess"
            if (try? await store.isAuthorizedForWrite(row)) == true {
                try? await store.failOutbox(destinationID: ids.0, sessionID: ids.1,
                    errorCode: code, transient: failure?.isTransient ?? true, now: now,
                    expectedRevision: row.desiredRevision, configRevision: row.desiredConfigRevision)
                try? await markBinding(destinationID: ids.0, sessionID: ids.1, component: component,
                    state: failure?.isTransient == false ? .conflict : .failed, errorCode: code)
            }
            onLog("obsidian-export-failed", ["session": ids.1.uuidString, "error": code])
        }
    }

    private func exportComponent(_ component: ObsidianExportComponent, row: ObsidianOutboxRecord,
                                 destination: ObsidianDestinationRecord, vault: URL, snapshot: ObsidianExportSnapshot,
                                 meetingRelativePath: String?, now: Date) async throws -> ObsidianExportBindingRecord? {
        let session = snapshot.session
        let existing = try await store.binding(destinationID: destination.id, sessionID: session.id, component: component)
        var relativePath = existing?.relativePath ?? ObsidianComponentRenderer.relativePath(for: component,
            destination: destination, snapshot: snapshot)
        if existing == nil, component == .meeting {
            relativePath = try availableMeetingPath(relativePath, in: vault)
        }
        guard case .success(let target) = ObsidianVaultAccess.validate(relativePath: relativePath, in: vault),
              case .success(let fileTarget) = ObsidianVaultAccess.validateFileTarget(target) else {
            throw ObsidianExportError.pathEscapesVault(relativePath)
        }
        var binding = existing ?? ObsidianExportBindingRecord(
            destinationID: destination.id, sessionID: session.id, component: component, relativePath: relativePath,
            markerID: ManagedBlock.newNonce(), lastExportedRevision: 0, lastBlockSHA256: nil, lastFileSHA256: nil,
            state: .idle, errorCode: nil, updatedAt: now)
        if existing == nil { try await store.saveBinding(binding) }

        let expected = try ObsidianFileWriter.FileIdentity.fingerprint(fileTarget)
        if expected == nil, binding.lastExportedRevision > 0 {
            throw ObsidianExportError.markerDamage("The previously exported file is missing or was moved.")
        }
        let existingText = expected == nil ? "" : try String(contentsOf: fileTarget, encoding: .utf8)
        guard try ObsidianFileWriter.FileIdentity.fingerprint(fileTarget) == expected else {
            throw ObsidianExportError.destinationChanged
        }
        if let expected,
           var prepared = try await store.preparedExportWrite(destinationID: destination.id, sessionID: session.id, component: component),
           prepared.relativePath == relativePath,
           let nonce = prepared.markerID, let expectedBlock = prepared.lastBlockSHA256,
           expected.sha256 == prepared.lastFileSHA256 ||
            (MarkdownFilePatcher.managedBlockHash(in: existingText, sessionID: session.id,
                nonce: nonce, component: component) == expectedBlock &&
             (try? self.metadataMatches(prepared, in: existingText)) == true) {
            prepared.lastFileSHA256 = expected.sha256
            try await store.commitExportWrite(prepared)
            binding = prepared
        }
        let approval = try await store.approvedObsidianConflict(row: row, component: component)
        if approval == nil, binding.lastExportedRevision >= row.desiredRevision, binding.lastExportedRevision > 0 {
            guard let nonce = binding.markerID,
                  MarkdownFilePatcher.managedBlockHash(in: existingText, sessionID: session.id,
                    nonce: nonce, component: component) == binding.lastBlockSHA256,
                  try metadataMatches(binding, in: existingText) else {
                throw ObsidianExportError.managedBlockConflict
            }
            return binding
        }
        if let approval {
            guard let nonce = binding.markerID,
                  MarkdownFilePatcher.managedBlockHash(in: existingText, sessionID: session.id,
                    nonce: nonce, component: component) == approval.blockHash else {
                throw ObsidianExportError.managedBlockConflict
            }
            binding.lastBlockSHA256 = approval.blockHash
            if binding.lastMetadataSHA256 != nil {
                guard let approved = approval.metadataHash,
                      try ObsidianOwnedMetadata.hash(in: existingText) == approved else {
                    throw ObsidianExportError.managedBlockConflict
                }
                binding.lastMetadataSHA256 = approved
            }
        }
        let result = try ObsidianComponentRenderer.patch(existing: existingText, binding: binding,
            destination: destination, snapshot: snapshot, meetingRelativePath: meetingRelativePath, fileExists: expected != nil)
        var receipt = ObsidianExportBindingRecord(
            destinationID: destination.id, sessionID: session.id, component: component, relativePath: relativePath,
            markerID: binding.markerID, lastExportedRevision: session.exportRevision,
            lastBlockSHA256: result.blockSHA256, lastFileSHA256: result.fileSHA256,
            state: .exported, errorCode: nil, updatedAt: now)
        receipt.lastMetadataSHA256 = result.metadataSHA256
        receipt.metadataOwnershipEvaluated = component == .meeting ? true : nil
        guard try await store.prepareExportWrite(row: row, binding: receipt) else { return nil }
        let outcome = try await writer.write(target: fileTarget, content: result.text, expectedIdentity: expected,
            vaultRoot: vault, relativePath: relativePath)
        receipt.lastFileSHA256 = outcome.identity.sha256
        try await store.commitExportWrite(receipt)
        return receipt
    }

    private func metadataMatches(_ binding: ObsidianExportBindingRecord, in text: String) throws -> Bool {
        guard let expected = binding.lastMetadataSHA256 else { return true }
        return try ObsidianOwnedMetadata.hash(in: text) == expected
    }

    private func availableMeetingPath(_ proposed: String, in vault: URL) throws -> String {
        let path = proposed as NSString
        let base = path.deletingPathExtension
        let ext = path.pathExtension
        for attempt in 1...1000 {
            let candidate = attempt == 1 ? proposed : base + " (\(attempt))." + ext
            guard case .success(let url) = ObsidianVaultAccess.validate(relativePath: candidate, in: vault) else {
                throw ObsidianExportError.pathEscapesVault(candidate)
            }
            if !FileManager.default.fileExists(atPath: url.path), (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil {
                return candidate
            }
        }
        throw ObsidianExportError.notARegularFile(proposed)
    }

    func conflicts() async throws -> [ObsidianConflict] {
        guard let destination = try await store.destination() else { return [] }
        let rows = try await store.outboxRows(destinationID: destination.id).filter(\.paused)
        var conflicts: [ObsidianConflict] = []
        for row in rows {
            for component in destination.mode.requiredComponents {
                if let binding = try await store.binding(destinationID: destination.id, sessionID: row.sessionID, component: component),
                   binding.state == .conflict {
                    conflicts.append(ObsidianConflict(row: row, binding: binding))
                }
            }
        }
        return conflicts.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func compare(_ conflict: ObsidianConflict) async throws -> ObsidianConflictComparison {
        let row = conflict.row, binding = conflict.binding
        guard let destination = try await store.destination(), destination.id == row.destinationID,
              let snapshot = row.snapshot else { throw ObsidianExportError.destinationChanged }
        let copy = MeetingMarkdownTemplate.managedContent(session: snapshot.session, note: snapshot.note,
            outcome: snapshot.outcome, outcomeState: snapshot.outcomeState)
        guard let vault = await resolveVault(destination) else {
            return ObsidianConflictComparison(conflict: conflict, local: copy,
                external: L("Waiting for vault access"), standaloneCopy: copy, observedBlockHash: nil)
        }
        let meetingPath = try await store.binding(destinationID: destination.id, sessionID: row.sessionID,
                                                  component: .meeting)?.relativePath
        guard case .success(let url) = ObsidianVaultAccess.validate(relativePath: binding.relativePath, in: vault),
              case .success = ObsidianVaultAccess.validateFileTarget(url),
              let text = try? String(contentsOf: url, encoding: .utf8), let nonce = binding.markerID else {
            return ObsidianConflictComparison(conflict: conflict, local: copy,
                external: L("The previously exported file could not be read."), standaloneCopy: copy, observedBlockHash: nil)
        }
        let block = MarkdownFilePatcher.managedBlockContent(in: text, sessionID: row.sessionID,
            nonce: nonce, component: binding.component)
        let hash = block.map(MarkdownFilePatcher.sha256)
        var reviewed = binding
        reviewed.lastBlockSHA256 = hash
        let currentMetadata = binding.lastMetadataSHA256 == nil ? nil : try? ObsidianOwnedMetadata.preview(in: text)
        if let currentMetadata { reviewed.lastMetadataSHA256 = MarkdownFilePatcher.sha256(currentMetadata) }
        let candidate = try? ObsidianComponentRenderer.patch(existing: text, binding: reviewed,
            destination: destination, snapshot: snapshot, meetingRelativePath: meetingPath, fileExists: true)
        let local = candidate.flatMap {
            MarkdownFilePatcher.managedBlockContent(in: $0.text, sessionID: row.sessionID,
                nonce: nonce, component: binding.component)
        } ?? copy
        let nextMetadata = currentMetadata == nil ? nil : candidate.flatMap { try? ObsidianOwnedMetadata.preview(in: $0.text) }
        let external = block ?? String(text.prefix(100_000))
        return ObsidianConflictComparison(conflict: conflict, local: conflictText(body: local, metadata: nextMetadata),
            external: conflictText(body: external, metadata: currentMetadata), standaloneCopy: copy,
            observedBlockHash: candidate != nil && binding.lastExportedRevision > 0 ? hash : nil,
            observedMetadataHash: currentMetadata.map(MarkdownFilePatcher.sha256))
    }

    private func conflictText(body: String, metadata: String?) -> String {
        guard let metadata else { return body }
        return "---\n" + metadata + "\n---\n\n" + body
    }

    func replaceConflictingBlock(_ comparison: ObsidianConflictComparison) async throws {
        guard let hash = comparison.observedBlockHash else { throw ObsidianExportError.managedBlockConflict }
        try await store.approveObsidianConflictReplacement(row: comparison.conflict.row,
            component: comparison.conflict.binding.component, observedBlockHash: hash,
            observedMetadataHash: comparison.observedMetadataHash)
        await runOnce()
    }

    private func markBinding(destinationID: UUID, sessionID: UUID, component: ObsidianExportComponent,
                             state: ObsidianBindingState, errorCode: String?) async throws {
        guard var binding = try await store.binding(destinationID: destinationID, sessionID: sessionID, component: component) else { return }
        binding.state = state
        binding.errorCode = errorCode
        try await store.saveBinding(binding)
    }
}
