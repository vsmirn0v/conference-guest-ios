import XCTest
@testable import RockNativeDesktop

extension XCTestCase {
    /// Closes the store's meeting-library SQLite handle before this test's teardown
    /// blocks delete the store's directory. XCTest runs teardown blocks in reverse
    /// registration order, so registering this right after store creation
    /// deterministically wins the race that Swift's scheduled isolated deinits can
    /// lose against directory removal ("vnode unlinked while in use").
    func closeLibraryAtTeardown(_ store: AttentionStore) {
        addTeardownBlock { @MainActor in await store.closeLibrarySyncForTeardown() }
    }
}
