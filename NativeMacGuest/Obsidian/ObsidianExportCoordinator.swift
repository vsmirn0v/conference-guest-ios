import AppKit
import Foundation

/// MainActor projection of the Obsidian export integration: settings, status and
/// user actions. The heavy lifting lives in the actor worker; this class only turns
/// UI intent into destination/queue state.
@MainActor final class ObsidianExportCoordinator: ObservableObject {
    @Published private(set) var destination: ObsidianDestinationRecord?
    @Published private(set) var pendingCount = 0
    @Published private(set) var conflictCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var vaultName: String?

    private let library: MeetingLibraryController
    private let worker: ObsidianExportWorker
    private var statusTask: Task<Void, Never>?

    var isEnabled: Bool { destination?.enabled == true }

    init(library: MeetingLibraryController, worker: ObsidianExportWorker? = nil) {
        self.library = library
        let root = library.store.storeRoot.appendingPathComponent("MeetingLibrary/ExportBackups", isDirectory: true)
        self.worker = worker ?? ObsidianExportWorker(store: library.store, backupRoot: root) { event, fields in
            probeLog(event, fields)
        }
    }

    func load() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.destination = try? await self.library.store.destination()
            await self.refreshStatus()
            if self.destination?.enabled == true { await self.worker.start() }
        }
    }

    /// Picks a vault and enables Mode A (separate meeting files).
    func enable() {
        guard let choice = ObsidianVaultAccess.chooseVaultBookmark() else { return }
        var record = destination ?? ObsidianDestinationRecord()
        record.enabled = true
        record.mode = .separateFiles
        record.configRevision += 1
        record.vaultBookmark = choice.bookmark
        destination = record
        vaultName = choice.url.lastPathComponent
        Task { [weak self] in
            guard let self else { return }
            try? await self.library.store.saveDestination(record)
            await self.worker.start()
            await self.refreshStatus()
        }
    }

    /// Disabling stops new attempts and retries; queue, bindings and local originals stay.
    func disable() {
        guard var record = destination else { return }
        record.enabled = false
        record.configRevision += 1
        destination = record
        worker.stop()
        Task { [weak self] in
            guard let self else { return }
            try? await self.library.store.saveDestination(record)
            await self.refreshStatus()
        }
    }

    /// Re-grants access after a stale bookmark.
    func reauthorize() {
        guard var record = destination else { return }
        guard let choice = ObsidianVaultAccess.chooseVaultBookmark() else { return }
        record.vaultBookmark = choice.bookmark
        record.configRevision += 1
        destination = record
        vaultName = choice.url.lastPathComponent
        Task { [weak self] in
            guard let self else { return }
            try? await self.library.store.saveDestination(record)
            await self.refreshStatus()
        }
    }

    /// Retries paused rows after a conflict resolution or recovery.
    func retryAll() {
        Task { [weak self] in
            guard let self else { return }
            try? await self.library.store.retryAllOutbox()
            await self.worker.start()
            await self.refreshStatus()
        }
    }

    func refreshStatus() async {
        guard let destination else { return }
        let outbox = (try? await library.store.dueOutbox(now: .distantFuture)) ?? []
        pendingCount = outbox.filter { !$0.paused }.count
        conflictCount = outbox.filter { $0.paused }.count
        lastError = outbox.first(where: { $0.paused })?.lastErrorCode
    }

    private var statusLoop: Task<Void, Never>?
    func startStatusLoop() {
        guard statusLoop == nil else { return }
        statusLoop = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                await self.refreshStatus()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopStatusLoop() {
        statusLoop?.cancel()
        statusLoop = nil
    }
}
