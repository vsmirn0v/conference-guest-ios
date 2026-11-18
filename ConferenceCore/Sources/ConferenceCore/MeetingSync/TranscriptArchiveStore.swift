import Foundation

public struct ArchivedTranscriptDocument: Codable, Equatable, Sendable {
    public var schema: Int
    public var sessionID: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var exportedAt: Date
    public var events: [SyncedTranscriptEvent]

    public init(
        schema: Int = 1,
        sessionID: UUID,
        title: String,
        startedAt: Date,
        endedAt: Date? = nil,
        exportedAt: Date = Date(),
        events: [SyncedTranscriptEvent]
    ) {
        self.schema = schema
        self.sessionID = sessionID
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exportedAt = exportedAt
        self.events = events
    }
}

public struct TranscriptArchiveStats: Equatable, Sendable {
    public var archivedCount: Int
    public var totalBytes: Int64
    public var folderName: String?
    public var usesCustomFolder: Bool

    public init(archivedCount: Int, totalBytes: Int64, folderName: String?, usesCustomFolder: Bool) {
        self.archivedCount = archivedCount
        self.totalBytes = totalBytes
        self.folderName = folderName
        self.usesCustomFolder = usesCustomFolder
    }
}

public actor TranscriptArchiveStore {
    public static let bookmarkKey = "workspace.transcriptArchiveBookmark"
    public static let folderNameKey = "workspace.transcriptArchiveFolderName"

    private let defaultRoot: URL
    private let preferences: UserDefaults
    private var indexCache: [UUID: String] = [:]
    private var loadedIndexRoot: URL?

    public init(root: URL? = nil, preferences: UserDefaults = .standard) {
        if let root {
            self.defaultRoot = root
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.defaultRoot = support.appendingPathComponent("RockTranscriptArchive", isDirectory: true)
        }
        self.preferences = preferences
    }

    public func setCustomFolderBookmark(_ bookmarkData: Data?, displayName: String?) {
        if let bookmarkData {
            preferences.set(bookmarkData, forKey: Self.bookmarkKey)
            preferences.set(displayName, forKey: Self.folderNameKey)
        } else {
            preferences.removeObject(forKey: Self.bookmarkKey)
            preferences.removeObject(forKey: Self.folderNameKey)
        }
        loadedIndexRoot = nil
    }

    public func setCustomFolderURL(_ url: URL?) {
        guard let url else {
            setCustomFolderBookmark(nil, displayName: nil)
            return
        }
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        if let bookmark = try? url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil) {
            setCustomFolderBookmark(bookmark, displayName: url.lastPathComponent)
        }
    }

    public func currentFolderName() -> String? {
        preferences.string(forKey: Self.folderNameKey)
    }

    public func archive(session: SyncedMeetingSession, events: [SyncedTranscriptEvent]) async throws {
        guard !events.isEmpty else { return }
        try await withResolvedRoot { root in
            try Self.writeSession(
                sessionID: session.id,
                title: session.title.value,
                startedAt: session.startedAt,
                endedAt: session.endedAt.value,
                events: events,
                into: root,
                index: &self.indexCache
            )
        }
    }

    public func loadTranscript(sessionID: UUID) async -> [SyncedTranscriptEvent]? {
        let custom: [SyncedTranscriptEvent]? = try? await withResolvedRoot { root in
            try self.readSession(sessionID: sessionID, in: root)
        }
        if let custom, !custom.isEmpty {
            return custom
        }
        return try? readSession(sessionID: sessionID, in: defaultRoot)
    }

    public func exportBundle(
        sessions: [(session: SyncedMeetingSession, events: [SyncedTranscriptEvent])],
        to destinationDirectory: URL
    ) async throws -> Int {
        let started = destinationDirectory.startAccessingSecurityScopedResource()
        defer { if started { destinationDirectory.stopAccessingSecurityScopedResource() } }
        var exported = 0
        var temporaryIndex: [UUID: String] = [:]
        for item in sessions where !item.events.isEmpty {
            try Self.writeSession(
                sessionID: item.session.id,
                title: item.session.title.value,
                startedAt: item.session.startedAt,
                endedAt: item.session.endedAt.value,
                events: item.events,
                into: destinationDirectory,
                index: &temporaryIndex
            )
            exported += 1
        }
        return exported
    }

    public func importBundle(from directory: URL) async throws -> [ArchivedTranscriptDocument] {
        let started = directory.startAccessingSecurityScopedResource()
        defer { if started { directory.stopAccessingSecurityScopedResource() } }
        return try Self.scanDocuments(in: directory)
    }

    public func stats() async -> TranscriptArchiveStats {
        let customName = preferences.string(forKey: Self.folderNameKey)
        let usesCustom = preferences.data(forKey: Self.bookmarkKey) != nil
        let summary: (Int, Int64)? = try? await withResolvedRoot { root in
            Self.measureDirectory(root)
        }
        let counts = summary ?? Self.measureDirectory(defaultRoot)
        return TranscriptArchiveStats(
            archivedCount: counts.0,
            totalBytes: counts.1,
            folderName: customName ?? defaultRoot.lastPathComponent,
            usesCustomFolder: usesCustom
        )
    }

    private func withResolvedRoot<T>(_ body: (URL) throws -> T) async throws -> T {
        if let data = preferences.data(forKey: Self.bookmarkKey) {
            var stale = false
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let options: URL.BookmarkResolutionOptions = []
            #endif
            if let resolved = try? URL(
                resolvingBookmarkData: data,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                let accessed = resolved.startAccessingSecurityScopedResource()
                defer { if accessed { resolved.stopAccessingSecurityScopedResource() } }
                if stale {
                    #if os(macOS)
                    let refreshOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
                    #else
                    let refreshOptions: URL.BookmarkCreationOptions = []
                    #endif
                    if let refreshed = try? resolved.bookmarkData(options: refreshOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
                        preferences.set(refreshed, forKey: Self.bookmarkKey)
                    }
                }
                return try body(resolved)
            }
        }
        return try body(defaultRoot)
    }

    private func readSession(sessionID: UUID, in root: URL) throws -> [SyncedTranscriptEvent]? {
        loadIndexIfNeeded(in: root)
        if let relative = indexCache[sessionID] {
            let fileURL = root.appendingPathComponent(relative)
            if let doc = try? Self.decodeDocument(at: fileURL) {
                return doc.events
            }
        }
        let suffix = "-\(sessionID.uuidString.prefix(8)).transcript.json"
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator where fileURL.lastPathComponent.hasSuffix(suffix) {
                if let doc = try? Self.decodeDocument(at: fileURL), doc.sessionID == sessionID {
                    let relative = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
                    indexCache[sessionID] = relative
                    return doc.events
                }
            }
        }
        return nil
    }

    private func loadIndexIfNeeded(in root: URL) {
        guard loadedIndexRoot != root else { return }
        loadedIndexRoot = root
        let indexURL = root.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: indexURL),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else {
            indexCache = [:]
            return
        }
        var parsed: [UUID: String] = [:]
        for (key, value) in raw {
            if let id = UUID(uuidString: key) { parsed[id] = value }
        }
        indexCache = parsed
    }

    private static func writeSession(
        sessionID: UUID,
        title: String,
        startedAt: Date,
        endedAt: Date?,
        events: [SyncedTranscriptEvent],
        into root: URL,
        index: inout [UUID: String]
    ) throws {
        let fm = FileManager.default
        let monthFormatter = DateFormatter()
        monthFormatter.locale = Locale(identifier: "en_US_POSIX")
        monthFormatter.dateFormat = "yyyy-MM"
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        let referenceDate = startedAt == .distantPast ? (endedAt ?? Date()) : startedAt
        let monthFolder = monthFormatter.string(from: referenceDate)
        let dayPrefix = dayFormatter.string(from: referenceDate)
        let folder = root.appendingPathComponent(monthFolder, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let slug = sanitizeSlug(title)
        let baseName = "\(dayPrefix)-\(slug)-\(sessionID.uuidString.prefix(8))"
        let jsonName = baseName + ".transcript.json"
        let mdName = baseName + ".transcript.md"

        let doc = ArchivedTranscriptDocument(
            sessionID: sessionID,
            title: title,
            startedAt: startedAt,
            endedAt: endedAt,
            events: events
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(doc)
        try coordinateWrite(jsonData, to: folder.appendingPathComponent(jsonName))

        let markdown = renderMarkdown(title: title, startedAt: startedAt, events: events)
        try coordinateWrite(Data(markdown.utf8), to: folder.appendingPathComponent(mdName))

        let relative = monthFolder + "/" + jsonName
        index[sessionID] = relative
        let rawIndex = Dictionary(uniqueKeysWithValues: index.map { ($0.key.uuidString, $0.value) })
        if let indexData = try? encoder.encode(rawIndex) {
            try? coordinateWrite(indexData, to: root.appendingPathComponent("index.json"))
        }
    }

    private static func decodeDocument(at url: URL) throws -> ArchivedTranscriptDocument {
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        var readError: NSError?
        var payload: Data?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: [], error: &readError) { coordinatedURL in
            payload = try? Data(contentsOf: coordinatedURL)
        }
        if let readError { throw readError }
        let data = try payload ?? Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ArchivedTranscriptDocument.self, from: data)
    }

    private static func coordinateWrite(_ data: Data, to url: URL) throws {
        var coordError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { targetURL in
            do {
                try data.write(to: targetURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
    }

    private static func scanDocuments(in root: URL) throws -> [ArchivedTranscriptDocument] {
        var result: [ArchivedTranscriptDocument] = []
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".transcript.json") {
            if let doc = try? decodeDocument(at: url) {
                result.append(doc)
            }
        }
        return result.sorted { $0.startedAt > $1.startedAt }
    }

    private static func measureDirectory(_ root: URL) -> (Int, Int64) {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            return (0, 0)
        }
        var count = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            if url.lastPathComponent.hasSuffix(".transcript.json") {
                count += 1
            }
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                bytes += Int64(size)
            }
        }
        return (count, bytes)
    }

    private static func renderMarkdown(
        title: String,
        startedAt: Date,
        events: [SyncedTranscriptEvent]
    ) -> String {
        let clock = ISO8601DateFormatter()
        var lines = ["# " + title, ""]
        if startedAt != .distantPast {
            lines.append("Started: \(clock.string(from: startedAt))")
            lines.append("")
        }
        for event in events where !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let stamp = clock.string(from: event.occurredAt)
            let speaker = (event.speaker?.isEmpty == false ? event.speaker! : (event.isOwn ? "You" : "Participant"))
            let tag = event.kind == "chat" ? " [chat]" : ""
            lines.append("- **\(speaker)**\(tag) (\(stamp)): \(event.text)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func sanitizeSlug(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(cleaned)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if collapsed.isEmpty { return "meeting" }
        return String(collapsed.prefix(40))
    }
}
