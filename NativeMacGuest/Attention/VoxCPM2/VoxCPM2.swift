import Accelerate
import Foundation
#if canImport(CoreAI)
import CoreAI
#endif

// VoxCPM2 (OpenBMB, Apache-2.0) speech generation, ported from tinkerbox-ane's Python runtime
// (voxcpm2/runtime.py and prompt.py, Apache-2.0). The MiniCPM base and residual language
// models, the patch encoder and the diffusion sampler run on the Neural Engine through Core AI;
// tokenization, embeddings, small projections, the scalar quantizer and the AudioVAE run on
// the CPU. Output is 48 kHz mono.

/// A cloned voice: AudioVAE latents of a reference recording, in 4-frame patches (P × 4 × 64).
struct VoxVoice: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable {
        /// Imitate the reference's timbre; the reference is not continued.
        case clone
        /// Continue the reference recording; needs its transcript.
        case continuation
        /// Both: the stable timbre of `clone` with the prosody of continuation (best in the bench).
        case cloneContinuation = "clone_continuation"
    }

    static let revision = "32279effe8c19989596f05d353d1447f51d9e915"
    var revision = VoxVoice.revision
    var mode: Mode
    var transcript: String
    /// Patches padded on the right (used as the isolated reference), and on the left (continued).
    var reference: [Float]?
    var continuation: [Float]?
    var patches: Int

    static let patchValues = 4 * 64
}

extension VoxAudioVAE {
    /// Encodes a reference recording (mono, 16 kHz) into a voice. Runs on the CPU only, so a voice
    /// can be recorded before the Neural Engine model is ready.
    func makeVoice(samples: [Float], rate: Int, transcript: String, mode: VoxVoice.Mode = .cloneContinuation,
                   maximumPositions: Int = 8192) throws -> VoxVoice {
        guard rate == sampleRate else { throw VoxError.audio("reference must be \(sampleRate) Hz") }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode == .clone || !text.isEmpty else { throw VoxError.context("This voice needs the reference transcript.") }
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else { throw VoxError.audio("empty reference") }
        let alignment = 4 * encodeHop
        let count = (samples.count + alignment - 1) / alignment
        guard count + 4 < maximumPositions else { throw VoxError.context("The reference recording is too long.") }
        let pad = count * alignment - samples.count
        func encodePatches(left: Bool) -> [Float] {
            let padded = left ? [Float](repeating: 0, count: pad) + samples : samples + [Float](repeating: 0, count: pad)
            let latent = encode(padded)
            var patches = [Float](repeating: 0, count: count * VoxVoice.patchValues)
            for patch in 0..<count {
                for frame in 0..<4 {
                    for channel in 0..<64 {
                        patches[(patch * 4 + frame) * 64 + channel] = latent.values[channel * latent.frames + patch * 4 + frame]
                    }
                }
            }
            return patches
        }
        return VoxVoice(mode: mode, transcript: text,
                        reference: mode != .continuation ? encodePatches(left: false) : nil,
                        continuation: mode != .clone ? encodePatches(left: true) : nil,
                        patches: count)
    }
}

/// Deterministic standard normals for the diffusion noise (SplitMix64 + Box–Muller).
struct VoxRandom {
    private var state: UInt64
    private var spare: Float?

    init(seed: UInt64) { state = seed }

    private mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func normal() -> Float {
        if let spare { self.spare = nil; return spare }
        let u1 = max(Double(next() >> 11) / Double(1 << 53), Double.leastNonzeroMagnitude)
        let u2 = Double(next() >> 11) / Double(1 << 53)
        let radius = (-2 * log(u1)).squareRoot()
        spare = Float(radius * sin(2 * .pi * u2))
        return Float(radius * cos(2 * .pi * u2))
    }
}

/// Round to float16 and back, to follow the reference runtime's half-precision arithmetic.
@inline(__always) func voxHalf(_ value: Float) -> Float { Float(Float16(value)) }

/// y (rows × output) = x (rows × input) · Wᵀ + b, with float16 checkpoint weights widened once.
struct VoxLinear {
    let input: Int
    let output: Int
    private let weight: [Float]
    private let bias: [Float]?

    init(_ file: VoxSafeTensors, _ name: String, input: Int, output: Int, bias: Bool = true) throws {
        self.input = input
        self.output = output
        weight = try file.widened(name + ".weight", shape: [output, input])
        self.bias = bias ? try file.widened(name + ".bias", shape: [output]) : nil
    }

    func callAsFunction(_ x: [Float], rows: Int) -> [Float] {
        precondition(x.count == rows * input)
        var y = [Float](repeating: 0, count: rows * output)
        if let bias { for row in 0..<rows { for index in 0..<output { y[row * output + index] = bias[index] } } }
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(output), Int32(input), 1,
                    x, Int32(input), weight, Int32(input), bias == nil ? 0 : 1, &y, Int32(output))
        return y
    }
}

/// Bundle manifest (model.json) and checkpoint configuration (checkpoint/config.json).
struct VoxManifest: Decodable {
    struct Function: Decodable { let name: String; let capacity: Int?; let width: Int?; let steps: Int? }
    struct StageConfig: Decodable { let hidden: Int; let heads: Int; let kv_heads: Int; let head_dim: Int; let layers: Int; let rope: Bool }
    struct Asset: Decodable {
        let role: String
        let asset: String
        let config: StageConfig
        let start: Int
        let end: Int
        let cached: Bool
        let cache_functions: [Function]?
        let local_functions: [String: Function]?
        let sampler_functions: [Function]?
    }
    struct Source: Decodable { let repo: String; let revision: String; let code_revision: String }
    let kind: String
    let version: Int
    let capacities: [Int]
    let prefill_width: Int
    let architecture: String
    let source: Source
    let assets: [Asset]
}

struct VoxCheckpointConfig: Decodable {
    struct LM: Decodable {
        struct Scaling: Decodable { let long_factor: [Double]; let short_factor: [Double]; let original_max_position_embeddings: Int }
        let hidden_size: Int
        let kv_channels: Int
        let rope_theta: Double
        let max_position_embeddings: Int
        let rope_scaling: Scaling
        let vocab_size: Int
    }
    struct DiT: Decodable { let hidden_dim: Int }
    let lm_config: LM
    let patch_size: Int
    let feat_dim: Int
    let scalar_quantization_latent_dim: Int
    let scalar_quantization_scale: Int
    let dit_config: DiT
    let audio_vae_config: VoxAudioVAE.Config
}

#if canImport(CoreAI)
@available(macOS 27.0, *)
final class VoxCPM2 {
    static let kind = "voxcpm2-minicpm"
    static let sourceRevision = VoxVoice.revision
    static let codeRevision = "cce58a5b59303c9bd63d12f23afe6a49a4a80c59"

    struct Options {
        var minimumPatches = 2
        var maximumPatches = 4096
        var guidance: Float = 2
    }

    struct Timing { var neuralEngine = 0.0; var total = 0.0; var patches = 0 }

    let manifest: VoxManifest
    let config: VoxCheckpointConfig
    let tokenizer: VoxTokenizer
    let codec: VoxAudioVAE
    var sampleRate: Int { codec.outputRate }
    var maximumPositions: Int { manifest.capacities.max() ?? 0 }
    private(set) var timing = Timing()

    private let weights: VoxSafeTensors
    private let embeddings: UnsafeRawPointer
    private let hidden: Int
    private let ditWidth: Int
    private let featureEncoderInput: VoxLinear, encoderToLM: VoxLinear, quantizerInput: VoxLinear, quantizerOutput: VoxLinear
    private let fusion: VoxLinear, lmToDiT: VoxLinear, residualToDiT: VoxLinear, stopProjection: VoxLinear, stopHead: VoxLinear
    private let conditionProjection: VoxLinear
    private let specialToken: [Float]
    private let cosine: [Float16], sine: [Float16]
    private let headDimension: Int
    private let stages: [String: VoxManifest.Asset]
    private let assets: [String: VoxAsset]
    private let base: VoxAsset.Cached
    private let residual: VoxAsset.Cached
    private var schedule: [(name: String, clocks: [Float16], dts: [Float16])] = []
    private var masks: [String: [String: [Float16]]] = [:]

    /// Loads a bundle folder holding model.json, the `.aimodelc` assets and `checkpoint/`.
    /// The first load on a Mac compiles the assets for its Neural Engine and can take many minutes.
    init(bundle: URL) async throws {
        manifest = try JSONDecoder().decode(VoxManifest.self, from: Data(contentsOf: bundle.appendingPathComponent("model.json")))
        guard manifest.kind == Self.kind, manifest.version == 2 else { throw VoxError.unsupported("bundle kind \(manifest.kind)") }
        guard manifest.source.revision == Self.sourceRevision, manifest.source.code_revision == Self.codeRevision else {
            throw VoxError.unsupported("bundle revision differs from this app")
        }
        guard manifest.architecture == VoxCoreAI.architecture else {
            throw VoxError.unsupported("bundle is for \(manifest.architecture), this Mac is \(VoxCoreAI.architecture)")
        }
        let checkpoint = bundle.appendingPathComponent("checkpoint", isDirectory: true)
        config = try JSONDecoder().decode(VoxCheckpointConfig.self, from: Data(contentsOf: checkpoint.appendingPathComponent("config.json")))
        guard config.patch_size == 4, config.feat_dim == 64 else { throw VoxError.unsupported("patch layout") }
        tokenizer = try VoxTokenizer(url: checkpoint.appendingPathComponent("tokenizer.json"))
        codec = try VoxAudioVAE(url: checkpoint.appendingPathComponent("audiovae.safetensors"), config: config.audio_vae_config)
        weights = try VoxSafeTensors(url: checkpoint.appendingPathComponent("model.safetensors"))

        let lm = config.lm_config
        hidden = lm.hidden_size
        ditWidth = config.dit_config.hidden_dim
        let encoderWidth = ditWidth, latent = config.scalar_quantization_latent_dim
        let table = try weights.entry("base_lm.embed_tokens.weight", dtype: "F16", shape: [lm.vocab_size, hidden])
        embeddings = weights.raw(table)
        featureEncoderInput = try VoxLinear(weights, "feat_encoder.in_proj", input: 64, output: encoderWidth)
        encoderToLM = try VoxLinear(weights, "enc_to_lm_proj", input: encoderWidth, output: hidden)
        quantizerInput = try VoxLinear(weights, "fsq_layer.in_proj", input: hidden, output: latent)
        quantizerOutput = try VoxLinear(weights, "fsq_layer.out_proj", input: latent, output: hidden)
        fusion = try VoxLinear(weights, "fusion_concat_proj", input: 2 * hidden, output: hidden)
        lmToDiT = try VoxLinear(weights, "lm_to_dit_proj", input: hidden, output: ditWidth)
        residualToDiT = try VoxLinear(weights, "res_to_dit_proj", input: hidden, output: ditWidth)
        stopProjection = try VoxLinear(weights, "stop_proj", input: hidden, output: hidden)
        stopHead = try VoxLinear(weights, "stop_head", input: hidden, output: 2, bias: false)
        conditionProjection = try VoxLinear(weights, "feat_decoder.estimator.cond_proj", input: 64, output: ditWidth)
        specialToken = try weights.widened("feat_encoder.special_token", shape: [1, 1, 1, encoderWidth])

        // Long-RoPE tables as the pinned source builds them (float32 math, stored as float16).
        let dimension = lm.kv_channels
        headDimension = dimension
        let scaling = lm.rope_scaling
        let factors = lm.max_position_embeddings > scaling.original_max_position_embeddings ? scaling.long_factor : scaling.short_factor
        guard factors.count == dimension / 2 else { throw VoxError.format("RoPE factors") }
        let inverse = (0..<(dimension / 2)).map { 1 / pow(Float(lm.rope_theta), Float(2 * $0) / Float(dimension)) }
        let multiplier = Float((1 + log(Double(lm.max_position_embeddings) / Double(scaling.original_max_position_embeddings))
            / log(Double(scaling.original_max_position_embeddings))).squareRoot())
        let positions = manifest.capacities.max() ?? 0
        var cosine = [Float16](repeating: 0, count: positions * dimension), sine = cosine
        for position in 0..<positions {
            for index in 0..<(dimension / 2) {
                let angle = Float(position) * (1 / Float(factors[index])) * inverse[index]
                let c = Float16(cos(angle) * multiplier), s = Float16(sin(angle) * multiplier)
                cosine[position * dimension + index] = c; cosine[position * dimension + index + dimension / 2] = c
                sine[position * dimension + index] = s; sine[position * dimension + index + dimension / 2] = s
            }
        }
        self.cosine = cosine
        self.sine = sine

        stages = Dictionary(uniqueKeysWithValues: manifest.assets.map { ($0.role, $0) })
        guard let baseStage = stages["base-0"], let residualStage = stages["residual"], stages["encoder"] != nil, stages["dit"] != nil,
              manifest.assets.filter({ $0.role.hasPrefix("base-") }).count == 1 else {
            throw VoxError.unsupported("bundle stages")
        }
        var assets: [String: VoxAsset] = [:]
        for stage in manifest.assets {
            assets[stage.role] = try await VoxAsset(url: bundle.appendingPathComponent(stage.asset))
        }
        self.assets = assets
        func cached(_ stage: VoxManifest.Asset) throws -> VoxAsset.Cached {
            guard stage.cached, let functions = stage.cache_functions else { throw VoxError.unsupported("\(stage.role) is not cached") }
            let channels = 2 * (stage.end - stage.start) * stage.config.kv_heads * stage.config.head_dim
            return VoxAsset.Cached(asset: assets[stage.role]!, hidden: stage.config.hidden, channels: channels,
                                   functions: try functions.map {
                                       guard let capacity = $0.capacity, let width = $0.width else { throw VoxError.format("cache function") }
                                       return .init(name: $0.name, capacity: capacity, width: width)
                                   })
        }
        base = try cached(baseStage)
        residual = try cached(residualStage)
        schedule = try makeSchedule(steps: 10)
    }

    // MARK: Voices

    /// Encodes a reference recording (mono, `rate` Hz) into a reusable voice.
    func makeVoice(samples: [Float], rate: Int, transcript: String, mode: VoxVoice.Mode = .cloneContinuation) throws -> VoxVoice {
        try codec.makeVoice(samples: samples, rate: rate, transcript: transcript, mode: mode, maximumPositions: maximumPositions)
    }

    // MARK: Generation

    /// Speaks `text` in `voice`; `audio` receives 48 kHz pieces in order as they are decoded.
    /// `noise`, for tests, supplies each patch's 64 × 4 starting noise instead of `seed`.
    @discardableResult
    func generate(_ text: String, voice: VoxVoice?, seed: UInt64, options: Options = Options(),
                  noise: ((Int) -> [Float])? = nil, audio: (([Float]) -> Void)? = nil) async throws -> [Float] {
        let started = ContinuousClock.now
        timing = Timing()
        let engineBefore = assets.values.reduce(0) { $0 + $1.seconds }
        defer {
            timing.total = (ContinuousClock.now - started).voxSeconds
            timing.neuralEngine = assets.values.reduce(0) { $0 + $1.seconds } - engineBefore
        }
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !clean.isEmpty else { throw VoxError.context("There is nothing to say.") }
        if let voice, voice.revision != VoxVoice.revision { throw VoxError.context("Record this voice again for the new model.") }
        let inputs = try buildInputs(clean, voice: voice)
        let count = inputs.ids.count
        let available = maximumPositions - count
        let budget = min(options.maximumPatches, available)
        guard budget > options.minimumPatches + 1 else { throw VoxError.context("The text is too long to speak in one reply.") }

        let embedded = try await encode(inputs.features, count: count)
        var combined = [Float](repeating: 0, count: count * hidden)
        for row in 0..<count {
            if inputs.audio[row] {
                for index in 0..<hidden { combined[row * hidden + index] = embedded[row * hidden + index] }
            } else {
                let id = inputs.ids[row]
                for index in 0..<hidden {
                    combined[row * hidden + index] = Float(embeddings.loadUnaligned(fromByteOffset: (id * hidden + index) * 2, as: Float16.self))
                }
            }
        }
        var baseOut = try await run(base, combined, rows: count, reset: true, rope: stages["base-0"]!.config.rope)
        let quantized = quantize(baseOut, rows: count)
        var fused = [Float](repeating: 0, count: count * 2 * hidden)
        for row in 0..<count {
            let audio = inputs.audio[row]
            for index in 0..<hidden {
                if audio { baseOut[row * hidden + index] = quantized[row * hidden + index] }
                fused[row * 2 * hidden + index] = baseOut[row * hidden + index]
                fused[row * 2 * hidden + hidden + index] = audio ? embedded[row * hidden + index] : 0
            }
        }
        let residualOut = try await run(residual, fusion(fused, rows: count), rows: count, reset: true,
                                        rope: stages["residual"]!.config.rope)
        var lastHidden = Array(baseOut[((count - 1) * hidden)..<(count * hidden)])
        var lastResidual = Array(residualOut[((count - 1) * hidden)..<(count * hidden)])
        var previous = Array(inputs.features[((count - 1) * VoxVoice.patchValues)..<(count * VoxVoice.patchValues)])

        // Decoder input: 25 Hz latent frames, decoded 16 at a time as generation goes.
        codec.resetDecoder()
        var pending: [[Float]] = []
        var skip = 0
        var output: [Float] = []
        func decode(final: Bool) throws {
            while pending.count >= 16 || (final && !pending.isEmpty) {
                let frames = min(16, pending.count)
                var latent = VoxSignal.zeros(64, frames)
                for frame in 0..<frames { for channel in 0..<64 { latent.values[channel * frames + frame] = pending[frame][channel] } }
                pending.removeFirst(frames)
                var piece = codec.decode(latent)
                guard piece.allSatisfy(\.isFinite) else { throw VoxError.audio("non-finite samples") }
                let dropped = min(skip, piece.count)
                skip -= dropped
                piece.removeFirst(dropped)
                if !piece.isEmpty { output += piece; audio?(piece) }
            }
        }
        func push(_ patch: [Float]) {
            for frame in 0..<4 { pending.append(Array(patch[(frame * 64)..<((frame + 1) * 64)])) }
        }
        if inputs.audio[count - 1] {
            // Continuation: decode the reference's last three patches for continuity, then drop them.
            let audioRows = (0..<count).filter { inputs.audio[$0] }.suffix(3)
            for row in audioRows { push(Array(inputs.features[(row * VoxVoice.patchValues)..<((row + 1) * VoxVoice.patchValues)])) }
            skip = audioRows.count * 4 * codec.decodeHop
        }

        var random = VoxRandom(seed: seed)
        for step in 0..<budget {
            try Task.checkCancellation()
            let mu = lmToDiT(lastHidden, rows: 1) + residualToDiT(lastResidual, rows: 1)
            let startNoise = noise?(step) ?? (0..<VoxVoice.patchValues).map { _ in voxHalf(random.normal()) }
            let patch = try await sample(mu: mu, previous: previous, noise: startNoise, guidance: options.guidance)
            let stop = stopHead(stopProjection(lastHidden, rows: 1).map { $0 / (1 + exp(-$0)) }, rows: 1)
            timing.patches = step + 1
            if step > options.minimumPatches && stop[1] > stop[0] {
                push(patch)
                break
            }
            if step + 1 == budget {
                throw VoxError.context(available <= options.maximumPatches
                    ? "The text and reference voice are too long for one reply."
                    : "The reply did not finish within \(budget) audio patches.")
            }
            push(patch)
            try decode(final: false)
            let current = try await encode(patch, count: 1)
            lastHidden = quantize(try await run(base, current, rows: 1, reset: false, rope: stages["base-0"]!.config.rope), rows: 1)
            lastResidual = try await run(residual, fusion(lastHidden + current, rows: 1), rows: 1, reset: false,
                                         rope: stages["residual"]!.config.rope)
            previous = patch
        }
        try decode(final: true)
        return output
    }

    /// Token ids, per-position 4 × 64 features and which positions are audio (prompt.py).
    func buildInputs(_ text: String, voice: VoxVoice?) throws -> (ids: [Int], features: [Float], audio: [Bool]) {
        let reference = voice?.reference, prompt = voice?.continuation
        var ids = tokenizer.encode((prompt != nil ? voice!.transcript : "") + text) + [101]
        let patches = voice?.patches ?? 0
        let positions = ids.count + (reference != nil ? patches + 2 : 0) + (prompt != nil ? patches : 0)
        guard positions + 4 <= maximumPositions else { throw VoxError.context("The text and reference voice are too long for one reply.") }
        let zero = [Float](repeating: 0, count: VoxVoice.patchValues)
        var features = [Float](repeating: 0, count: ids.count * VoxVoice.patchValues)
        var audio = [Bool](repeating: false, count: ids.count)
        if let reference {
            ids = [103] + [Int](repeating: 0, count: patches) + [104] + ids
            features = zero + reference + zero + features
            audio = [false] + [Bool](repeating: true, count: patches) + [false] + audio
        }
        if let prompt {
            ids += [Int](repeating: 0, count: patches)
            features += prompt
            audio += [Bool](repeating: true, count: patches)
        }
        return (ids, features, audio)
    }

    // MARK: Stages

    /// Feature-encoder embeddings (count × hidden) of `count` 4 × 64 patches; each distinct patch once.
    private func encode(_ patches: [Float], count: Int) async throws -> [Float] {
        let size = VoxVoice.patchValues
        var unique: [[Float]] = [], index: [Int] = [], seen: [[Float]: Int] = [:]
        for row in 0..<count {
            let patch = patches[(row * size)..<((row + 1) * size)].map(voxHalf)
            if let known = seen[patch] { index.append(known) } else { seen[patch] = unique.count; index.append(unique.count); unique.append(patch) }
        }
        let width = ditWidth
        let projected = featureEncoderInput(unique.flatMap { $0 }, rows: unique.count * 4)
        guard let functions = stages["encoder"]?.local_functions, let main = functions["main"], let batch = functions["batch"],
              let mainWidth = main.width, let batchWidth = batch.width else { throw VoxError.unsupported("encoder functions") }
        let length = 5
        let perCall = unique.count == 1 ? 1 : batchWidth / length
        let function = unique.count == 1 ? main : batch
        let callWidth = unique.count == 1 ? mainWidth : batchWidth
        var classes = [Float](repeating: 0, count: unique.count * width)
        var start = 0
        while start < unique.count {
            let rows = min(perCall, unique.count - start)
            var values = rowsInputs(width: callWidth, count: rows, length: length)
            var hiddenValues = [Float16](repeating: 0, count: width * callWidth)
            for row in 0..<rows {
                for channel in 0..<width {
                    hiddenValues[channel * callWidth + row * length] = Float16(specialToken[channel])
                    for frame in 0..<4 {
                        hiddenValues[channel * callWidth + row * length + 1 + frame] = Float16(projected[((start + row) * 4 + frame) * width + channel])
                    }
                }
            }
            values["hidden"] = hiddenValues
            let out = try await assets["encoder"]!.run(function.name, values)
            for row in 0..<rows {
                for channel in 0..<width { classes[(start + row) * width + channel] = Float(out[channel * callWidth + row * length]) }
            }
            start += rows
        }
        let embedded = encoderToLM(classes, rows: unique.count)
        var result = [Float](repeating: 0, count: count * hidden)
        for row in 0..<count {
            let source = index[row]
            for channel in 0..<hidden { result[row * hidden + channel] = embedded[source * hidden + channel] }
        }
        return result
    }

    /// Runs `rows` positions through a cached language-model stage in prefill-width chunks.
    private func run(_ stage: VoxAsset.Cached, _ x: [Float], rows: Int, reset: Bool, rope: Bool) async throws -> [Float] {
        if reset { stage.reset() }
        guard stage.position + rows <= maximumPositions else { throw VoxError.context("The reply is too long for the voice model.") }
        let width = stage.hidden
        var result = [Float](repeating: 0, count: rows * width)
        var offset = 0
        while offset < rows {
            let count = min(manifest.prefill_width, rows - offset)
            let columns = count == 1 ? 1 : manifest.prefill_width
            guard let capacity = manifest.capacities.sorted().first(where: { $0 >= stage.position + count }),
                  let function = stage.functions.first(where: { $0.capacity == capacity && $0.width == columns }) else {
                throw VoxError.unsupported("no cache function for \(stage.position + count) positions")
            }
            var hiddenValues = [Float16](repeating: 0, count: width * columns)
            for row in 0..<count {
                for channel in 0..<width { hiddenValues[channel * columns + row] = Float16(x[(offset + row) * width + channel]) }
            }
            var cosValues = [Float16](repeating: 1, count: headDimension * columns)
            var sinValues = [Float16](repeating: 0, count: headDimension * columns)
            if rope {
                for row in 0..<count {
                    let position = stage.position + row
                    for index in 0..<headDimension {
                        cosValues[index * columns + row] = cosine[position * headDimension + index]
                        sinValues[index * columns + row] = sine[position * headDimension + index]
                    }
                }
            }
            let out = try await stage.run(function.name, count: count,
                                          values: ["hidden": hiddenValues, "cos": cosValues, "sin": sinValues])
            for row in 0..<count {
                for channel in 0..<width { result[(offset + row) * width + channel] = Float(out[channel * count + row]) }
            }
            offset += count
        }
        return result
    }

    /// Masks and RoPE tables for `count` independent rows of `length` packed into `width` columns.
    private func rowsInputs(width: Int, count: Int, length: Int) -> [String: [Float16]] {
        let key = "\(width):\(count):\(length)"
        if let cached = masks[key] { return cached }
        var mask = [Float16](repeating: -30000, count: width * width)
        for start in stride(from: 0, to: count * length, by: length) {
            for row in start..<(start + length) { for column in start..<(start + length) { mask[row * width + column] = 0 } }
        }
        for index in 0..<width { mask[index * width + index] = 0 }
        var cosValues = [Float16](repeating: 0, count: headDimension * width), sinValues = cosValues
        for column in 0..<width {
            let position = column % length
            for index in 0..<headDimension {
                cosValues[index * width + column] = cosine[position * headDimension + index]
                sinValues[index * width + column] = sine[position * headDimension + index]
            }
        }
        let values = ["cos": cosValues, "sin": sinValues, "mask": mask]
        masks[key] = values
        return values
    }

    /// Scalar quantization of language-model states: tanh, round to ninths, project back.
    private func quantize(_ x: [Float], rows: Int) -> [Float] {
        let scale = Float(config.scalar_quantization_scale)
        let latent = quantizerInput(x, rows: rows).map { (tanh($0) * scale).rounded(.toNearestOrEven) / scale }
        return quantizerOutput(latent, rows: rows)
    }

    /// One 4 × 64 patch from the diffusion sampler, guided by `mu` and the previous patch.
    private func sample(mu: [Float], previous: [Float], noise: [Float], guidance: Float) async throws -> [Float] {
        let width = ditWidth
        guard let pair = stages["dit"]?.local_functions?["pair"], let pairWidth = pair.width else { throw VoxError.unsupported("sampler") }
        // Rows: guided [mu, time, condition, frames] and unguided with mu zeroed; the sampler adds time and frames.
        let condition = conditionProjection(previous.map(voxHalf), rows: 4)
        var context = [Float16](repeating: 0, count: width * 12)
        for channel in 0..<width {
            context[channel * 12 + 0] = Float16(mu[channel])
            context[channel * 12 + 1] = Float16(mu[width + channel])
            for row in 0..<4 {
                let value = Float16(condition[row * width + channel])
                context[channel * 12 + 2 + row] = value
                context[channel * 12 + 8 + row] = value
            }
        }
        var values = rowsInputs(width: pairWidth, count: 2, length: 11)
        values["context"] = context
        values["guidance"] = [Float16(guidance)]
        var x = noise.map { Float16($0) }
        for call in schedule {
            values["x"] = x
            values["clocks"] = call.clocks
            values["dts"] = call.dts
            x = try await assets["dit"]!.run(call.name, values)
        }
        var patch = [Float](repeating: 0, count: VoxVoice.patchValues)
        for channel in 0..<64 { for frame in 0..<4 { patch[frame * 64 + channel] = Float(x[channel * 4 + frame]) } }
        return patch
    }

    /// Fused Euler calls shared by every patch, in the reference runtime's half precision.
    /// Upstream's initial zero-velocity steps leave the sample unchanged and are skipped.
    private func makeSchedule(steps: Int) throws -> [(name: String, clocks: [Float16], dts: [Float16])] {
        let span = (0...steps).map { index -> Float in
            let value = voxHalf(1 - Float(index) / Float(steps))
            let bend = voxHalf(voxHalf(voxHalf(cos(voxHalf(Float.pi / 2 * value))) - 1) + value)
            return voxHalf(value + bend)
        }
        var t = span[0], dt = voxHalf(span[0] - span[1])
        let zeroSteps = max(1, Int(Double(span.count) * 0.04))
        var timeline: [(dt: Float, clock: [Float])] = []
        for step in 1..<span.count {
            if step > zeroSteps { timeline.append((dt, try clock(t))) }
            t = voxHalf(t - dt)
            if step < span.count - 1 { dt = voxHalf(t - span[step + 1]) }
        }
        let functions = (stages["dit"]?.sampler_functions ?? []).compactMap { function in function.steps.map { (function.name, $0) } }
            .sorted { $0.1 > $1.1 }
        var calls: [(name: String, clocks: [Float16], dts: [Float16])] = []
        var remaining = timeline[...]
        while !remaining.isEmpty {
            guard let chosen = functions.first(where: { $0.1 <= remaining.count }) else { throw VoxError.unsupported("sampler steps") }
            let (name, size) = chosen
            let part = remaining.prefix(size)
            remaining = remaining.dropFirst(size)
            var clocks = [Float16](repeating: 0, count: ditWidth * size)
            for (column, item) in part.enumerated() {
                for channel in 0..<ditWidth { clocks[channel * size + column] = Float16(item.clock[channel]) }
            }
            calls.append((name, clocks, part.map { Float16($0.dt) }))
        }
        return calls
    }

    /// Diffusion time embedding of `t` plus upstream's zero step-size embedding (half precision).
    private func clock(_ t: Float) throws -> [Float] {
        let prefix = "feat_decoder.estimator."
        let half = ditWidth / 2
        let exponent = Float(-log(10000.0) / Double(half - 1))
        let inverse = (0..<half).map { voxHalf(exp(voxHalf(Float($0) * exponent))) }
        func embed(_ value: Float, _ name: String) throws -> [Float] {
            let scaled = voxHalf(1000 * value)
            let phase = inverse.map { voxHalf(scaled * $0) }
            let embedding = phase.map { voxHalf(sin($0)) } + phase.map { voxHalf(cos($0)) }
            let first = try VoxLinear(weights, prefix + name + ".linear_1", input: ditWidth, output: ditWidth)
            let second = try VoxLinear(weights, prefix + name + ".linear_2", input: ditWidth, output: ditWidth)
            let activated = first(embedding, rows: 1).map { voxHalf(voxHalf($0) / (1 + exp(-voxHalf($0)))) }
            return second(activated, rows: 1).map(voxHalf)
        }
        let time = try embed(t, "time_mlp"), delta = try embed(0, "delta_time_mlp")
        return zip(time, delta).map { voxHalf($0 + $1) }
    }
}
#endif
