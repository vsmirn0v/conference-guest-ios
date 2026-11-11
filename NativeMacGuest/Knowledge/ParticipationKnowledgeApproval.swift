import Foundation

/// Scope shown to the user during review. Audience and processor IDs come from the live meeting.
struct ParticipationKnowledgeReviewContext: Equatable, Sendable {
    let audience: ParticipationKnowledgeAudience
    let meetingTitle: String
    let processorID: String
    let processorLabel: String
    let processingDescription: String
    let expiresAt: Date

    func matches(_ live: Self?, now: Date = Date()) -> Bool {
        self == live && !audience.roomIdentity.isEmpty && !processorID.isEmpty && !processorLabel.isEmpty
            && !processingDescription.isEmpty && now < expiresAt
    }
}

/// Folder access is read-only, process local, and separate from any export bookmark.
/// The bookmark permits inspecting individually chosen notes; it never authorizes sharing.
struct ParticipationKnowledgeFolder: Sendable {
    private let bookmark: Data
    let name: String

    init(selectedURL: URL) throws {
        guard selectedURL.isFileURL else { throw ParticipationKnowledgeError.invalidPath }
        try Self.requireLocalVolume(selectedURL)
        bookmark = try selectedURL.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                               includingResourceValuesForKeys: nil, relativeTo: nil)
        name = selectedURL.lastPathComponent
    }

    func withAccess<T>(_ operation: (URL) throws -> T) throws -> T {
        var stale = false
        let root = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                           relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale, root.startAccessingSecurityScopedResource() else { throw ParticipationKnowledgeError.inaccessible }
        defer { root.stopAccessingSecurityScopedResource() }
        try Self.requireLocalVolume(root)
        return try operation(root)
    }

    private static func requireLocalVolume(_ url: URL) throws {
        guard try url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == true else {
            throw ParticipationKnowledgeError.nonlocalVolume
        }
    }

    static func relativePath(selectedURL: URL, root: URL) throws -> String {
        guard root.isFileURL, selectedURL.isFileURL else { throw ParticipationKnowledgeError.invalidPath }
        let folder = root.pathComponents
        let note = selectedURL.pathComponents
        // Compare complete path components, including their original Unicode representation.
        guard note.count > folder.count, folder.elementsEqual(note.prefix(folder.count), by: {
            $0.utf8.elementsEqual($1.utf8)
        }) else { throw ParticipationKnowledgeError.invalidPath }
        return note.dropFirst(folder.count).joined(separator: "/")
    }

    func inspect(relativePath: String) throws -> ParticipationKnowledgeSnapshot {
        try withAccess { try ParticipationKnowledgeReader.inspect(root: $0, relativePath: relativePath) }
    }

    func approve(reviewed: ParticipationKnowledgeSnapshot, context: ParticipationKnowledgeReviewContext) throws -> ParticipationKnowledgeApproval {
        // Never exchange a changed file for the bytes the user saw in the preview.
        guard Date() < context.expiresAt else { throw ParticipationKnowledgeError.expired }
        guard context.matches(context) else { throw ParticipationKnowledgeError.processorDenied }
        let current = try inspect(relativePath: reviewed.relativePath)
        guard current == reviewed else { throw ParticipationKnowledgeError.sourceChanged }
        return .init(grant: .init(id: UUID(), revision: 1, source: current, audience: context.audience,
                                 allowedProcessors: [context.processorID], expiresAt: context.expiresAt), folder: self)
    }
}

/// A local approval plus the authority to re-read its exact file. Store in memory only.
/// Register/revoke `grant` in the same barrier that controls meeting dispatch.
struct ParticipationKnowledgeApproval: Identifiable, Sendable {
    let grant: ParticipationKnowledgeGrant
    fileprivate let folder: ParticipationKnowledgeFolder
    var id: UUID { grant.id }

    func read(scope: ParticipationKnowledgeScope, audience: ParticipationKnowledgeAudience, processor: String,
              now: Date = Date()) throws -> ParticipationKnowledgeSnapshot {
        guard scope.contains(grant) else { throw ParticipationKnowledgeError.revoked }
        let source = try folder.withAccess {
            try scope.read(root: $0, id: grant.id, audience: audience, processor: processor, now: now)
        }
        guard source == grant.source, scope.contains(grant) else { throw ParticipationKnowledgeError.revoked }
        return source
    }
}
