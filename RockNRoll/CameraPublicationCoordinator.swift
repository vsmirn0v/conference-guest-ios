import Foundation

/// Initial publication can briefly expose a track before cancellation removes it.
/// Drain that work before reusing a track or applying a later camera intent.
@MainActor
final class CameraPublicationCoordinator<Publication: Sendable> {
    private var pending: (id: UUID, task: Task<Publication, Error>)?

    func cancel() {
        pending?.task.cancel()
        pending = nil
    }

    func set(enabled: Bool, isCurrent: () -> Bool, hasPublication: () -> Bool,
             update: (Bool) async throws -> Publication?,
             create: @escaping @MainActor () async throws -> Publication) async throws -> Publication? {
        func validate() throws {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
        }
        try validate()
        if !enabled {
            if let old = pending {
                old.task.cancel()
                _ = try? await old.task.value
                if pending?.id == old.id { pending = nil }
            }
            try validate()
            return try await update(false)
        }
        while let old = pending {
            do { _ = try await old.task.value }
            catch {
                if pending?.id == old.id { pending = nil }
                try validate()
                // A newer ON may follow an OFF which cancelled this creation.
                // Real publication failures still reach the caller unchanged.
                if !old.task.isCancelled { throw error }
            }
            if pending?.id == old.id { pending = nil }
            try validate()
        }
        try validate()
        if hasPublication() { return try await update(true) }
        let id = UUID()
        let task = Task { @MainActor in try await create() }
        pending = (id, task)
        defer { if pending?.id == id { pending = nil } }
        return try await task.value
    }
}
