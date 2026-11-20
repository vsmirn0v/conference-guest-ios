import Foundation
import os
import XCTest
@testable import RockNativeDesktop

@MainActor
final class MacWorkspaceReplicaWriterTests: XCTestCase {
    func testOrdinaryWritesCoalesceAroundRequiredCheckpoints() async throws {
        let writes = OSAllocatedUnfairLock(initialState: [Int]())
        let started = expectation(description: "First write started")
        let release = DispatchSemaphore(value: 0)
        let writer = MacWorkspaceReplicaWriter<Int>(persisted: nil) { value in
            if value == 1 {
                started.fulfill()
                guard release.wait(timeout: .now() + 10) == .success else { throw CocoaError(.userCancelled) }
            }
            writes.withLock { $0.append(value) }
        }
        writer.schedule(1)
        await fulfillment(of: [started], timeout: 5)
        writer.schedule(2)
        writer.schedule(3)
        // This task runs after the main actor enqueues the checkpoint and suspends.
        let updates = Task { @MainActor in
            writer.schedule(5)
            writer.schedule(6)
            release.signal()
        }
        try await writer.checkpoint(4)
        await updates.value
        try await writer.checkpoint(6)

        XCTAssertEqual(writes.withLock { $0 }, [1, 4, 6])
    }

    func testUnchangedStateSkipsDiskAndFailedStateCanBeRetried() async throws {
        let attempts = OSAllocatedUnfairLock(initialState: [Int]())
        let writer = MacWorkspaceReplicaWriter<Int>(persisted: 0) { value in
            let firstAttempt = attempts.withLock {
                $0.append(value)
                return $0.count == 1
            }
            if firstAttempt { throw CocoaError(.fileWriteNoPermission) }
        }

        try await writer.checkpoint(0)
        do {
            try await writer.checkpoint(1)
            XCTFail("The caller must see a failed checkpoint")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileWriteNoPermission)
        }
        try await writer.checkpoint(1)
        try await writer.checkpoint(1)

        XCTAssertEqual(attempts.withLock { $0 }, [1, 1])
    }
}
