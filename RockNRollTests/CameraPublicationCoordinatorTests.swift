import XCTest
@testable import RockNRoll

@MainActor
final class CameraPublicationCoordinatorTests: XCTestCase {
    @MainActor private final class Signal {
        private var signalled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if signalled { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func send() {
            signalled = true
            let current = waiters; waiters.removeAll()
            current.forEach { $0.resume() }
        }
    }

    @MainActor private final class Publisher {
        let coordinator = CameraPublicationCoordinator<Int>()
        let created = Signal(), release = Signal(), cancelled = Signal()
        var validated: Signal?
        var intent = true
        var publication: Int?
        var creations = 0
        var updates: [Bool] = []

        func set(_ enabled: Bool) async throws -> Int? {
            try await coordinator.set(enabled: enabled, isCurrent: {
                self.validated?.send(); self.validated = nil
                return self.intent == enabled
            }, hasPublication: { self.publication != nil }, update: { enabled in
                self.updates.append(enabled)
                if !enabled { self.publication = nil }
                return self.publication
            }, create: {
                self.creations += 1
                let result = self.creations
                // Real negotiation can expose the publication before its task
                // finishes. Cancelling that task must remove this old object.
                self.publication = result
                if result == 1 {
                    self.created.send()
                    do {
                        try await withTaskCancellationHandler {
                            await self.release.wait()
                            try Task.checkCancellation()
                        } onCancel: {
                            Task { @MainActor in self.cancelled.send() }
                        }
                    } catch {
                        self.publication = nil
                        throw error
                    }
                }
                return result
            })
        }
    }

    func testOffThenOnDrainsCancelledPublicationBeforeReusingVisibleTrack() async throws {
        let publisher = Publisher()
        let first = Task { try await publisher.set(true) }
        await publisher.created.wait()
        publisher.intent = false
        let off = Task { try await publisher.set(false) }
        await publisher.cancelled.wait()
        publisher.intent = true
        let onValidated = Signal(); publisher.validated = onValidated
        let on = Task { try await publisher.set(true) }
        await onValidated.wait()
        XCTAssertEqual(publisher.publication, 1)
        XCTAssertTrue(publisher.updates.isEmpty)
        publisher.release.send()
        do { _ = try await first.value; XCTFail("Cancelled creation must not succeed") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        do { _ = try await off.value; XCTFail("Stale OFF must not update the sender") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let current = try await on.value
        XCTAssertEqual(current, 2)
        XCTAssertEqual(publisher.creations, 2)
        XCTAssertEqual(publisher.publication, 2)
        XCTAssertTrue(publisher.updates.isEmpty)
        publisher.intent = false
        _ = try await publisher.set(false)
        XCTAssertEqual(publisher.updates, [false])
        XCTAssertNil(publisher.publication)
    }

    func testConcurrentOnWaitsForOneInitialPublication() async throws {
        let publisher = Publisher()
        let first = Task { try await publisher.set(true) }
        await publisher.created.wait()
        let secondValidated = Signal(); publisher.validated = secondValidated
        let second = Task { try await publisher.set(true) }
        await secondValidated.wait()
        XCTAssertTrue(publisher.updates.isEmpty)
        publisher.release.send()
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a, 1); XCTAssertEqual(b, 1)
        XCTAssertEqual(publisher.creations, 1)
        XCTAssertEqual(publisher.updates, [true])
    }

    func testRealPublicationFailureIsNotRetried() async {
        enum Failure: Error { case negotiation }
        let coordinator = CameraPublicationCoordinator<Int>()
        var attempts = 0
        do {
            _ = try await coordinator.set(enabled: true, isCurrent: { true }, hasPublication: { false },
                update: { _ in XCTFail("No existing publication"); return nil },
                create: { attempts += 1; throw Failure.negotiation })
            XCTFail("Expected negotiation error")
        } catch Failure.negotiation {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(attempts, 1)
    }
}
