import Accelerate
import CoreML
import Foundation

/// GigaAM v3 e2e RNNT as native Core ML (smkrv/gigaam-v3-e2e-rnnt-coreml, fp16):
/// the encoder runs on the Neural Engine, the small prediction and joint networks in a
/// host-side greedy loop. Russian, punctuated text. Instances are not thread-safe; the
/// owner serializes calls (LocalSpeechRecognizer's queue).
struct CoreMLGigaAMModel: Equatable, Sendable {
    var encoder: URL
    var decoder: URL
    var joint: URL
    var tokens: URL
    /// Compiled models are kept here between launches (compiling takes seconds).
    var cache: URL
    var computeUnits: MLComputeUnits = .cpuAndNeuralEngine

    static func == (a: Self, b: Self) -> Bool {
        a.encoder == b.encoder && a.decoder == b.decoder && a.joint == b.joint && a.tokens == b.tokens &&
            a.cache == b.cache && a.computeUnits == b.computeUnits
    }
}

enum CoreMLGigaAMError: Error, Equatable {
    case badTokens, badOutput(String)
}

final class CoreMLGigaAMRecognizer {
    static let sampleRate = 16_000
    /// The encoder takes a fixed 30 s window; longer speech is split.
    static let window = 30 * sampleRate
    static let melFrames = (window - 320) / 160 + 1   // 2999
    static let blank = 1024
    static let maxSymbolsPerFrame = 10

    private let encoder: MLModel
    private let decoder: MLModel
    private let joint: MLModel
    private let pieces: [String]
    private let front = GigaAMMelFrontEnd()
    /// Seconds spent loading (compiling on first use, then the cached compiled copy).
    let loadSeconds: TimeInterval

    init(_ model: CoreMLGigaAMModel) throws {
        let started = ProcessInfo.processInfo.systemUptime
        let configuration = MLModelConfiguration()
        configuration.computeUnits = model.computeUnits
        encoder = try MLModel(contentsOf: Self.compiled(model.encoder, cache: model.cache), configuration: configuration)
        // The per-token networks are tiny; the CPU avoids Neural Engine dispatch per step.
        let small = MLModelConfiguration(); small.computeUnits = .cpuOnly
        decoder = try MLModel(contentsOf: Self.compiled(model.decoder, cache: model.cache), configuration: small)
        joint = try MLModel(contentsOf: Self.compiled(model.joint, cache: model.cache), configuration: small)
        pieces = try JSONDecoder().decode([String].self, from: Data(contentsOf: model.tokens))
        guard pieces.count == Self.blank else { throw CoreMLGigaAMError.badTokens }
        loadSeconds = ProcessInfo.processInfo.systemUptime - started
    }

    /// The compiled `.mlmodelc` for a package, compiled once and kept in `cache`.
    /// Rebuilt when the package's model file changes (size and date in the folder name).
    static func compiled(_ package: URL, cache: URL) throws -> URL {
        let spec = package.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel")
        let attributes = try FileManager.default.attributesOfItem(atPath: spec.path)
        let stamp = "\((attributes[.size] as? Int64) ?? 0)-\(Int((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))"
        let target = cache.appendingPathComponent("\(package.deletingPathExtension().lastPathComponent)-\(stamp).mlmodelc")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let built = try MLModel.compileModel(at: package)
        let staging = cache.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: built, to: staging)
        if (try? FileManager.default.moveItem(at: staging, to: target)) == nil { try? FileManager.default.removeItem(at: staging) }
        return target
    }

    /// Text for one utterance of 16 kHz mono speech.
    func transcribe(_ samples: [Float]) throws -> String {
        guard !samples.isEmpty else { return "" }
        var ids: [Int] = []
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + Self.window)
            ids += try decodeWindow(Array(samples[start..<end]))
            start = end
        }
        return Self.detokenize(ids, pieces: pieces)
    }

    private func decodeWindow(_ samples: [Float]) throws -> [Int] {
        guard samples.count >= 320 else { return [] }
        let features = try front.features(samples, frames: Self.melFrames, window: Self.window)
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: Int32((samples.count - 320) / 160 + 1))
        let out = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["features": features, "length": length]))
        guard let encoded = out.featureValue(for: "encoded")?.multiArrayValue,
              let lengthValue = out.featureValue(for: "encoded_len")?.multiArrayValue else { throw CoreMLGigaAMError.badOutput("encoder") }
        let frames = min(Int(Self.float(lengthValue, 0).rounded()), encoded.shape[2].intValue)
        let hidden = encoded.shape[1].intValue
        let encodedValues = Self.floats(encoded)
        let strides = encoded.strides.map(\.intValue)

        let token = try MLMultiArray(shape: [1, 1], dataType: .int32)
        var h = try MLMultiArray(shape: [1, 1, 320], dataType: .float32)
        var c = try MLMultiArray(shape: [1, 1, 320], dataType: .float32)
        for i in 0..<320 { h[i] = 0; c[i] = 0 }
        let encT = try MLMultiArray(shape: [1, NSNumber(value: hidden)], dataType: .float32)
        var last = Self.blank
        // The prediction network's output depends only on (last, h, c): rerun it only after an emission.
        var step = try predict(token: token, last: last, h: h, c: c)
        var ids: [Int] = []
        for t in 0..<frames {
            let encPointer = encT.dataPointer.assumingMemoryBound(to: Float.self)
            for d in 0..<hidden { encPointer[d] = encodedValues[d * strides[1] + t * strides[2]] }
            for _ in 0..<Self.maxSymbolsPerFrame {
                let logits = try joint.prediction(from: MLDictionaryFeatureProvider(dictionary: ["enc_t": encT, "dec_t": step.out]))
                guard let values = logits.featureValue(for: "logits")?.multiArrayValue else { throw CoreMLGigaAMError.badOutput("joint") }
                let k = Self.argmax(values)
                if k == Self.blank { break }
                ids.append(k)
                last = k; h = step.h; c = step.c
                step = try predict(token: token, last: last, h: h, c: c)
            }
        }
        return ids
    }

    private func predict(token: MLMultiArray, last: Int, h: MLMultiArray, c: MLMultiArray) throws -> (out: MLMultiArray, h: MLMultiArray, c: MLMultiArray) {
        token[0] = NSNumber(value: Int32(last))
        let out = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["token": token, "h_in": h, "c_in": c]))
        guard let dec = out.featureValue(for: "dec_out")?.multiArrayValue,
              let hOut = out.featureValue(for: "h_out")?.multiArrayValue,
              let cOut = out.featureValue(for: "c_out")?.multiArrayValue else { throw CoreMLGigaAMError.badOutput("decoder") }
        return (try Self.float32(dec), try Self.float32(hOut), try Self.float32(cOut))
    }

    // MARK: Multi-array helpers (outputs may be fp16 or strided)

    static func float(_ array: MLMultiArray, _ index: Int) -> Float { array[index].floatValue }

    /// All values in storage order (the caller indexes with `strides`).
    static func floats(_ array: MLMultiArray) -> [Float] {
        let count = zip(array.shape, array.strides).map { ($0.intValue - 1) * $1.intValue }.reduce(0, +) + 1
        switch array.dataType {
        case .float16:
            let source = array.dataPointer.assumingMemoryBound(to: Float16.self)
            return (0..<count).map { Float(source[$0]) }
        case .float32:
            let source = array.dataPointer.assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: source, count: count))
        default:
            return (0..<count).map { array[$0].floatValue }
        }
    }

    /// A contiguous float32 copy with the same shape (inputs are declared float32).
    static func float32(_ array: MLMultiArray) throws -> MLMultiArray {
        if array.dataType == .float32, array.strides.last?.intValue == 1 { return array }
        let copy = try MLMultiArray(shape: array.shape, dataType: .float32)
        let values = floats(array)
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        let target = copy.dataPointer.assumingMemoryBound(to: Float.self)
        var index = [Int](repeating: 0, count: shape.count)
        for flat in 0..<copy.count {
            var rest = flat
            for axis in stride(from: shape.count - 1, through: 0, by: -1) { index[axis] = rest % shape[axis]; rest /= shape[axis] }
            target[flat] = values[zip(index, strides).map(*).reduce(0, +)]
        }
        return copy
    }

    static func argmax(_ array: MLMultiArray) -> Int {
        let values = floats(array), stride = array.strides.last?.intValue ?? 1
        var best = 0, bestValue = -Float.infinity
        for i in 0..<array.shape.last!.intValue where values[i * stride] > bestValue { best = i; bestValue = values[i * stride] }
        return best
    }

    /// SentencePiece pieces to text: `▁` starts a word; `<0xHH>` pieces are raw UTF-8 bytes.
    static func detokenize(_ ids: [Int], pieces: [String]) -> String {
        var bytes: [UInt8] = []
        for id in ids where id < pieces.count {
            let piece = pieces[id]
            if piece.count == 6, piece.hasPrefix("<0x"), piece.hasSuffix(">"), let byte = UInt8(piece.dropFirst(3).dropLast(), radix: 16) {
                bytes.append(byte)
            } else {
                bytes += Array(piece.replacingOccurrences(of: "\u{2581}", with: " ").utf8)
            }
        }
        return (String(bytes: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// GigaAM's log-mel front-end, as torchaudio computes it: 16 kHz, 320-sample Hann window
/// (periodic), hop 160, no centering, power spectrum, 64 HTK mel bands without norm,
/// then log(clamp(x, 1e-9, 1e9)). The speech is zero-padded to the window.
final class GigaAMMelFrontEnd {
    static let fft = 320, hop = 160, bins = 161, mels = 64
    private let window: [Float]
    private let cosines: [Float]   // bins x fft
    private let sines: [Float]     // bins x fft
    private let filters: [Float]   // bins x mels

    init() {
        let n = Self.fft
        window = (0..<n).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(n)) }
        var cosines = [Float](repeating: 0, count: Self.bins * n), sines = cosines
        for k in 0..<Self.bins {
            for j in 0..<n {
                let angle = 2 * Double.pi * Double(k * j % n) / Double(n)
                cosines[k * n + j] = Float(cos(angle)); sines[k * n + j] = Float(sin(angle))
            }
        }
        self.cosines = cosines; self.sines = sines
        filters = Self.melFilters()
    }

    /// torchaudio.functional.melscale_fbanks(161, 0, 8000, 64, 16000, norm=None, mel_scale="htk").
    static func melFilters() -> [Float] {
        func mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func hz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let frequencies = (0..<bins).map { Double($0) * 8000 / Double(bins - 1) }
        let top = mel(8000)
        let points = (0..<(mels + 2)).map { hz(top * Double($0) / Double(mels + 1)) }
        var result = [Float](repeating: 0, count: bins * mels)
        for b in 0..<bins {
            for m in 0..<mels {
                let down = (frequencies[b] - points[m]) / (points[m + 1] - points[m])
                let up = (points[m + 2] - frequencies[b]) / (points[m + 2] - points[m + 1])
                result[b * mels + m] = Float(max(0, min(down, up)))
            }
        }
        return result
    }

    /// Features `[1, 64, frames]` for `samples` zero-padded to `window` samples.
    func features(_ samples: [Float], frames: Int, window total: Int) throws -> MLMultiArray {
        var padded = [Float](repeating: 0, count: total)
        padded.replaceSubrange(0..<min(samples.count, total), with: samples.prefix(total))
        let n = Self.fft
        // Framed, windowed signal: frames x n.
        var framed = [Float](repeating: 0, count: frames * n)
        padded.withUnsafeBufferPointer { source in
            for f in 0..<frames {
                vDSP_vmul(source.baseAddress! + f * Self.hop, 1, window, 1, &framed[f * n], 1, vDSP_Length(n))
            }
        }
        // Real and imaginary parts: frames x bins (framed x transposed basis).
        var real = [Float](repeating: 0, count: frames * Self.bins), imaginary = real
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(frames), Int32(Self.bins), Int32(n),
                    1, framed, Int32(n), cosines, Int32(n), 0, &real, Int32(Self.bins))
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(frames), Int32(Self.bins), Int32(n),
                    1, framed, Int32(n), sines, Int32(n), 0, &imaginary, Int32(Self.bins))
        var power = [Float](repeating: 0, count: frames * Self.bins)
        vDSP_vmul(real, 1, real, 1, &power, 1, vDSP_Length(power.count))
        vDSP_vma(imaginary, 1, imaginary, 1, power, 1, &power, 1, vDSP_Length(power.count))
        // Mel energies: frames x mels.
        var energies = [Float](repeating: 0, count: frames * Self.mels)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(frames), Int32(Self.mels), Int32(Self.bins),
                    1, power, Int32(Self.bins), filters, Int32(Self.mels), 0, &energies, Int32(Self.mels))
        var low: Float = 1e-9, high: Float = 1e9
        vDSP_vclip(energies, 1, &low, &high, &energies, 1, vDSP_Length(energies.count))
        var count = Int32(energies.count)
        vvlogf(&energies, energies, &count)
        // Transposed into [1, mels, frames].
        let array = try MLMultiArray(shape: [1, NSNumber(value: Self.mels), NSNumber(value: frames)], dataType: .float32)
        let target = array.dataPointer.assumingMemoryBound(to: Float.self)
        let strides = array.strides.map(\.intValue)
        for f in 0..<frames {
            for m in 0..<Self.mels { target[m * strides[1] + f * strides[2]] = energies[f * Self.mels + m] }
        }
        return array
    }
}
