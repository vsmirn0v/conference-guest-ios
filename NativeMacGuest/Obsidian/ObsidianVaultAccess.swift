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
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            return (url, bookmark)
        } catch {
            return nil
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
            let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale { return .stale }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .missing
            }
            guard url.startAccessingSecurityScopedResource() else {
                return .denied(L("macOS denied access to the vault."))
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
        guard !components.contains(".obsidian") else {
            return .failure(.pathEscapesVault(".obsidian is never written"))
        }
        let target = vault.appendingPathComponent(relativePath)
        let vaultStandard = vault.standardizedFileURL.path
        let targetStandard = target.standardizedFileURL.path
        guard targetStandard.hasPrefix(vaultStandard + "/") else {
            return .failure(.pathEscapesVault(relativePath))
        }
        // Existing symlinks must not escape the vault.
        var probe = vault
        for component in components.dropLast() {
            probe = probe.appendingPathComponent(component)
            let attributes = try? FileManager.default.attributesOfItem(atPath: probe.path)
            if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
                let destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: probe.path)).map {
                    URL(fileURLWithPath: $0, relativeTo: probe).standardizedFileURL.path
                } ?? ""
                guard destination.hasPrefix(vaultStandard) else {
                    return .failure(.pathEscapesVault(relativePath))
                }
            }
        }
        return .success(target)
    }

    /// Ensures the target is a regular file (or creatable path): no directories,
    /// symlinks or hardlinked surprises as the final component.
    static func validateFileTarget(_ url: URL) -> Result<URL, ObsidianExportError> {
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
