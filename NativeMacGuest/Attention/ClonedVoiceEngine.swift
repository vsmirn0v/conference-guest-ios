import Combine
import Darwin
import Foundation

enum ClonedVoiceEnginePhase: Equatable, Sendable {
    case unloaded, loading, loaded, unloading, failed
}

struct ClonedVoiceRuntimeSnapshot: Equatable, Sendable {
    var folder: URL?
    var phase: ClonedVoiceEnginePhase = .unloaded
    var generation = 0
    var activeSpeeches = 0
    var queuedSpeeches = 0
    var idleDeadline: Date?
    var error: String?
}

struct ClonedVoiceWorkerOutput: Sendable {
    var samples: [Float]?
    var memoryBytes: UInt64?
    var message: String?
    var repairedAsset: String?
}

protocol ClonedVoiceWorkerConnection: Sendable {
    func execute(_ request: ClonedVoiceWire.Request, timeout: TimeInterval) async throws -> ClonedVoiceWorkerOutput
    func stop() async
}

/// Owns one child, one operation, and its idle timer. Identical callers share the
/// operation. A competing request receives backpressure without queuing stale replies.
actor ClonedVoiceEngine {
    static let shared = ClonedVoiceEngine()
    static let idleNanoseconds: UInt64 = 10 * 60 * 1_000_000_000

    nonisolated let runtime = CurrentValueSubject<ClonedVoiceRuntimeSnapshot, Never>(.init())
    private let idleNanoseconds: UInt64
    private let connect: @Sendable () throws -> any ClonedVoiceWorkerConnection
    private var worker: (any ClonedVoiceWorkerConnection)?
    private var operation: (request: ClonedVoiceWire.Request, task: Task<ClonedVoiceWorkerOutput, Error>)?
    private var idle: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var runtimeState = ClonedVoiceRuntimeSnapshot()

    init(idleNanoseconds: UInt64 = ClonedVoiceEngine.idleNanoseconds,
         connect: @escaping @Sendable () throws -> any ClonedVoiceWorkerConnection = { try ClonedVoiceWorkerProcess() }) {
        self.idleNanoseconds = idleNanoseconds
        self.connect = connect
    }

    var runtimeSnapshot: ClonedVoiceRuntimeSnapshot { runtimeState }

    @discardableResult func prepare(_ folder: URL, repairAsset: String? = nil) async throws -> String? {
        if repairAsset != nil {
            // Never evict a cache entry while this process is using its model.
            guard operation == nil, stopping == nil else { throw ClonedVoiceWorkerError.busy }
            if worker != nil { await unload() }
        }
        return try await execute(.init(operation: .prepare, folder: folder.standardizedFileURL, repairAsset: repairAsset)).repairedAsset
    }

    func speak(_ text: String, voice: VoxVoice, folder: URL) async throws -> [Float] {
        let result = try await execute(.init(operation: .speak, folder: folder.standardizedFileURL, text: text, voice: voice))
        guard let samples = result.samples else { throw ClonedVoiceWorkerError.protocolFailure }
        return samples
    }

    func unload() async {
        if let stopping { await stopping.value; return }
        idle?.cancel()
        idle = nil
        let generation = runtimeState.generation + 1
        runtimeState = .init(folder: runtimeState.folder, phase: .unloading, generation: generation)
        publish()
        operation = nil
        let child = worker
        worker = nil
        let completion = Task { [weak self] in
            await child?.stop()
            await self?.unloaded(generation: generation)
        }
        stopping = completion
        await completion.value
    }

    private func unloaded(generation: Int) {
        runtimeState = .init(generation: generation)
        stopping = nil
        LocalModelMemoryTracker.shared.clear(.voice)
        publish()
    }

    private func execute(_ request: ClonedVoiceWire.Request) async throws -> ClonedVoiceWorkerOutput {
        try Task.checkCancellation()
        guard stopping == nil else { throw ClonedVoiceWorkerError.busy }
        if let operation {
            guard operation.request == request else { throw ClonedVoiceWorkerError.busy }
            return try await operation.task.value
        }
        if worker != nil, runtimeState.folder != request.folder {
            await unload()
            return try await execute(request)
        }

        idle?.cancel()
        idle = nil
        runtimeState.idleDeadline = nil
        let isCold = worker == nil
        let generation = runtimeState.generation
        runtimeState.folder = request.folder
        runtimeState.error = nil
        runtimeState.phase = isCold ? .loading : .loaded
        runtimeState.activeSpeeches = request.operation == .speak ? 1 : 0
        publish()

        let task = Task {
            guard runtimeState.generation == generation, stopping == nil else { throw ClonedVoiceWorkerError.stopped }
            do {
                if worker == nil { worker = try connect() }
                guard let worker else { throw ClonedVoiceWorkerError.unavailable }
                let timeout: TimeInterval = request.operation == .prepare ? 65 * 60 : (isCold ? 10 * 60 : 3 * 60)
                let output = try await worker.execute(request, timeout: timeout)
                guard runtimeState.generation == generation else { throw ClonedVoiceWorkerError.stopped }
                operation = nil
                runtimeState.phase = .loaded
                runtimeState.activeSpeeches = 0
                if let bytes = output.memoryBytes { LocalModelMemoryTracker.shared.recordVoiceWorker(bytes: bytes) }
                scheduleIdleUnload(generation: generation)
                return output
            } catch {
                guard runtimeState.generation == generation else { throw ClonedVoiceWorkerError.stopped }
                if case ClonedVoiceWorkerError.context = error {
                    operation = nil
                    runtimeState.activeSpeeches = 0
                    runtimeState.phase = .loaded
                    scheduleIdleUnload(generation: generation)
                } else {
                    await worker?.stop()
                    guard runtimeState.generation == generation else { throw ClonedVoiceWorkerError.stopped }
                    worker = nil
                    operation = nil
                    runtimeState.activeSpeeches = 0
                    runtimeState.phase = .failed
                    runtimeState.error = error.localizedDescription
                    LocalModelMemoryTracker.shared.clear(.voice)
                    publish()
                }
                throw error
            }
        }
        operation = (request, task)
        return try await task.value
    }

    private func scheduleIdleUnload(generation: Int) {
        runtimeState.idleDeadline = Date().addingTimeInterval(Double(idleNanoseconds) / 1_000_000_000)
        publish()
        idle = Task { [weak self, idleNanoseconds] in
            do { try await Task.sleep(nanoseconds: idleNanoseconds) } catch { return }
            await self?.unloadIfIdle(generation: generation)
        }
    }

    private func unloadIfIdle(generation: Int) async {
        guard !Task.isCancelled, generation == runtimeState.generation, operation == nil, stopping == nil else { return }
        await unload()
    }

    private func publish() { runtime.send(runtimeState) }
}

/// Blocking pipe reads and child reaping use a utility queue. The watchdog has an
/// independent queue and can kill a child stalled inside a noncooperative framework.
final class ClonedVoiceWorkerProcess: ClonedVoiceWorkerConnection, @unchecked Sendable {
    static let name = "RockClonedVoiceWorker"
    private let process = Process()
    private let input: FileHandle
    private let output: FileHandle
    private let io = DispatchQueue(label: "attention.voice-worker.io", qos: .utility)
    private let state = NSLock()
    private var current: UUID?
    private var interruption: ClonedVoiceWorkerError?

    init(executable: URL? = Bundle.main.url(forAuxiliaryExecutable: name)) throws {
        guard let executable else { throw ClonedVoiceWorkerError.unavailable }
        let toChild = Pipe(), fromChild = Pipe()
        input = toChild.fileHandleForWriting
        output = fromChild.fileHandleForReading
        guard fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) >= 0 else { throw ClonedVoiceWorkerError.unavailable }
        process.executableURL = executable
        process.standardInput = toChild
        process.standardOutput = fromChild
        process.standardError = FileHandle.standardError
        do { try process.run() }
        catch { throw ClonedVoiceWorkerError.unavailable }
        probeLog("voice-worker-started", ["pid": process.processIdentifier])
    }

    deinit { interrupt(.stopped) }

    var pid: Int32 { process.processIdentifier }

    func execute(_ request: ClonedVoiceWire.Request, timeout: TimeInterval) async throws -> ClonedVoiceWorkerOutput {
        try await withCheckedThrowingContinuation { continuation in
            io.async {
                let id = UUID()
                self.state.lock()
                let previous = self.interruption
                self.current = id
                self.state.unlock()
                if let previous { continuation.resume(throwing: previous); return }
                let watchdog = DispatchWorkItem { [weak self] in self?.interrupt(.timeout, operation: id) }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
                let result = Result { try self.exchange(request) }
                self.state.lock()
                self.current = nil
                let interruption = self.interruption
                self.state.unlock()
                watchdog.cancel()
                if let interruption { continuation.resume(throwing: interruption) }
                else { continuation.resume(with: result) }
            }
        }
    }

    func stop() async {
        interrupt(.stopped)
        await withCheckedContinuation { continuation in
            io.async {
                self.process.waitUntilExit()
                try? self.input.close()
                try? self.output.close()
                continuation.resume()
            }
        }
    }

    private func interrupt(_ error: ClonedVoiceWorkerError, operation: UUID? = nil) {
        state.lock()
        defer { state.unlock() }
        guard interruption == nil, operation == nil || current == operation else { return }
        interruption = error
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func exchange(_ request: ClonedVoiceWire.Request) throws -> ClonedVoiceWorkerOutput {
        let wire = ClonedVoiceWire.self
        do {
            try wire.write(JSONEncoder().encode(request), to: input, limit: wire.controlLimit)
            let response = try readResponse(request: request.operation)

            switch response.failure {
            case .busy: throw ClonedVoiceWorkerError.busy
            case .context: throw ClonedVoiceWorkerError.context(response.message ?? "")
            case .runtime:
                if let failure = response.failureInfo {
                    probeLog("voice-worker-failure", failure.diagnosticFields.merging(["operation": request.operation.rawValue]) { current, _ in current })
                    throw ClonedVoiceWorkerError.diagnosed(failure, repairedAsset: response.repairedAsset)
                }
                throw ClonedVoiceWorkerError.runtime(response.message ?? "", repairAsset: response.repairAsset)
            case nil: break
            }
            guard response.pcm == (request.operation == .speak) else { throw ClonedVoiceWorkerError.protocolFailure }
            let samples: [Float]?
            if response.pcm {
                guard let data = try wire.read(from: output, limit: wire.pcmLimit), data.count.isMultiple(of: 4) else {
                    throw ClonedVoiceWorkerError.protocolFailure
                }
                samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            } else {
                samples = nil
            }
            return .init(samples: samples, memoryBytes: response.memoryBytes, message: response.message,
                         repairedAsset: response.repairedAsset)
        } catch let error as ClonedVoiceWorkerError {
            throw error
        } catch {
            throw ClonedVoiceWorkerError.protocolFailure
        }
    }

    private func readResponse(request: ClonedVoiceWire.Request.Operation) throws -> ClonedVoiceWire.Response {
        let wire = ClonedVoiceWire.self
        for _ in 0..<4 {
            guard let control = try wire.read(from: output, limit: wire.controlLimit) else {
                throw ClonedVoiceWorkerError.stopped
            }
            let response = try JSONDecoder().decode(wire.Response.self, from: control)
            guard let stage = response.stage else { return response }
            probeLog("voice-worker-stage", ["operation": request.rawValue, "stage": stage.rawValue, "pid": pid])
        }
        throw ClonedVoiceWorkerError.protocolFailure
    }

}
