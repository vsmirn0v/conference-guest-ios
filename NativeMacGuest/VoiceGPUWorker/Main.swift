import Darwin
import Foundation
import MLXAudioCore
import MLXAudioTTS

@main
struct ClonedVoiceGPUWorkerMain {
    static func main() async {
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
        let worker = GPUVoiceWorkerRuntime()
        do {
            while let bytes = try ClonedVoiceWire.read(from: .standardInput, limit: ClonedVoiceWire.controlLimit) {
                let request = try JSONDecoder().decode(ClonedVoiceWire.Request.self, from: bytes)
                let result = await worker.perform(request) { stage in
                    if let data = try? JSONEncoder().encode(ClonedVoiceWire.Response(stage: stage)) {
                        try? ClonedVoiceWire.write(data, to: output, limit: ClonedVoiceWire.controlLimit)
                    }
                }
                try ClonedVoiceWire.write(JSONEncoder().encode(result.0), to: output, limit: ClonedVoiceWire.controlLimit)
                if let samples = result.1 {
                    try ClonedVoiceWire.write(samples.withUnsafeBytes { Data($0) }, to: output, limit: ClonedVoiceWire.pcmLimit)
                }
            }
        } catch {
            probeLog("gpu-voice-worker-ipc-failed", ["domain": (error as NSError).domain, "code": (error as NSError).code])
        }
    }
}

private final class GPUVoiceWorkerRuntime {
    private let baseline = ProcessMemoryProbe.footprint()
    private var folder: URL?
    private var lease: ClonedVoiceLease?
    private var model: VoxCPM2Model?
    private var tokenizer: VoxTokenizer?

    func perform(_ request: ClonedVoiceWire.Request,
                 progress: (ClonedVoiceWire.Response.Stage) -> Void) async -> (ClonedVoiceWire.Response, [Float]?) {
        do {
            if request.operation == .ping { return (.init(), nil) }
            if request.operation == .cacheScope { return (.init(message: "gpu-worker"), nil) }
            guard let folder = request.folder, folder.isFileURL else { throw ClonedVoiceWorkerError.protocolFailure }
            let samples = try await generate(request, folder: folder, progress: progress)
            let memory: UInt64? = {
                guard let baseline, let footprint = ProcessMemoryProbe.footprint(), footprint > baseline else { return nil }
                return footprint - baseline
            }()
            return (.init(pcm: samples != nil, memoryBytes: memory), samples)
        } catch ClonedVoiceWorkerError.busy {
            return (.init(failure: .busy), nil)
        } catch VoxError.context(let message) {
            return (.init(failure: .context, message: message), nil)
        } catch {
            let detail = error as NSError
            probeLog("gpu-voice-worker-failed", ["domain": detail.domain, "code": detail.code])
            return (.init(failure: .runtime, message: "The GPU voice model could not run (\(detail.domain) \(detail.code))."), nil)
        }
    }

    private func generate(_ request: ClonedVoiceWire.Request, folder: URL,
                          progress: (ClonedVoiceWire.Response.Stage) -> Void) async throws -> [Float]? {
        let folder = folder.standardizedFileURL
        guard self.folder == nil || self.folder == folder else { throw ClonedVoiceWorkerError.protocolFailure }
        if lease == nil { lease = try ClonedVoiceLease(folder: folder, purpose: "worker") }
        self.folder = folder
        let loaded: VoxCPM2Model
        if let model { loaded = model }
        else {
            progress(.load)
            loaded = try await VoxCPM2Model.fromModelDirectory(folder, hfToken: nil)
            guard loaded.sampleRate == 48_000 else { throw VoxError.audio("unexpected sample rate") }
            tokenizer = try VoxTokenizer(url: folder.appendingPathComponent("tokenizer.json"))
            model = loaded
        }
        let text: String
        let voice: VoxVoice
        switch request.operation {
        case .prepare:
            progress(.validate)
            text = "The voice is ready."
            voice = VoxVoice(mode: .clone, transcript: "", reference: (0..<256).map { 0.25 * sin(Float($0) * 0.1) }, continuation: nil, patches: 1)
        case .speak:
            progress(.synthesize)
            guard let inputText = request.text, let inputVoice = request.voice else { throw ClonedVoiceWorkerError.protocolFailure }
            text = inputText
            voice = inputVoice
        case .ping, .cacheScope: return nil
        }
        guard voice.revision == VoxVoice.revision,
              (voice.mode == .clone && voice.reference != nil && voice.continuation == nil) ||
              (voice.mode == .continuation && voice.reference == nil && voice.continuation != nil) ||
              (voice.mode == .cloneContinuation && voice.reference != nil && voice.continuation != nil)
        else { throw VoxError.context("This saved voice is not compatible with the GPU voice model.") }
        guard let tokenizer else { throw ClonedVoiceWorkerError.protocolFailure }
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let tokenIDs = tokenizer.encode((voice.continuation != nil ? voice.transcript : "") + clean)
        let output = try await loaded.generateSavedVoice(text: text, transcript: voice.transcript, patches: voice.patches,
            reference: voice.reference, continuation: voice.continuation, tokenIDs: tokenIDs,
            generationParameters: GenerateParameters(maxTokens: request.operation == .prepare ? 64 : 256))
        let samples = output.asArray(Float.self)
        guard samples.count <= ClonedVoiceWire.pcmLimit / MemoryLayout<Float>.size else { throw ClonedVoiceWorkerError.protocolFailure }
        try ClonedVoiceWire.validatePCM(samples)
        return request.operation == .speak ? samples : nil
    }
}
