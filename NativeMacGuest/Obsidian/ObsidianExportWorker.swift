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
    private let vaultResolver: (Data) -> (resolution: ObsidianVaultAccess.Resolution, refreshedBookmark: Data?)
    private let transcriptProvider: @Sendable (MeetingSessionRecord) async -> String?
    private var running = false
    private var processing = false
    private var pendingWake = false
    private var loopTask: Task<Void, Never>?
    private var sleepWaiter: (id: UUID, continuation: CheckedContinuation<Void, Never>, timer: Task<Void, Never>)?
    private var vaultCache: (destinationID: UUID, configRevision: Int, url: URL, started: Bool)?

    var onLog: (String, [String: Any]) -> Void = { _, _ in }

    init(store: MeetingLibraryStore, backupRoot: URL, writer: ObsidianFileWriter? = nil,
         vaultResolver: ((Data) -> ObsidianVaultAccess.Resolution)? = nil,
         transcriptProvider: @escaping @Sendable (MeetingSessionRecord) async -> String? = { _ in nil },
         onLog: @escaping (String, [String: Any]) -> Void = { _, _ in }) {
        self.store = store
        self.backupRoot = backupRoot
        self.writer = writer ?? ObsidianFileWriter(backupRoot: backupRoot)
        if let vaultResolver {
            self.vaultResolver = { (vaultResolver($0), nil) }
        } else {
            self.vaultResolver = { ObsidianVaultAccess.resolveWithRefresh($0) }
        }
        self.transcriptProvider = transcriptProvider
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

    /// Starts the background loop: immediate pass, then event-driven wake + smart retry sleep.
    func start() {
        store.setOutboxWakeHandler { [weak self] in
            self?.wake()
        }
        if running {
            wakeIsolated()
            return
        }
        running = true
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.clearPendingWake()
                await self.runOnce()
                let delay = await self.nextSleepDelay()
                await self.waitForWakeOrDelay(delay)
            }
        }
    }

    /// Wakes the background loop immediately when new outbox rows are queued or settings change.
    nonisolated func wake() {
        Task { await self.wakeIsolated() }
    }

    private func clearPendingWake() {
        pendingWake = false
    }

    private func wakeIsolated() {
        pendingWake = true
        finishSleepWaiter()
    }

    private func finishSleepWaiter(id: UUID? = nil) {
        guard let waiter = sleepWaiter, id == nil || waiter.id == id else { return }
        sleepWaiter = nil
        waiter.timer.cancel()
        waiter.continuation.resume()
    }

    private func nextSleepDelay(now: Date = Date()) async -> TimeInterval {
        guard let destination = try? await store.destination(),
              destination.enabled,
              destination.vaultBookmark != nil else {
            return 30.0
        }
        if let nextAttempt = try? await store.earliestActiveOutboxAttempt(destinationID: destination.id) {
            return min(15.0, max(0.25, nextAttempt.timeIntervalSince(now)))
        }
        return 15.0
    }

    private func waitForWakeOrDelay(_ delay: TimeInterval) async {
        if pendingWake || !running || Task.isCancelled { return }
        finishSleepWaiter()
        let waiterID = UUID()
        let _: Void = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if pendingWake || !running || Task.isCancelled {
                    continuation.resume()
                    return
                }
                let ms = max(50, Int((delay * 1000).rounded()))
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(ms))
                    await self?.finishSleepWaiter(id: waiterID)
                }
                sleepWaiter = (waiterID, continuation, timer)
            }
        }, onCancel: { [weak self] in
            Task { await self?.finishSleepWaiter(id: waiterID) }
        })
    }

    /// Stops the background loop and releases any security-scoped vault access.
    /// Safe to call from any isolation context.
    nonisolated func stop() {
        Task { await self.stopIsolated() }
    }

    private func stopIsolated() {
        running = false
        finishSleepWaiter()
        loopTask?.cancel()
        loopTask = nil
        stopVaultAccess()
    }

    /// Checks whether `destination`'s vault is accessible off the main thread, reusing
    /// the worker's active security-scoped handle when already open so status polling never
    /// blocks `@MainActor` or races `stopAccessingSecurityScopedResource()`.
    func isVaultAccessible(for destination: ObsidianDestinationRecord) async -> Bool {
        if let cache = vaultCache,
           cache.destinationID == destination.id,
           cache.configRevision == destination.configRevision,
           cache.started {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: cache.url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        return await resolveVault(destination) != nil
    }

    private func resolveVault(_ destination: ObsidianDestinationRecord) async -> URL? {
        if let cache = vaultCache, cache.destinationID == destination.id,
           cache.configRevision == destination.configRevision, cache.started {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: cache.url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return cache.url
            }
        }
        stopVaultAccess()
        guard let bookmark = destination.vaultBookmark else {
            onLog("obsidian-export-no-bookmark", [:])
            return nil
        }
        let resolved = vaultResolver(bookmark)
        switch resolved.resolution {
        case .granted(let url):
            if let refreshed = resolved.refreshedBookmark {
                try? await store.refreshDestinationVaultBookmark(
                    id: destination.id,
                    expectedConfigRevision: destination.configRevision,
                    bookmark: refreshed
                )
                onLog("obsidian-export-refreshed-stale-bookmark", ["destination": destination.id.uuidString])
            }
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
            let transcript = destination.layout.sections.contains(.transcript) ? await transcriptProvider(snapshot.session) : nil
            var transcriptRelativePath: String?
            // Deliver the transcript before writing a link to it in the worklog.
            if destination.mode == .worklog, transcript != nil {
                component = .transcript
                guard let receipt = try await exportComponent(component, row: row, destination: destination, vault: vault,
                    snapshot: snapshot, meetingRelativePath: nil, transcriptBody: transcript, now: now) else { return }
                transcriptRelativePath = receipt.relativePath
            }
            var meetingRelativePath: String?
            for required in destination.mode.requiredComponents {
                component = required
                guard let receipt = try await exportComponent(required, row: row, destination: destination, vault: vault,
                    snapshot: snapshot, meetingRelativePath: meetingRelativePath, transcriptBody: transcript,
                    transcriptRelativePath: transcriptRelativePath, now: now) else { return }
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
                                 meetingRelativePath: String?, transcriptBody: String?,
                                 transcriptRelativePath: String? = nil, now: Date) async throws -> ObsidianExportBindingRecord? {
        let session = snapshot.session
        let existing = try await store.binding(destinationID: destination.id, sessionID: session.id, component: component)
        var relativePath = existing?.relativePath ?? ObsidianComponentRenderer.relativePath(for: component,
            destination: destination, snapshot: snapshot)
        if existing == nil, component == .meeting || component == .transcript {
            let reservedPath = component == .transcript
                ? ObsidianComponentRenderer.relativePath(for: .worklog, destination: destination, snapshot: snapshot) : nil
            relativePath = try availableIndividualPath(relativePath, in: vault, excluding: reservedPath)
        }
        let section = ObsidianComponentRenderer.transcriptSection(component: component, layout: destination.layout,
            path: relativePath, body: transcriptBody, transcriptPath: transcriptRelativePath)
        let transcriptSignature = destination.layout.sections.contains(.transcript) && component != .index
            ? (section.isEmpty ? "" : MarkdownFilePatcher.sha256(section)) : nil
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
        if approval == nil, binding.lastExportedRevision >= row.desiredRevision, binding.lastExportedRevision > 0,
           binding.transcriptSignature == transcriptSignature {
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
            destination: destination, snapshot: snapshot, meetingRelativePath: meetingRelativePath,
            transcriptBody: transcriptBody, transcriptRelativePath: transcriptRelativePath, fileExists: expected != nil)
        if let reviewed = approval?.proposedBlockHash, reviewed != result.blockSHA256 {
            throw ObsidianExportError.managedBlockConflict
        }
        var receipt = ObsidianExportBindingRecord(
            destinationID: destination.id, sessionID: session.id, component: component, relativePath: relativePath,
            markerID: binding.markerID, lastExportedRevision: session.exportRevision,
            lastBlockSHA256: result.blockSHA256, lastFileSHA256: result.fileSHA256,
            state: .exported, errorCode: nil, updatedAt: now)
        receipt.lastMetadataSHA256 = result.metadataSHA256
        receipt.metadataOwnershipEvaluated = component == .meeting ? true : nil
        receipt.transcriptSignature = transcriptSignature
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

    private func availableIndividualPath(_ proposed: String, in vault: URL, excluding reservedPath: String?) throws -> String {
        let path = proposed as NSString
        let base = path.deletingPathExtension
        let ext = path.pathExtension
        for attempt in 1...1000 {
            let candidate = attempt == 1 ? proposed : base + " (\(attempt))." + ext
            if let reservedPath, candidate.caseInsensitiveCompare(reservedPath) == .orderedSame { continue }
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
            let components = destination.mode == .worklog ? [.transcript, .worklog] : destination.mode.requiredComponents
            for component in components {
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
        let transcript = destination.layout.sections.contains(.transcript) ? await transcriptProvider(snapshot.session) : nil
        let copy = MeetingMarkdownTemplate.managedContent(session: snapshot.session, note: snapshot.note,
            outcome: snapshot.outcome, outcomeState: snapshot.outcomeState)
            + ObsidianComponentRenderer.transcriptSection(component: .meeting, layout: destination.layout,
                path: binding.relativePath, body: transcript, transcriptPath: nil)
        guard let vault = await resolveVault(destination) else {
            return ObsidianConflictComparison(conflict: conflict, local: copy,
                external: L("Waiting for vault access"), standaloneCopy: copy, observedBlockHash: nil)
        }
        let meetingPath = try await store.binding(destinationID: destination.id, sessionID: row.sessionID,
                                                  component: .meeting)?.relativePath
        let transcriptPath = try await store.binding(destinationID: destination.id, sessionID: row.sessionID,
                                                     component: .transcript)?.relativePath
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
            destination: destination, snapshot: snapshot, meetingRelativePath: meetingPath,
            transcriptBody: transcript, transcriptRelativePath: transcriptPath, fileExists: true)
        let local = candidate.flatMap {
            MarkdownFilePatcher.managedBlockContent(in: $0.text, sessionID: row.sessionID,
                nonce: nonce, component: binding.component)
        } ?? copy
        let nextMetadata = currentMetadata == nil ? nil : candidate.flatMap { try? ObsidianOwnedMetadata.preview(in: $0.text) }
        let external = block ?? String(text.prefix(100_000))
        return ObsidianConflictComparison(conflict: conflict, local: conflictText(body: local, metadata: nextMetadata),
            external: conflictText(body: external, metadata: currentMetadata), standaloneCopy: copy,
            observedBlockHash: candidate != nil && binding.lastExportedRevision > 0 ? hash : nil,
            observedMetadataHash: currentMetadata.map(MarkdownFilePatcher.sha256),
            proposedBlockHash: candidate?.blockSHA256)
    }

    private func conflictText(body: String, metadata: String?) -> String {
        guard let metadata else { return body }
        return "---\n" + metadata + "\n---\n\n" + body
    }

    func replaceConflictingBlock(_ comparison: ObsidianConflictComparison) async throws {
        guard let hash = comparison.observedBlockHash else { throw ObsidianExportError.managedBlockConflict }
        try await store.approveObsidianConflictReplacement(row: comparison.conflict.row,
            component: comparison.conflict.binding.component, observedBlockHash: hash,
            observedMetadataHash: comparison.observedMetadataHash, proposedBlockHash: comparison.proposedBlockHash)
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
