import XCTest


final class ClonedVoiceBackendRouterTests: XCTestCase {
    private let voice = VoxVoice(mode: .clone, transcript: "", reference: [0.25, -0.5], continuation: nil, patches: 1)
    private let deadline = Date(timeIntervalSince1970: 10_000)

    func testGPUFinishesCurrentUtteranceAndNextUsesRecoveredANE() async throws {
        let ane = BackendFixture(), gpu = BackendFixture(blocked: true)
        let router = ClonedVoiceBackendRouter(neuralEngine: { try await ane.speak($0, $1) },
            gpu: { try await gpu.speak($0, $1) }, now: { Date(timeIntervalSince1970: 1) })
        await router.setReadiness(.preparing, for: .neuralEngine)
        await router.setReadiness(.ready, for: .gpu)
        let voice = self.voice, deadline = self.deadline
        let speech = Task { try await router.speak("first", voice: voice, expiresAt: deadline) }
        try await waitUntil { await gpu.count == 1 }
        await router.setReadiness(.ready, for: .neuralEngine)
        let active = await router.snapshot
        XCTAssertEqual(active.gpu, .synthesizing)
        XCTAssertEqual(active.neuralEngine, .ready)
        await gpu.release()
        let first = try await speech.value
        XCTAssertEqual(first.backend, .gpu)
        let second = try await router.speak("second", voice: voice, expiresAt: deadline)
        XCTAssertEqual(second.backend, .neuralEngine)
        let gpuVoices = await gpu.voices, aneVoices = await ane.voices
        XCTAssertEqual(gpuVoices, [voice]); XCTAssertEqual(aneVoices, [voice])
    }

    func testInvalidationDiscardsLateOutputAndKeepsWorkerBusy() async throws {
        let gpu = BackendFixture(blocked: true)
        let router = ClonedVoiceBackendRouter(neuralEngine: { _, _ in [1] },
            gpu: { try await gpu.speak($0, $1) }, now: { Date(timeIntervalSince1970: 1) })
        await router.setReadiness(.ready, for: .gpu)
        let voice = self.voice, deadline = self.deadline
        let pending = Task { try await router.speak("outdated", voice: voice, expiresAt: deadline) }
        try await waitUntil { await gpu.count == 1 }
        await router.invalidatePending()
        do { _ = try await router.speak("overlap", voice: voice, expiresAt: deadline); XCTFail("accepted overlapping work") }
        catch { XCTAssertEqual(error as? ClonedVoiceBackendRouter.Failure, .busy) }
        await gpu.release()
        do { _ = try await pending.value; XCTFail("returned invalidated audio") }
        catch { XCTAssertEqual(error as? ClonedVoiceBackendRouter.Failure, .invalidated) }
    }

    func testExpiryAndUnavailableBackendNeverStartAnUtterance() async throws {
        let ane = BackendFixture(), gpu = BackendFixture()
        let router = ClonedVoiceBackendRouter(neuralEngine: { try await ane.speak($0, $1) },
            gpu: { try await gpu.speak($0, $1) }, now: { Date(timeIntervalSince1970: 10) })
        await router.setReadiness(.preparing, for: .neuralEngine)
        do { _ = try await router.speak("unavailable", voice: voice, expiresAt: deadline); XCTFail("started unready backend") }
        catch { XCTAssertEqual(error as? ClonedVoiceBackendRouter.Failure, .unavailable) }
        await router.setReadiness(.ready, for: .gpu)
        do { _ = try await router.speak("expired", voice: voice, expiresAt: Date(timeIntervalSince1970: 10)); XCTFail("accepted stale speech") }
        catch { XCTAssertEqual(error as? ClonedVoiceBackendRouter.Failure, .expired) }
        let a = await ane.count, b = await gpu.count
        XCTAssertEqual(a, 0); XCTAssertEqual(b, 0)
    }

    func testBackendFailureIsNotReplayedOnAnotherBackend() async throws {
        let gpu = BackendFixture()
        let router = ClonedVoiceBackendRouter(neuralEngine: { _, _ in throw ClonedVoiceWorkerError.timeout },
            gpu: { try await gpu.speak($0, $1) }, now: { Date(timeIntervalSince1970: 1) })
        await router.setReadiness(.ready, for: .neuralEngine)
        await router.setReadiness(.ready, for: .gpu)
        do { _ = try await router.speak("once", voice: voice, expiresAt: deadline); XCTFail("expected failure") }
        catch { XCTAssertEqual(error as? ClonedVoiceWorkerError, .timeout) }
        let count = await gpu.count
        XCTAssertEqual(count, 0)
    }

    func testDeadlineIsRecheckedAfterNoncooperativeSynthesis() async throws {
        let gpu = BackendFixture(blocked: true), clock = BackendClock()
        let router = ClonedVoiceBackendRouter(neuralEngine: { _, _ in [1] },
            gpu: { try await gpu.speak($0, $1) }, now: { clock.read() })
        await router.setReadiness(.ready, for: .gpu)
        let voice = self.voice, deadline = self.deadline
        let pending = Task { try await router.speak("late", voice: voice, expiresAt: deadline) }
        try await waitUntil { await gpu.count == 1 }
        clock.set(deadline)
        await gpu.release()
        do { _ = try await pending.value; XCTFail("returned expired audio") }
        catch { XCTAssertEqual(error as? ClonedVoiceBackendRouter.Failure, .expired) }
    }

    func testRevokingActiveBackendDiscardsItsResult() async throws {
        let gpu = BackendFixture(blocked: true)
        let router = ClonedVoiceBackendRouter(neuralEngine: { _, _ in [1] },
            gpu: { try await gpu.speak($0, $1) }, now: { Date(timeIntervalSince1970: 1) })
        await router.setReadiness(.ready, for: .gpu)
        let voice = self.voice, deadline = self.deadline
        let pending = Task { try await router.speak("cancelled", voice: voice, expiresAt: deadline) }
        try await waitUntil { await gpu.count == 1 }
        await router.setReadiness(.unavailable, for: .gpu)
        await router.setReadiness(.ready, for: .gpu)
        await gpu.release()
        do { _ = try await pending.value; XCTFail("returned output from a revoked backend") }
        catch { XCTAssertEqual(error as? ClonedVoiceBackendRouter.Failure, .invalidated) }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ClonedVoiceWorkerError.timeout
    }
}

private final class BackendClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1)
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func set(_ value: Date) { lock.lock(); date = value; lock.unlock() }
}

private actor BackendFixture {
    private var blocked: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var voices: [VoxVoice] = []
    var count: Int { voices.count }
    init(blocked: Bool = false) { self.blocked = blocked }
    func speak(_ text: String, _ voice: VoxVoice) async throws -> [Float] {
        voices.append(voice)
        if blocked { await withCheckedContinuation { continuation = $0 } }
        return [Float(text.count)]
    }
    func release() { blocked = false; continuation?.resume(); continuation = nil }
}
