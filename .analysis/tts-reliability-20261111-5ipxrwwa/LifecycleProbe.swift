import Foundation
import Combine
struct VoxVoice: Sendable {}
enum VoiceSynthesisError: Error { case cloneUnsupported, cloneModelMissing }
enum Role { case voice }
final class LocalModelMemoryTracker: @unchecked Sendable {
 static let shared = LocalModelMemoryTracker()
 func begin(_ role: Role) -> UUID { UUID() }
 func clear(_ role: Role) {}
 func complete(_ role: Role, token: UUID, success: Bool) {}
 func refine(_ role: Role) {}
}
final class VoxCPM2 {
 init(bundle: URL) async throws {}
 func generate(_ text: String, voice: VoxVoice, seed: UInt64) async throws -> [Float] { [0.2, 0.4] }
}
enum ClonedVoiceEnginePhase: Equatable, Sendable {
    case unloaded, loading, loaded, unloading, failed
}

/// Runtime residency for the cloned voice model. Preparation state remains in
/// VoiceCloneStore; this snapshot describes what the engine currently holds.
struct ClonedVoiceRuntimeSnapshot: Equatable, Sendable {
    var folder: URL?
    var phase: ClonedVoiceEnginePhase = .unloaded
    var generation = 0
    var activeSpeeches = 0
    var queuedSpeeches = 0
    var idleDeadline: Date?
    var error: String?
}

/// Runs the voice model: one reply at a time, kept loaded for a while after the last one.
actor ClonedVoiceEngine {
    static let shared = ClonedVoiceEngine()
    static let idleNanoseconds: UInt64 = 10 * 60 * 1_000_000_000

    nonisolated let runtime = CurrentValueSubject<ClonedVoiceRuntimeSnapshot, Never>(.init())
    private var model: AnyObject?
    private var folder: URL?
    private var loading: (folder: URL, task: Task<AnyObject, Error>)?
    private var tail: Task<Void, Never>?
    private var idle: Task<Void, Never>?
    private var runtimeState = ClonedVoiceRuntimeSnapshot()

    func load(_ folder: URL) async throws { _ = try await loaded(folder) }

    func unload() {
        generation += 1
        idle?.cancel()
        idle = nil
        loading?.task.cancel()
        loading = nil
        model = nil
        self.folder = nil
        loading = nil
        runtimeState.queuedSpeeches = 0
        runtimeState.phase = .unloading
        publishRuntime()
        LocalModelMemoryTracker.shared.clear(.voice)
        runtimeState.folder = nil
        runtimeState.phase = .unloaded
        runtimeState.idleDeadline = nil
        runtimeState.error = nil
        publishRuntime()
    }

    /// 48 kHz mono samples of `text` in `voice`. Requests wait for the one before them.
    func speak(_ text: String, voice: VoxVoice, folder: URL) async throws -> [Float] {
        let previous = tail
        let startedGeneration = generation
        runtimeState.queuedSpeeches += 1
        publishRuntime()
        let work = Task { () async throws -> [Float] in
            await previous?.value
            return try await self.generate(text, voice: voice, folder: folder)
        }
        tail = Task { [weak self] in
            _ = try? await work.value
            await self?.speechQueuedFinished(generation: startedGeneration)
        }
        return try await work.value
    }

    var runtimeSnapshot: ClonedVoiceRuntimeSnapshot { runtimeState }

    private var generation = 0 {
        didSet { runtimeState.generation = generation }
    }

    private func speechQueuedFinished(generation: Int) {
        guard generation == self.generation else { return }
        runtimeState.queuedSpeeches = max(0, runtimeState.queuedSpeeches - 1)
        publishRuntime()
    }

    private func loaded(_ folder: URL) async throws -> AnyObject {
        if let model, self.folder == folder {
            runtimeState.folder = folder
            runtimeState.error = nil
            publishRuntime()
            return model
        }
        if let loading, loading.folder == folder { return try await loading.task.value }

        generation += 1
        let startedGeneration = generation
        let token = LocalModelMemoryTracker.shared.begin(.voice)
        runtimeState.folder = folder
        runtimeState.phase = .loading
        runtimeState.idleDeadline = nil
        runtimeState.error = nil
        publishRuntime()

        let task = Task.detached(priority: .utility) { () async throws -> AnyObject in
            #if canImport(CoreAI)
            if #available(macOS 27.0, *) { return try await VoxCPM2(bundle: folder) }
            #endif
            throw VoiceSynthesisError.cloneUnsupported
        }
        loading = (folder, task)
        defer { loading = nil }
        do {
            let value = try await task.value
            guard startedGeneration == generation else { throw VoiceSynthesisError.cloneModelMissing }
            model = value
            self.folder = folder
            runtimeState.phase = .loaded
            publishRuntime()
            LocalModelMemoryTracker.shared.complete(.voice, token: token, success: true)
            return value
        } catch {
            if startedGeneration == generation {
                runtimeState.phase = .failed
                runtimeState.error = String(describing: error)
                publishRuntime()
                LocalModelMemoryTracker.shared.complete(.voice, token: token, success: false)
            }
            throw error
        }
    }

    private func generate(_ text: String, voice: VoxVoice, folder: URL) async throws -> [Float] {
        idle?.cancel()
        idle = nil
        runtimeState.idleDeadline = nil
        let startedGeneration = generation
        runtimeState.activeSpeeches += 1
        publishRuntime()
        defer {
            runtimeState.activeSpeeches = max(0, runtimeState.activeSpeeches - 1)
            publishRuntime()
            if startedGeneration == generation { scheduleIdleUnload(folder: folder, generation: startedGeneration) }
        }
        let model = try await loaded(folder)
        guard startedGeneration == generation else { throw VoiceSynthesisError.cloneModelMissing }
        #if canImport(CoreAI)
        if #available(macOS 27.0, *), let model = model as? VoxCPM2 {
            let samples = try await model.generate(text, voice: voice, seed: UInt64.random(in: 0...UInt64.max))
            LocalModelMemoryTracker.shared.refine(.voice)
            return samples
        }
        #endif
        throw VoiceSynthesisError.cloneUnsupported
    }

    private func scheduleIdleUnload(folder: URL, generation: Int) {
        guard runtimeState.activeSpeeches == 0, runtimeState.phase == .loaded else { return }
        let deadline = Date().addingTimeInterval(TimeInterval(Self.idleNanoseconds) / 1_000_000_000)
        runtimeState.idleDeadline = deadline
        publishRuntime()
        idle = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleNanoseconds)
            guard !Task.isCancelled, let self else { return }
            await self.unloadIfStillIdle(folder: folder, generation: generation)
        }
    }

    /// On the actor: the idle deadline passed with no new speech on the same load.
    private func unloadIfStillIdle(folder: URL, generation: Int) {
        guard generation == self.generation, self.folder == folder,
              runtimeState.activeSpeeches == 0, runtimeState.phase == .loaded else { return }
        unload()
    }

    private func publishRuntime() { runtime.send(runtimeState) }
}

/// Reading, resampling and trimming voice recordings.

@main struct Probe {
 static func speak(_ engine: ClonedVoiceEngine, _ label: String) async {
   do { let audio = try await engine.speak("test", voice: VoxVoice(), folder: URL(fileURLWithPath: "/unused-test-model")); print("\(label): success, \(audio.count) samples") }
   catch { print("\(label): \(error)") }
   let state = await engine.runtimeSnapshot
   print("  engine=\(state.phase) generation=\(state.generation) idleTimer=\(state.idleDeadline != nil)")
 }
 static func main() async throws {
   print("Exact production actor; model and memory tracker replaced by deterministic stubs.")
   let engine = ClonedVoiceEngine()
   await speak(engine,"cold first request")
   await speak(engine,"second request")
   await engine.unload()
   await speak(engine,"first request after unload")
   let preloaded = ClonedVoiceEngine()
   try await preloaded.load(URL(fileURLWithPath: "/unused-test-model"))
   await speak(preloaded,"request after explicit preparation")
 }
}
