import AppKit
import Foundation

/// Security-scoped vault access. Bookmarks are created from an NSOpenPanel choice and
/// resolved on demand; a stale or revoked bookmark is a visible state, never a crash.
enum ObsidianVaultAccess {
    /// Asks the user for a vault folder and returns a fresh bookmark.
    static func chooseVaultBookmark() -> (url: URL, bookmark: Data)? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("Choose Vault")
        panel.message = L("Choose the Obsidian vault. Rock’N’Roll writes Markdown files inside it and never touches its .obsidian settings.")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: [.fileResourceIdentifierKey], relativeTo: nil)
            return (url, bookmark)
        } catch {
            return nil
        }
    }

    static func bookmarkedURL(_ bookmark: Data) -> URL? {
        var stale = false
        return try? resolveURL(bookmark, stale: &stale)
    }

    static func identifiesSameVault(_ bookmark: Data, selected: URL) -> Bool {
        var stale = false
        guard let old = try? resolveURL(bookmark, stale: &stale),
              old.standardizedFileURL == selected.standardizedFileURL,
              let oldIdentity = URL.resourceValues(forKeys: [.fileResourceIdentifierKey], fromBookmarkData: bookmark)?.fileResourceIdentifier as? NSObject,
              let selectedIdentity = try? selected.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        else { return false }
        return oldIdentity.isEqual(selectedIdentity)
    }

    private static func resolveURL(_ bookmark: Data, stale: inout Bool) throws -> URL {
        do {
            return try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                           relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            // Pre-migration vaults may have an implicit scope.
            return try URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                           relativeTo: nil, bookmarkDataIsStale: &stale)
        }
    }

    enum Resolution {
        case granted(URL)
        case stale
        case missing
        case denied(String)
    }

    static func resolve(_ bookmark: Data) -> Resolution {
        var stale = false
        do {
            let url = try resolveURL(bookmark, stale: &stale)
            if stale { return .stale }
            guard url.startAccessingSecurityScopedResource() else {
                return .denied(L("macOS denied access to the vault."))
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                url.stopAccessingSecurityScopedResource()
                return .missing
            }
            return .granted(url)
        } catch {
            return .missing
        }
    }

    /// Validates a vault-relative path: rejects absolute inputs, "..", normalized
    /// escapes and anything that resolves outside the vault. `.obsidian` is never a
    /// valid target directory. Symlinks that escape the vault are rejected.
    static func validate(relativePath: String, in vault: URL) -> Result<URL, ObsidianExportError> {
        guard !relativePath.isEmpty else { return .failure(.pathEscapesVault(relativePath)) }
        let ns = relativePath as NSString
        if ns.isAbsolutePath || relativePath.split(separator: "/").contains("..") {
            return .failure(.pathEscapesVault(relativePath))
        }
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.contains(where: { $0.caseInsensitiveCompare(".obsidian") == .orderedSame }) else {
            return .failure(.pathEscapesVault(".obsidian is never written"))
        }
        let target = vault.appendingPathComponent(relativePath)
        let vaultStandard = vault.standardizedFileURL.path
        let targetStandard = target.standardizedFileURL.path
        guard targetStandard.hasPrefix(vaultStandard + "/") else {
            return .failure(.pathEscapesVault(relativePath))
        }
        // Do not follow an indirect path when deciding which vault file to own.
        var probe = vault
        for component in components.dropLast() {
            probe = probe.appendingPathComponent(component)
            let attributes = try? FileManager.default.attributesOfItem(atPath: probe.path)
            if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
                return .failure(.pathEscapesVault(relativePath))
            }
        }
        return .success(target)
    }

    /// Ensures the target is a regular file (or creatable path): no directories,
    /// symlinks or hardlinked surprises as the final component.
    static func validateFileTarget(_ url: URL) -> Result<URL, ObsidianExportError> {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            return .failure(.notARegularFile(url.lastPathComponent))
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists {
            guard !isDirectory.boolValue else { return .failure(.notARegularFile(url.lastPathComponent)) }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
                return .failure(.notARegularFile(url.lastPathComponent))
            }
        }
        return .success(url)
    }
}
