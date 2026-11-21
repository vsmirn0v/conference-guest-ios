import Accelerate
import Foundation

// AudioVAE V2 from OpenBMB/VoxCPM (Apache-2.0), as reduced by tinkerbox-ane's codec.py
// (Apache-2.0): causal convolutions with weight norm already folded into the checkpoint,
// Snake activations, depthwise residual units and sample-rate conditioning. Runs on the CPU
// with Accelerate. Every convolution keeps its left context between calls, so decoding in
// chunks gives the same samples as decoding at once, and audio can play while it is made.

/// Channel-major activations: `channels` rows of `frames` values.
struct VoxSignal {
    var channels: Int
    var frames: Int
    var values: [Float]

    init(channels: Int, frames: Int, values: [Float]) {
        precondition(values.count == channels * frames)
        self.channels = channels
        self.frames = frames
        self.values = values
    }

    static func zeros(_ channels: Int, _ frames: Int) -> VoxSignal {
        VoxSignal(channels: channels, frames: frames, values: [Float](repeating: 0, count: channels * frames))
    }

    /// Frames `range` of every channel.
    func slice(_ range: Range<Int>) -> VoxSignal {
        var result = VoxSignal.zeros(channels, range.count)
        for channel in 0..<channels {
            for (target, source) in range.enumerated() { result.values[channel * range.count + target] = values[channel * frames + source] }
        }
        return result
    }
}

/// A causal 1-D convolution: `pad` zeros (then the previous call's tail) on the left.
final class VoxCausalConv {
    let input: Int, output: Int, kernel: Int, stride: Int, dilation: Int, pad: Int
    let depthwise: Bool
    private let weight: VoxWeights
    private let bias: VoxWeights
    private var history: [Float]

    init(_ file: VoxSafeTensors, _ prefix: String, input: Int, output: Int, kernel: Int,
         stride: Int = 1, dilation: Int = 1, pad: Int, depthwise: Bool = false) throws {
        precondition(!depthwise || (input == output && stride == 1))
        self.input = input; self.output = output; self.kernel = kernel
        self.stride = stride; self.dilation = dilation; self.pad = pad; self.depthwise = depthwise
        weight = try file.f32(prefix + ".weight", shape: [output, depthwise ? 1 : input, kernel])
        bias = try file.f32(prefix + ".bias", shape: [output])
        history = [Float](repeating: 0, count: input * pad)
    }

    func reset() { history = [Float](repeating: 0, count: input * pad) }

    func callAsFunction(_ x: VoxSignal) -> VoxSignal {
        precondition(x.channels == input)
        let span = pad + x.frames
        var padded: [Float]
        if pad == 0 {
            padded = x.values
        } else {
            padded = [Float](repeating: 0, count: input * span)
            for channel in 0..<input {
                for index in 0..<pad { padded[channel * span + index] = history[channel * pad + index] }
                for index in 0..<x.frames { padded[channel * span + pad + index] = x.values[channel * x.frames + index] }
                for index in 0..<pad { history[channel * pad + index] = padded[channel * span + span - pad + index] }
            }
        }
        let frames = (span - dilation * (kernel - 1) - 1) / stride + 1
        guard frames > 0 else { return .zeros(output, 0) }
        var y = [Float](repeating: 0, count: output * frames)
        padded.withUnsafeBufferPointer { source in
            y.withUnsafeMutableBufferPointer { target in
                let x = source.baseAddress!, out = target.baseAddress!
                if depthwise {
                    for channel in 0..<output {
                        let row = out + channel * frames, base = x + channel * span
                        var tap = weight[channel * kernel]
                        vDSP_vsmul(base, 1, &tap, row, 1, vDSP_Length(frames))
                        for index in 1..<kernel {
                            tap = weight[channel * kernel + index]
                            vDSP_vsma(base + index * dilation, 1, &tap, row, 1, row, 1, vDSP_Length(frames))
                        }
                    }
                } else if kernel == 1 && stride == 1 {
                    voxMultiply(weight.pointer, rows: output, inner: input, x, columns: frames, into: out, stride: frames)
                } else {
                    // im2col in time tiles, then one matrix product per tile.
                    let rows = input * kernel
                    let tile = max(1, min(frames, (1 << 21) / rows))
                    var columns = [Float](repeating: 0, count: rows * tile)
                    columns.withUnsafeMutableBufferPointer { buffer in
                        let cols = buffer.baseAddress!
                        var start = 0
                        while start < frames {
                            let count = min(tile, frames - start)
                            for channel in 0..<input {
                                for index in 0..<kernel {
                                    cblas_scopy(Int32(count), x + channel * span + start * stride + index * dilation, Int32(stride),
                                                cols + (channel * kernel + index) * tile, 1)
                                }
                            }
                            voxMultiply(weight.pointer, rows: output, inner: rows, cols, columns: count, columnStride: tile,
                                        into: out + start, stride: frames)
                            start += count
                        }
                    }
                }
                for channel in 0..<output {
                    var value = bias[channel]
                    vDSP_vsadd(out + channel * frames, 1, &value, out + channel * frames, 1, vDSP_Length(frames))
                }
            }
        }
        return VoxSignal(channels: output, frames: frames, values: y)
    }
}

/// A causal transposed convolution with kernel 2×stride, trimmed so `frames` in give
/// `frames × stride` out; the previous call's last input frame is its left context.
final class VoxCausalTransposedConv {
    let input: Int, output: Int, stride: Int
    private let kernel: Int
    private let weight: VoxWeights
    private let bias: VoxWeights
    private var history: [Float]

    init(_ file: VoxSafeTensors, _ prefix: String, input: Int, output: Int, stride: Int) throws {
        self.input = input; self.output = output; self.stride = stride
        kernel = 2 * stride
        weight = try file.f32(prefix + ".weight", shape: [input, output, kernel])
        bias = try file.f32(prefix + ".bias", shape: [output])
        history = [Float](repeating: 0, count: input)
    }

    func reset() { history = [Float](repeating: 0, count: input) }

    func callAsFunction(_ x: VoxSignal) -> VoxSignal {
        precondition(x.channels == input)
        let frames = x.frames, span = frames + 1
        guard frames > 0 else { return .zeros(output, 0) }
        var full = [Float](repeating: 0, count: input * span)
        for channel in 0..<input {
            full[channel * span] = history[channel]
            for index in 0..<frames { full[channel * span + 1 + index] = x.values[channel * frames + index] }
            history[channel] = x.values[channel * frames + frames - 1]
        }
        // Z[(o, j), u] = Σ_i W[i, o, j] · x[i, u]; then y[o, u·s + j] += Z, trimmed to frames·s.
        let rows = output * kernel
        var z = [Float](repeating: 0, count: rows * span)
        full.withUnsafeBufferPointer { source in
            z.withUnsafeMutableBufferPointer { target in
                cblas_sgemm(CblasRowMajor, CblasTrans, CblasNoTrans, Int32(rows), Int32(span), Int32(input), 1,
                            weight.pointer, Int32(rows), source.baseAddress!, Int32(span), 0, target.baseAddress!, Int32(span))
            }
        }
        let length = frames * stride
        var y = [Float](repeating: 0, count: output * length)
        z.withUnsafeBufferPointer { source in
            y.withUnsafeMutableBufferPointer { target in
                let z = source.baseAddress!, out = target.baseAddress!
                for channel in 0..<output {
                    for offset in 0..<stride {
                        let late = z + (channel * kernel + offset) * span + 1
                        let early = z + (channel * kernel + stride + offset) * span
                        vDSP_vadd(late, 1, early, 1, out + channel * length + offset, vDSP_Stride(stride), vDSP_Length(frames))
                    }
                    var value = bias[channel]
                    vDSP_vsadd(out + channel * length, 1, &value, out + channel * length, 1, vDSP_Length(length))
                }
            }
        }
        return VoxSignal(channels: output, frames: length, values: y)
    }
}

/// x + sin²(αx)/α per channel.
struct VoxSnake {
    private let alpha: VoxWeights
    let channels: Int

    init(_ file: VoxSafeTensors, _ name: String, channels: Int) throws {
        alpha = try file.f32(name, shape: [1, channels, 1])
        self.channels = channels
    }

    func callAsFunction(_ x: VoxSignal) -> VoxSignal {
        precondition(x.channels == channels)
        var y = x
        let frames = x.frames
        var scratch = [Float](repeating: 0, count: frames)
        var count = Int32(frames)
        y.values.withUnsafeMutableBufferPointer { buffer in
            scratch.withUnsafeMutableBufferPointer { temporary in
                for channel in 0..<channels {
                    let row = buffer.baseAddress! + channel * frames, t = temporary.baseAddress!
                    var a = alpha[channel], inverse = 1 / (a + 1e-9)
                    vDSP_vsmul(row, 1, &a, t, 1, vDSP_Length(frames))
                    vvsinf(t, t, &count)
                    vDSP_vsq(t, 1, t, 1, vDSP_Length(frames))
                    vDSP_vsma(t, 1, &inverse, row, 1, row, 1, vDSP_Length(frames))
                }
            }
        }
        return y
    }
}

/// x + 1×1(snake(depthwise k7(snake(x)))).
final class VoxResidualUnit {
    private let first: VoxSnake, depthwise: VoxCausalConv, second: VoxSnake, pointwise: VoxCausalConv

    init(_ file: VoxSafeTensors, _ prefix: String, channels: Int, dilation: Int) throws {
        first = try VoxSnake(file, prefix + ".block.0.alpha", channels: channels)
        depthwise = try VoxCausalConv(file, prefix + ".block.1", input: channels, output: channels, kernel: 7,
                                      dilation: dilation, pad: 6 * dilation, depthwise: true)
        second = try VoxSnake(file, prefix + ".block.2.alpha", channels: channels)
        pointwise = try VoxCausalConv(file, prefix + ".block.3", input: channels, output: channels, kernel: 1, pad: 0)
    }

    func reset() { depthwise.reset(); pointwise.reset() }

    func callAsFunction(_ x: VoxSignal) -> VoxSignal {
        var y = pointwise(second(depthwise(first(x))))
        y.values.withUnsafeMutableBufferPointer { target in
            vDSP_vadd(target.baseAddress!, 1, x.values, 1, target.baseAddress!, 1, vDSP_Length(target.count))
        }
        return y
    }
}

/// The 16 kHz → 25 Hz encoder and 25 Hz → 48 kHz decoder.
final class VoxAudioVAE {
    let sampleRate: Int
    let outputRate: Int
    /// Input samples per latent frame (640) and output samples per latent frame (1920).
    let encodeHop: Int
    let decodeHop: Int
    let latentChannels: Int

    private let file: VoxSafeTensors
    private let encoderInput: VoxCausalConv
    private let encoderBlocks: [(units: [VoxResidualUnit], snake: VoxSnake, down: VoxCausalConv)]
    private let encoderOutput: VoxCausalConv
    private let decoderDepthwise: VoxCausalConv
    private let decoderInput: VoxCausalConv
    private let decoderBlocks: [(scale: [Float], shift: [Float], snake: VoxSnake, up: VoxCausalTransposedConv, units: [VoxResidualUnit])]
    private let decoderSnake: VoxSnake
    private let decoderOutput: VoxCausalConv

    struct Config: Decodable {
        let encoder_dim: Int
        let encoder_rates: [Int]
        let latent_dim: Int
        let decoder_dim: Int
        let decoder_rates: [Int]
        let sr_bin_boundaries: [Int]
        let sample_rate: Int
        let out_sample_rate: Int
    }

    init(url: URL, config: Config) throws {
        let file = try VoxSafeTensors(url: url)
        self.file = file
        sampleRate = config.sample_rate
        outputRate = config.out_sample_rate
        encodeHop = config.encoder_rates.reduce(1, *)
        decodeHop = config.decoder_rates.reduce(1, *)
        latentChannels = config.latent_dim

        var width = config.encoder_dim
        encoderInput = try VoxCausalConv(file, "encoder.block.0", input: 1, output: width, kernel: 7, pad: 6)
        var blocks: [(units: [VoxResidualUnit], snake: VoxSnake, down: VoxCausalConv)] = []
        for (index, stride) in config.encoder_rates.enumerated() {
            let prefix = "encoder.block.\(index + 1).block"
            let units = try [1, 3, 9].enumerated().map {
                try VoxResidualUnit(file, "\(prefix).\($0.offset)", channels: width, dilation: $0.element)
            }
            let snake = try VoxSnake(file, "\(prefix).3.alpha", channels: width)
            let down = try VoxCausalConv(file, "\(prefix).4", input: width, output: width * 2, kernel: 2 * stride,
                                         stride: stride, pad: stride)
            blocks.append((units, snake, down))
            width *= 2
        }
        encoderBlocks = blocks
        encoderOutput = try VoxCausalConv(file, "encoder.fc_mu", input: width, output: config.latent_dim, kernel: 3, pad: 2)

        let latent = config.latent_dim
        decoderDepthwise = try VoxCausalConv(file, "decoder.model.0", input: latent, output: latent, kernel: 7, pad: 6, depthwise: true)
        decoderInput = try VoxCausalConv(file, "decoder.model.1", input: latent, output: config.decoder_dim, kernel: 1, pad: 0)
        // torch.bucketize(rate, boundaries): the number of boundaries below the rate.
        let boundaries = try file.int32("decoder.sr_bin_boundaries").map(Int.init)
        guard boundaries == config.sr_bin_boundaries else { throw VoxError.format("AudioVAE sample-rate buckets differ") }
        let bucket = boundaries.filter { $0 < config.out_sample_rate }.count
        var channels = config.decoder_dim
        var decoder: [(scale: [Float], shift: [Float], snake: VoxSnake, up: VoxCausalTransposedConv, units: [VoxResidualUnit])] = []
        for (index, stride) in config.decoder_rates.enumerated() {
            let layer = index + 2, next = channels / 2
            let scales = try file.f32("decoder.sr_cond_model.\(layer).scale_embed.weight", shape: [boundaries.count + 1, channels])
            let shifts = try file.f32("decoder.sr_cond_model.\(layer).bias_embed.weight", shape: [boundaries.count + 1, channels])
            let scale = (0..<channels).map { scales[bucket * channels + $0] }
            let shift = (0..<channels).map { shifts[bucket * channels + $0] }
            let snake = try VoxSnake(file, "decoder.model.\(layer).block.0.alpha", channels: channels)
            let up = try VoxCausalTransposedConv(file, "decoder.model.\(layer).block.1", input: channels, output: next, stride: stride)
            let units = try [1, 3, 9].enumerated().map {
                try VoxResidualUnit(file, "decoder.model.\(layer).block.\($0.offset + 2)", channels: next, dilation: $0.element)
            }
            decoder.append((scale, shift, snake, up, units))
            channels = next
        }
        decoderBlocks = decoder
        let last = config.decoder_rates.count + 2
        decoderSnake = try VoxSnake(file, "decoder.model.\(last).alpha", channels: channels)
        decoderOutput = try VoxCausalConv(file, "decoder.model.\(last + 1)", input: channels, output: 1, kernel: 7, pad: 6)
    }

    /// Latents (64 × samples/640) of 16 kHz mono audio whose length is a multiple of 640.
    func encode(_ samples: [Float]) -> VoxSignal {
        precondition(samples.count % encodeHop == 0)
        encoderInput.reset(); encoderOutput.reset()
        for block in encoderBlocks { block.units.forEach { $0.reset() }; block.down.reset() }
        var latent = VoxSignal.zeros(latentChannels, samples.count / encodeHop)
        let chunk = encodeHop * 20
        var start = 0
        while start < samples.count {
            let count = min(chunk, samples.count - start)
            var x = encoderInput(VoxSignal(channels: 1, frames: count, values: Array(samples[start..<(start + count)])))
            for block in encoderBlocks {
                for unit in block.units { x = unit(x) }
                x = block.down(block.snake(x))
            }
            x = encoderOutput(x)
            let first = start / encodeHop
            for channel in 0..<latentChannels {
                for index in 0..<x.frames { latent.values[channel * latent.frames + first + index] = x.values[channel * x.frames + index] }
            }
            start += count
        }
        return latent
    }

    /// Starts a new utterance: the next `decode` call has no left context.
    func resetDecoder() {
        decoderDepthwise.reset(); decoderInput.reset(); decoderOutput.reset()
        for block in decoderBlocks { block.up.reset(); block.units.forEach { $0.reset() } }
    }

    /// 48 kHz samples for the next latent frames (64 × n) of the current utterance.
    func decode(_ latents: VoxSignal) -> [Float] {
        precondition(latents.channels == latentChannels)
        var x = decoderInput(decoderDepthwise(latents))
        for block in decoderBlocks {
            x.values.withUnsafeMutableBufferPointer { buffer in
                for channel in 0..<x.channels {
                    var scale = block.scale[channel], shift = block.shift[channel]
                    let row = buffer.baseAddress! + channel * x.frames
                    vDSP_vsmsa(row, 1, &scale, &shift, row, 1, vDSP_Length(x.frames))
                }
            }
            x = block.up(block.snake(x))
            for unit in block.units { x = unit(x) }
        }
        x = decoderOutput(decoderSnake(x))
        var count = Int32(x.values.count)
        var samples = x.values
        vvtanhf(&samples, x.values, &count)
        return samples
    }
}

/// C (rows × columns, row stride `stride`) = A (rows × inner) · B (inner × columns, row stride `columnStride`).
@inline(__always)
func voxMultiply(_ a: UnsafePointer<Float>, rows: Int, inner: Int, _ b: UnsafePointer<Float>, columns: Int,
                 columnStride: Int? = nil, into c: UnsafeMutablePointer<Float>, stride: Int) {
    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(rows), Int32(columns), Int32(inner), 1,
                a, Int32(inner), b, Int32(columnStride ?? columns), 0, c, Int32(stride))
}
