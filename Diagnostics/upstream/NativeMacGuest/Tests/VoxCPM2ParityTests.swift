import AVFoundation
import Foundation

// Parity and speed checks for the Swift VoxCPM2 port against tensors dumped from the Python
// tinkerbox-ane runtime (see run-voxcpm2.sh). Usage:
//   voxcpm2-tests <bundle> <reference dir> cpu
//   voxcpm2-tests <bundle> <reference dir> engine [<sentences.json> <output dir>]

struct Reference {
    let folder: URL
    let manifest: [String: Any]

    init(_ folder: URL) throws {
        self.folder = folder
        manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as! [String: Any]
    }

    func tensor(_ name: String) throws -> (shape: [Int], values: [Float]) {
        let shape = (manifest["tensors"] as! [String: [Int]])[name]!
        let data = try Data(contentsOf: folder.appendingPathComponent(name + ".f32"))
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        precondition(values.count == shape.reduce(1, *), "\(name) size")
        return (shape, values)
    }
}

var failures = 0
func check(_ condition: Bool, _ message: String) {
    print((condition ? "PASS " : "FAIL ") + message)
    if !condition { failures += 1 }
}

/// Max absolute difference and RMS of the difference relative to the reference's RMS.
func compare(_ a: [Float], _ b: [Float]) -> (max: Float, relative: Float) {
    precondition(a.count == b.count, "length \(a.count) vs \(b.count)")
    var maximum: Float = 0, error: Double = 0, power: Double = 0
    for index in a.indices {
        let difference = a[index] - b[index]
        maximum = max(maximum, abs(difference))
        error += Double(difference * difference)
        power += Double(b[index] * b[index])
    }
    return (maximum, Float((error / max(power, 1e-20)).squareRoot()))
}

func writeWAV(_ samples: [Float], rate: Int, to url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                           AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                                           AVLinearPCMIsFloatKey: false])
    try file.write(from: buffer)
}

func cpuChecks(bundle: URL, reference: Reference) throws {
    let checkpoint = bundle.appendingPathComponent("checkpoint")
    var started = Date()
    let tokenizer = try VoxTokenizer(url: checkpoint.appendingPathComponent("tokenizer.json"))
    print(String(format: "tokenizer loaded in %.2f s", Date().timeIntervalSince(started)))
    for item in reference.manifest["tokens"] as! [[String: Any]] {
        let text = item["text"] as! String, expected = item["ids"] as! [Int]
        let ids = tokenizer.encode(text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        check(ids == expected, "tokens \(text.debugDescription.prefix(40))" + (ids == expected ? "" : " got \(ids.prefix(24)) expected \(expected.prefix(24))"))
    }

    let config = try JSONDecoder().decode(VoxCheckpointConfig.self, from: Data(contentsOf: checkpoint.appendingPathComponent("config.json")))
    started = Date()
    let codec = try VoxAudioVAE(url: checkpoint.appendingPathComponent("audiovae.safetensors"), config: config.audio_vae_config)
    print(String(format: "AudioVAE loaded in %.2f s", Date().timeIntervalSince(started)))

    let wave = try reference.tensor("ref_wave").values
    let alignment = 4 * codec.encodeHop
    let count = (wave.count + alignment - 1) / alignment, pad = count * alignment - wave.count
    for (name, padded) in [("voice_reference", wave + [Float](repeating: 0, count: pad)),
                           ("voice_continuation", [Float](repeating: 0, count: pad) + wave)] {
        started = Date()
        let latent = codec.encode(padded)
        let seconds = Date().timeIntervalSince(started)
        var patches = [Float](repeating: 0, count: count * 256)
        for patch in 0..<count { for frame in 0..<4 { for channel in 0..<64 {
            patches[(patch * 4 + frame) * 64 + channel] = latent.values[channel * latent.frames + patch * 4 + frame]
        } } }
        let difference = compare(patches, try reference.tensor(name).values)
        check(difference.relative < 1e-3, String(format: "%@ encode: max %.2e, relative %.2e, %.2f s for %.1f s of audio",
                                                 name, difference.max, difference.relative, seconds, Double(wave.count) / 16000))
    }

    let latents = try reference.tensor("decode_latents")
    let frames = latents.shape[1]
    let signal = VoxSignal(channels: 64, frames: frames, values: latents.values)
    codec.resetDecoder()
    started = Date()
    var audio: [Float] = []
    for start in stride(from: 0, to: frames, by: 16) { audio += codec.decode(signal.slice(start..<min(frames, start + 16))) }
    let seconds = Date().timeIntervalSince(started)
    let difference = compare(audio, try reference.tensor("decode_audio").values)
    check(difference.relative < 1e-3, String(format: "decode: max %.2e, relative %.2e, %.3f s for %.1f s of audio",
                                             difference.max, difference.relative, seconds, Double(audio.count) / 48000))
    // Chunking must not change the samples.
    codec.resetDecoder()
    let whole = codec.decode(signal)
    check(compare(whole, audio).max < 1e-4, "decode in one call equals 16-frame chunks")
}

@available(macOS 27.0, *)
func engineChecks(bundle: URL, reference: Reference, sentences: URL?, output: URL?) async throws {
    var started = Date()
    let model = try await VoxCPM2(bundle: bundle)
    print(String(format: "engine loaded in %.2f s", Date().timeIntervalSince(started)))

    // Parity: the Python voice tensors and starting noise, so only the port differs.
    let referencePatches = try reference.tensor("voice_reference")
    let voice = VoxVoice(mode: .cloneContinuation, transcript: try String(contentsOf: reference.folder.appendingPathComponent("../../ttsbench/ref/ref.txt"), encoding: .utf8)
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                         reference: referencePatches.values, continuation: try reference.tensor("voice_continuation").values,
                         patches: referencePatches.shape[0])
    let noise = try reference.tensor("gen_noise").values
    let expectedPatches = try reference.tensor("gen_patches").values
    let expectedSteps = reference.manifest["generate_steps"] as! Int
    started = Date()
    let audio = try await model.generate(reference.manifest["generate_text"] as! String, voice: voice, seed: 23,
                                         noise: { step in Array(noise[(step * 256)..<((step + 1) * 256)]) })
    let seconds = Date().timeIntervalSince(started)
    print(String(format: "parity generation: %d patches (Python %d), %.2f s for %.2f s of audio, Neural Engine %.2f s",
                 model.timing.patches, expectedSteps, seconds, Double(audio.count) / 48000, model.timing.neuralEngine))
    check(model.timing.patches == expectedSteps, "same number of patches as Python")
    let pythonAudio = try reference.tensor("gen_audio").values
    if audio.count == pythonAudio.count {
        let difference = compare(audio, pythonAudio)
        print(String(format: "audio vs Python: max %.3f, relative %.3f", difference.max, difference.relative))
    }
    _ = expectedPatches
    if let output {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try writeWAV(audio, rate: model.sampleRate, to: output.appendingPathComponent("parity.wav"))
    }

    // Speed and quality: every bench sentence with the port's own noise and a voice it encoded itself.
    guard let sentences, let output else { return }
    let wave = try reference.tensor("ref_wave").values
    started = Date()
    let own = try model.makeVoice(samples: wave, rate: 16000, transcript: voice.transcript)
    print(String(format: "voice encoded in %.2f s", Date().timeIntervalSince(started)))
    check(compare(own.reference!, referencePatches.values).relative < 1e-3, "voice from makeVoice matches Python")
    let texts = try JSONSerialization.jsonObject(with: Data(contentsOf: sentences)) as! [String]
    var rows: [[String: Any]] = []
    for (index, text) in texts.enumerated() {
        started = Date()
        let samples = try await model.generate(text, voice: own, seed: 23)
        let seconds = Date().timeIntervalSince(started)
        try writeWAV(samples, rate: model.sampleRate, to: output.appendingPathComponent(String(format: "%02d.wav", index)))
        let row: [String: Any] = ["index": index, "seconds": (seconds * 1000).rounded() / 1000,
                                  "audio_seconds": Double(samples.count) / 48000, "rate": 48000,
                                  "neural_engine_seconds": (model.timing.neuralEngine * 1000).rounded() / 1000]
        print(row)
        rows.append(row)
    }
    let run: [String: Any] = ["repo": "Swift port, VoxCPM2 LUT8 Core AI (clone_continuation)", "lang": "auto",
                              "rows": rows, "rss_peak_gb": Double(peakResident()) / 1e9]
    try JSONSerialization.data(withJSONObject: run, options: .prettyPrinted).write(to: output.appendingPathComponent("run.json"))
}

func peakResident() -> Int {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int(usage.ru_maxrss)
}

@main struct VoxCPM2ParityTests {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 4 else { print("usage: voxcpm2-tests <bundle> <reference> cpu|engine [sentences output]"); exit(2) }
        let bundle = URL(fileURLWithPath: arguments[1]), referenceFolder = URL(fileURLWithPath: arguments[2])
        do {
            let reference = try Reference(referenceFolder)
            switch arguments[3] {
            case "cpu":
                try cpuChecks(bundle: bundle, reference: reference)
            case "engine":
                guard #available(macOS 27.0, *) else { print("needs macOS 27"); exit(2) }
                try await engineChecks(bundle: bundle, reference: reference,
                                       sentences: arguments.count > 4 ? URL(fileURLWithPath: arguments[4]) : nil,
                                       output: arguments.count > 5 ? URL(fileURLWithPath: arguments[5]) : nil)
            default:
                print("unknown mode"); exit(2)
            }
        } catch {
            print("ERROR \(error)")
            exit(1)
        }
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        print(String(format: "peak resident %.2f GB", Double(peakResident()) / 1e9))
        exit(failures == 0 ? 0 : 1)
    }
}
