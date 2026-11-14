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
        let output = FileHandle(fileDescriptor: protocolOutput, closeOnDealloc: true)
        let input = FileHandle.standardInput
        let worker = ClonedVoiceWorkerRuntime()
        do {
            while let bytes = try ClonedVoiceWire.read(from: input, limit: ClonedVoiceWire.controlLimit) {
                let request = try JSONDecoder().decode(ClonedVoiceWire.Request.self, from: bytes)
                let result = await worker.perform(request) { stage in
                    if let bytes = try? JSONEncoder().encode(ClonedVoiceWire.Response(stage: stage)) {
                        try? ClonedVoiceWire.write(bytes, to: output, limit: ClonedVoiceWire.controlLimit)
                    }
                }
                try ClonedVoiceWire.write(JSONEncoder().encode(result.0), to: output, limit: ClonedVoiceWire.controlLimit)
                if let samples = result.1 {
                    let pcm = samples.withUnsafeBytes { Data($0) }
                    try ClonedVoiceWire.write(pcm, to: output, limit: ClonedVoiceWire.pcmLimit)
                }
            }
        } catch {
            probeLog("voice-worker-ipc-failed", ["domain": (error as NSError).domain, "code": (error as NSError).code])
        }
    }
}

private final class ClonedVoiceWorkerRuntime {
    private let baseline = ProcessMemoryProbe.footprint()
    private var folder: URL?
    private var lease: ClonedVoiceLease?
    private var model: AnyObject?
    private var repairedAsset: String?
    private var pendingRepairAsset: String?

    func perform(_ request: ClonedVoiceWire.Request,
                 progress: (ClonedVoiceWire.Response.Stage) -> Void) async -> (ClonedVoiceWire.Response, [Float]?) {
        repairedAsset = nil
        pendingRepairAsset = nil
        do {
            if request.operation == .ping { return (.init(), nil) }
            #if canImport(CoreAI)
            if #available(macOS 27.0, *) {
                if request.operation == .cacheScope { return (.init(message: "worker-default"), nil) }
                if let folder = request.folder {
                    let samples = try await generate(request, folder: folder, progress: progress)
                    return (.init(repairedAsset: repairedAsset, pcm: samples != nil, memoryBytes: measuredMemory), samples)
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
                          failureInfo: diagnosis, repairedAsset: repairedAsset), nil)
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
                          failureInfo: diagnosis, repairedAsset: repairedAsset), nil)
        } catch {
            let detail = error as NSError
            probeLog("voice-worker-operation-failed", ["domain": detail.domain, "code": detail.code])
            let message = error is VoxError ? error.localizedDescription : "The Neural Engine could not run the voice model (\(detail.domain) \(detail.code))."
            let kind: ClonedVoiceFailure.Kind = VoiceStorage.isOutOfSpace(error) ? .storage : .unknown
            return (.init(failure: .runtime, message: message,
                          failureInfo: .init(kind: kind, technicalDetails: message, failedAt: Date()),
                          repairedAsset: repairedAsset), nil)
        }
    }

    private var measuredMemory: UInt64? {
        guard let baseline, let footprint = ProcessMemoryProbe.footprint(), footprint > baseline else { return nil }
        return footprint - baseline
    }

    #if canImport(CoreAI)
    @available(macOS 27.0, *)
    private func generate(_ request: ClonedVoiceWire.Request, folder: URL,
                          progress: (ClonedVoiceWire.Response.Stage) -> Void) async throws -> [Float]? {
        let folder = folder.standardizedFileURL
        guard self.folder == nil || self.folder == folder else { throw ClonedVoiceWorkerError.protocolFailure }
        if lease == nil { lease = try ClonedVoiceLease(folder: folder, purpose: "worker") }
        self.folder = folder
        let loaded: VoxCPM2
        if let resident = model as? VoxCPM2 {
            // An owner still using the model must never have its cache invalidated.
            guard request.repairAsset == nil else { throw ClonedVoiceWorkerError.busy }
            loaded = resident
        } else {
            progress(.load)
            if request.operation == .prepare, let asset = request.repairAsset {
                pendingRepairAsset = asset
                if try VoxCoreAI.repair(asset, in: folder) { repairedAsset = asset }
                pendingRepairAsset = nil
            }
            loaded = try await VoxCPM2(bundle: folder)
            model = loaded
        }

        switch request.operation {
        case .ping, .cacheScope: return nil
        case .prepare:
            progress(.validate)
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
            progress(.synthesize)
            guard let text = request.text, let voice = request.voice else { throw ClonedVoiceWorkerError.protocolFailure }
            let pcm = try await loaded.generate(text, voice: voice, seed: UInt64.random(in: UInt64.min...UInt64.max))
            try ClonedVoiceWire.validatePCM(pcm)
            return pcm
        }
    }
    #endif
}
