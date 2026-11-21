import ConferenceCore
import Darwin
import Foundation

@main
struct ClonedVoiceWorkerMain {
    static func main() async {
        // This child is owned by the app. It must stop even during a Core AI call
        // if the parent crashes or is force-quit before it can close the pipe.
        let parent = getppid()
        guard parent > 1 else { return }
        let parentExit = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global())
        parentExit.setEventHandler { _exit(1) }
        parentExit.activate()
        guard getppid() == parent else { return }
        defer { parentExit.cancel() }

        signal(SIGPIPE, SIG_IGN)
        let protocolOutput = dup(STDOUT_FILENO)
        guard protocolOutput >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else { return }
        let output = PipeWriter(handle: FileHandle(fileDescriptor: protocolOutput, closeOnDealloc: true))
        let input = FileHandle.standardInput
        let worker = ClonedVoiceWorkerRuntime()
        do {
            while let bytes = try ClonedVoiceWire.read(from: input, limit: ClonedVoiceWire.controlLimit) {
                let request = try JSONDecoder().decode(ClonedVoiceWire.Request.self, from: bytes)
                let priority: TaskPriority = (request.operation == .prepare || request.operation == .verify) ? .utility : .userInitiated
                let result = await Task.detached(priority: priority) {
                    await worker.perform(request) { update in
                        if let bytes = try? JSONEncoder().encode(ClonedVoiceWire.Response(stage: update.stage, progress: update)) {
                            try? output.write(bytes, limit: ClonedVoiceWire.controlLimit)
                        }
                    }
                }.value
                try output.write(JSONEncoder().encode(result.0), limit: ClonedVoiceWire.controlLimit)
                if let samples = result.1 {
                    let pcm = samples.withUnsafeBytes { Data($0) }
                    try output.write(pcm, limit: ClonedVoiceWire.pcmLimit)
                }
            }
        } catch {
            probeLog("voice-worker-ipc-failed", ["domain": (error as NSError).domain, "code": (error as NSError).code])
        }
    }
}

private final class PipeWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(handle: FileHandle) { self.handle = handle }

    func write(_ data: Data, limit: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        try ClonedVoiceWire.write(data, to: handle, limit: limit)
    }
}

private final class ClonedVoiceWorkerRuntime: @unchecked Sendable {
    private let baseline = ProcessMemoryProbe.footprint()
    private var folder: URL?
    private var lease: ClonedVoiceLease?
    private var model: AnyObject?
    private var repairedAssets: [String] = []
    private var pendingRepairAsset: String?

    private var primaryRepaired: String? { repairedAssets.first }
    private var reportedRepairedList: [String]? { repairedAssets.isEmpty ? nil : repairedAssets }

    func perform(_ request: ClonedVoiceWire.Request,
                 progress: @escaping @Sendable (ClonedVoiceWire.Response.Progress) -> Void) async -> (ClonedVoiceWire.Response, [Float]?) {
        repairedAssets = []
        pendingRepairAsset = nil
        do {
            if request.operation == .ping { return (.init(), nil) }
            #if canImport(CoreAI)
            if #available(macOS 27.0, *) {
                if request.operation == .cacheScope { return (.init(message: "worker-default"), nil) }
                if let folder = request.folder {
                    let samples = try await generate(request, folder: folder, progress: progress)
                    let memory = (samples != nil || model != nil) ? measuredMemory : nil
                    return (.init(repairedAssets: reportedRepairedList, repairedAsset: primaryRepaired,
                                  pcm: samples != nil, memoryBytes: memory), samples)
                }
            }
            #endif
            if request.operation == .cacheScope { return (.init(message: "Core AI unavailable on this OS"), nil) }
            throw VoxError.unsupported("Core AI is unavailable")
        } catch ClonedVoiceWorkerError.busy {
            return (.init(failure: .busy), nil)
        } catch VoxError.context(let message) where request.operation == .speak {
            return (.init(failure: .context, message: message), nil)
        } catch let failure as VoicePreparationStorageError {
            let diagnosis = ClonedVoiceFailure(kind: .preparationSpace, storage: failure.snapshot,
                technicalDetails: failure.localizedDescription,
                repairAsset: pendingRepairAsset, failedAt: Date())
            return (.init(failure: .runtime, message: failure.localizedDescription,
                          repairedAssets: reportedRepairedList,
                          failureInfo: diagnosis, repairedAsset: primaryRepaired), nil)
        } catch let failure as VoxVerificationFailure {
            let isStorage = VoiceStorage.isOutOfSpace(failure.cause)
            let primary = isStorage ? nil : failure.staleAssets.first
            let batch = (isStorage || failure.staleAssets.isEmpty) ? nil : failure.staleAssets
            let kind: ClonedVoiceFailure.Kind = isStorage ? .storage : .cache
            let detail = failure.cause as NSError
            let diagnosis = ClonedVoiceFailure(kind: kind, technicalDetails: failure.localizedDescription,
                                                repairAsset: primary, repairAssets: batch, failedAt: Date(),
                                                asset: failure.staleAssets.first, errorDomain: detail.domain, errorCode: detail.code)
            probeLog("voice-worker-failure-classified", ["kind": kind.rawValue, "repairAvailable": primary != nil])
            return (.init(failure: .runtime, message: failure.localizedDescription, repairAsset: primary,
                          repairedAssets: reportedRepairedList, failureInfo: diagnosis, repairedAsset: primaryRepaired), nil)
        } catch let failure as VoxAssetFailure {
            let asset = failure.missingSpecialization ? failure.asset : nil
            let kind: ClonedVoiceFailure.Kind = VoiceStorage.isOutOfSpace(failure.cause) ? .storage :
                (asset != nil ? .cache : (failure.duringSpecialization ? .compilation : .unknown))
            let detail = failure.cause as NSError
            let diagnosis = ClonedVoiceFailure(kind: kind, technicalDetails: failure.localizedDescription,
                                                repairAsset: asset, failedAt: Date(), asset: failure.asset,
                                                errorDomain: detail.domain, errorCode: detail.code)
            probeLog("voice-worker-failure-classified", ["kind": kind.rawValue, "repairAvailable": asset != nil])
            return (.init(failure: .runtime, message: failure.localizedDescription, repairAsset: asset,
                          repairedAssets: reportedRepairedList, failureInfo: diagnosis, repairedAsset: primaryRepaired), nil)
        } catch {
            let detail = error as NSError
            probeLog("voice-worker-operation-failed", ["domain": detail.domain, "code": detail.code])
            let message = error is VoxError ? error.localizedDescription : "The Neural Engine could not run the voice model (\(detail.domain) \(detail.code))."
            let kind: ClonedVoiceFailure.Kind = VoiceStorage.isOutOfSpace(error) ? .storage : .unknown
            return (.init(failure: .runtime, message: message,
                          repairedAssets: reportedRepairedList,
                          failureInfo: .init(kind: kind, technicalDetails: message, failedAt: Date()),
                          repairedAsset: primaryRepaired), nil)
        }
    }

    private var measuredMemory: UInt64? {
        guard let baseline, let footprint = ProcessMemoryProbe.footprint(), footprint > baseline else { return nil }
        return footprint - baseline
    }

    #if canImport(CoreAI)
    @available(macOS 27.0, *)
    private func generate(_ request: ClonedVoiceWire.Request, folder: URL,
                          progress: @escaping @Sendable (ClonedVoiceWire.Response.Progress) -> Void) async throws -> [Float]? {
        let folder = folder.standardizedFileURL
        guard self.folder == nil || self.folder == folder else { throw ClonedVoiceWorkerError.protocolFailure }
        if lease == nil { lease = try ClonedVoiceLease(folder: folder, purpose: "worker") }
        self.folder = folder
        if request.operation == .verify {
            progress(.init(stage: .validate))
            if let resident = model as? VoxCPM2 {
                try resident.verifyLoadedFunctions()
            } else {
                try VoxCoreAI.verify(bundle: folder)
            }
            return nil
        }
        let loaded: VoxCPM2
        if let resident = model as? VoxCPM2 {
            // An owner still using the model must never have its cache invalidated.
            guard request.repairAsset == nil, (request.repairAssets ?? []).isEmpty else { throw ClonedVoiceWorkerError.busy }
            loaded = resident
        } else {
            progress(.init(stage: .load))
            if request.operation == .prepare {
                var seen = Set<String>()
                let targets = (request.repairAssets ?? (request.repairAsset.map { [$0] } ?? [])).filter { seen.insert($0).inserted }
                for asset in targets {
                    pendingRepairAsset = asset
                    if try VoxCoreAI.repair(asset, in: folder) { repairedAssets.append(asset) }
                    pendingRepairAsset = nil
                }
                loaded = try await VoxCPM2(bundle: folder) { role, _, step, total in
                    progress(.init(stage: .load, asset: role, step: step, totalSteps: total))
                }
            } else {
                loaded = try await VoxCPM2(bundle: folder)
            }
            model = loaded
        }

        switch request.operation {
        case .ping, .cacheScope, .verify: return nil
        case .prepare:
            progress(.init(stage: .validate))
            try loaded.verifyLoadedFunctions()
            // A reference patch drives the encoder too, unlike a text-only probe.
            // This is synthetic conditioning data, independent of the user's enrollment.
            let reference = (0..<256).map { 0.25 * sin(Float($0) * 0.1) }
            let voice = VoxVoice(mode: .clone, transcript: "", reference: reference, continuation: nil, patches: 1)
            let pcm = try await loaded.generate("The voice is ready.", voice: voice, seed: 3,
                                               options: .init(minimumPatches: 2, maximumPatches: 16))
            guard loaded.sampleRate == 48_000 else { throw VoxError.audio("unexpected sample rate") }
            try ClonedVoiceWire.validatePCM(pcm)
            return nil
        case .speak:
            progress(.init(stage: .synthesize))
            guard let text = request.text else { throw ClonedVoiceWorkerError.protocolFailure }
            let pcm = try await loaded.generate(text, voice: request.voice, seed: UInt64.random(in: UInt64.min...UInt64.max))
            try ClonedVoiceWire.validatePCM(pcm)
            return pcm
        }
    }
    #endif
}
