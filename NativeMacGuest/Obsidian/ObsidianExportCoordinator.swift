import AppKit
import Foundation

@MainActor final class ObsidianExportCoordinator: ObservableObject {
    @Published private(set) var destination: ObsidianDestinationRecord?
    @Published private(set) var pendingCount = 0
    @Published private(set) var heldCount = 0
    @Published private(set) var conflictCount = 0
    @Published private(set) var partialCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var vaultName: String?
    @Published private(set) var lastSuccess: (revision: Int, date: Date)?
    @Published private(set) var waitingForVault = false

    private let library: MeetingLibraryController
    private let worker: ObsidianExportWorker
    private var settingsWrite: Task<Void, Never>?
    private var statusLoop: Task<Void, Never>?

    var isEnabled: Bool { destination?.enabled == true }
    var saveAfterMeeting: Bool { destination?.saveAfterMeeting == true }
    var syncChanges: Bool { destination?.syncChanges == true }

    init(library: MeetingLibraryController, worker: ObsidianExportWorker? = nil,
         archive: TranscriptArchiveStore = TranscriptArchiveStore()) {
        self.library = library
        let root = library.store.storeRoot.appendingPathComponent("ExportBackups", isDirectory: true)
        let journal = library.workspaceJournal
        let resolvedWorker = worker ?? ObsidianExportWorker(store: library.store, backupRoot: root, transcriptProvider: { session in
            let events = await journal.exportSyncedEvents(sessionID: session.id, deviceID: "")
            if let body = MeetingMarkdownTemplate.transcriptBody(events: events, startedAt: session.recordedStart) {
                return body
            }
            let archived = await archive.loadTranscript(sessionID: session.id) ?? []
            return MeetingMarkdownTemplate.transcriptBody(events: archived, startedAt: session.recordedStart)
        }) { event, fields in
            probeLog(event, fields)
        }
        self.worker = resolvedWorker
        library.store.setOutboxWakeHandler { [weak resolvedWorker] in
            resolvedWorker?.wake()
        }
    }

    func load() {
        Task { [weak self] in
            guard let self else { return }
            await settingsWrite?.value
            destination = try? await library.store.destination()
            await refreshStatus()
            await worker.start()
        }
    }

    func setEnabled(_ value: Bool) { update { $0.enabled = value } }
    func setSaveAfterMeeting(_ value: Bool) { update { $0.saveAfterMeeting = value } }
    func setSyncChanges(_ value: Bool) { update { $0.syncChanges = value } }

    func setLayout(mode: ObsidianExportMode, meetingFolder: String, layout: ObsidianExportLayout) {
        update { destination in
            if destination.mode != mode || destination.meetingFolder != meetingFolder ||
                destination.layout.documentPath != layout.documentPath || destination.layout.monthly != layout.monthly {
                destination.id = UUID()
            }
            destination.mode = mode
            destination.meetingFolder = meetingFolder
            destination.layout = layout
        }
    }

    func chooseVault() {
        guard let choice = ObsidianVaultAccess.chooseVaultBookmark() else { return }
        let connection = library.participationVaultConnection
        let change = connection.beginChange()
        update { destination in
            if let bookmark = destination.vaultBookmark,
               !ObsidianVaultAccess.identifiesSameVault(bookmark, selected: choice.url) {
                destination.id = UUID()
                destination.layout.legacyRuntimeYears = nil
            }
            destination.vaultBookmark = choice.bookmark
        }
        let save = settingsWrite
        Task {
            await save?.value
            connection.endChange(change)
        }
    }

    private func update(_ change: (inout ObsidianDestinationRecord) -> Void) {
        var record = destination ?? ObsidianDestinationRecord()
        change(&record)
        record.configRevision += 1
        destination = record
        let previous = settingsWrite
        settingsWrite = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try await library.store.saveDestination(record)
                await worker.start()
                await refreshStatus()
            } catch {
                if destination?.configRevision == record.configRevision {
                    destination = try? await library.store.destination()
                    lastError = error.localizedDescription
                }
            }
        }
    }

    func retryAccess() {
        Task {
            do {
                try await library.store.retryAllOutbox()
                await worker.runOnce()
                await refreshStatus()
            } catch { lastError = error.localizedDescription }
        }
    }

    func exportPendingNow() async {
        await worker.runOnce()
        await refreshStatus()
    }

    func heldMeetings() async throws -> (ObsidianDestinationRecord, [(id: UUID, title: String, date: MeetingEffectiveDate?, snapshots: [ObsidianExportSnapshot])]) {
        await settingsWrite?.value
        guard let destination = try await library.store.destination() else {
            throw ObsidianExportError.vaultUnavailable(L("Select an Obsidian vault in Settings."))
        }
        return (destination, try await library.store.heldObsidianMeetings(destinationID: destination.id))
    }

    func sendHeld(sessionIDs: Set<UUID>, destination: ObsidianDestinationRecord,
                  snapshots: [UUID: [ObsidianExportSnapshot]]) async throws {
        await settingsWrite?.value
        try await library.store.sendHeldObsidianRows(sessionIDs: sessionIDs, expectedDestination: destination.id,
                                                    expectedConfigRevision: destination.configRevision,
                                                    expectedSnapshots: snapshots)
        await worker.runOnce()
        await refreshStatus()
    }

    func conflicts() async throws -> [ObsidianConflict] { try await worker.conflicts() }

    func compare(_ conflict: ObsidianConflict) async throws -> ObsidianConflictComparison {
        try await worker.compare(conflict)
    }

    func replaceConflictingBlock(_ comparison: ObsidianConflictComparison) async throws {
        try await worker.replaceConflictingBlock(comparison)
        await refreshStatus()
    }

    private func refreshStatus() async {
        guard let destination else { return }
        let rows = (try? await library.store.outboxRows(destinationID: destination.id)) ?? []
        pendingCount = rows.filter { !$0.paused && !$0.policyHeld }.count
        conflictCount = rows.filter(\.paused).count
        partialCount = (try? await library.store.partialObsidianDeliveryCount(destinationID: destination.id)) ?? 0
        heldCount = rows.filter(\.policyHeld).count
            + ((try? await library.store.heldDeferredObsidianCount(destinationID: destination.id)) ?? 0)
        lastError = rows.first(where: { $0.paused })?.lastErrorCode
        lastSuccess = try? await library.store.latestObsidianDelivery(destinationID: destination.id)
        vaultName = destination.vaultBookmark.flatMap(ObsidianVaultAccess.bookmarkedURL)?.lastPathComponent
        if destination.vaultBookmark != nil {
            waitingForVault = !(await worker.isVaultAccessible(for: destination))
            // Pick up any refreshed bookmark persisted by the worker without overwriting an in-flight user edit.
            if settingsWrite == nil, let latest = try? await library.store.destination(),
               latest.id == destination.id, latest.configRevision == destination.configRevision,
               latest.vaultBookmark != destination.vaultBookmark {
                self.destination = latest
            }
        } else {
            waitingForVault = true
        }
    }

    func startStatusLoop() {
        guard statusLoop == nil else { return }
        statusLoop = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refreshStatus()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stopStatusLoop() {
        statusLoop?.cancel()
        statusLoop = nil
    }
}
