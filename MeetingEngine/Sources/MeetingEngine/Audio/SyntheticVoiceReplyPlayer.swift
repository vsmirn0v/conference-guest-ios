import AVFoundation
import Foundation
import LiveKitWebRTC

/// Paces a synthesized PCM reply into an active synthetic WebRTC audio source
/// (`isSynthetic == true`) without touching `AudioState` or the hardware microphone.
enum SyntheticVoiceReplyPlayer {
    static let targetSampleRate: Double = 48_000
    static let targetChannels: AVAudioChannelCount = 1
    static let frameSamples = 480

    private final class MonitorBox: @unchecked Sendable {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        init?(buffer: AVAudioPCMBuffer, gain: Float) {
            guard gain > 0 else { return nil }
            let clampedGain = min(1, max(0, gain))
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            player.volume = clampedGain
            do {
                try engine.start()
            } catch {
                return nil
            }
            player.scheduleBuffer(buffer)
            player.play()
        }

        func stop() {
            player.stop()
            engine.stop()
            engine.detach(player)
        }
    }

    static func play(_ buffer: AVAudioPCMBuffer,
                     localGain: Float?,
                     deliverFrame: @escaping @Sendable (UnsafePointer<Int16>, Int) -> Void,
                     canContinue: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        guard let speechSamples = convertTo48kMonoInt16(buffer), !speechSamples.isEmpty else {
            return false
        }
        guard !Task.isCancelled else { return false }
        guard await MainActor.run(body: canContinue) else {
            return false
        }

        #if os(macOS)
        let monitor = localGain.flatMap { MonitorBox(buffer: buffer, gain: $0) }
        defer { monitor?.stop() }
        #else
        _ = localGain
        #endif

        // Pad two silent 10ms frames on normal completion so Opus flushes the tail.
        let padded = speechSamples + [Int16](repeating: 0, count: frameSamples * 2)
        let totalSpeech = speechSamples.count
        let clock = ContinuousClock()
        var nextDeadline = clock.now
        var offset = 0

        while offset < padded.count {
            if Task.isCancelled { return false }
            guard await MainActor.run(body: canContinue) else {
                return false
            }
            let remaining = padded.count - offset
            let chunkCount = min(frameSamples, remaining)
            var frame = [Int16](repeating: 0, count: frameSamples)
            for index in 0..<chunkCount {
                frame[index] = padded[offset + index]
            }
            frame.withUnsafeBufferPointer { ptr in
                if let base = ptr.baseAddress {
                    deliverFrame(base, frameSamples)
                }
            }
            offset += frameSamples
            if offset < padded.count {
                nextDeadline = nextDeadline.advanced(by: .milliseconds(10))
                if nextDeadline > clock.now {
                    do {
                        try await clock.sleep(until: nextDeadline, tolerance: .milliseconds(2))
                    } catch {
                        return false
                    }
                }
            }
        }
        return offset >= totalSpeech && !Task.isCancelled
    }

    static func play(_ buffer: AVAudioPCMBuffer,
                     into source: LKRTCAudioSource,
                     localGain: Float?,
                     canContinue: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        nonisolated(unsafe) let box = source
        return await play(
            buffer,
            localGain: localGain,
            deliverFrame: { samples, count in
                box.deliverPCMInt16(
                    samples,
                    frameCount: count,
                    sampleRate: Int32(targetSampleRate),
                    channels: Int(targetChannels)
                )
            },
            canContinue: canContinue
        )
    }

    static func convertTo48kMonoInt16(_ buffer: AVAudioPCMBuffer) -> [Int16]? {
        guard buffer.frameLength > 0,
              buffer.format.sampleRate > 0,
              buffer.format.channelCount > 0 else { return nil }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: true
        ) else { return nil }

        if buffer.format == targetFormat, let channelData = buffer.int16ChannelData {
            let count = Int(buffer.frameLength)
            return Array(UnsafeBufferPointer(start: channelData[0], count: count))
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else { return nil }
        converter.primeMethod = .none
        let ratio = targetSampleRate / buffer.format.sampleRate
        let estimatedFrames = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 128
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(256, estimatedFrames)) else {
            return nil
        }

        final class InputState: @unchecked Sendable {
            var fed = false
            let buffer: AVAudioPCMBuffer
            init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        }
        let inputState = InputState(buffer)
        var conversionError: NSError?
        var samples = [Int16]()
        samples.reserveCapacity(Int(estimatedFrames))

        while true {
            converted.frameLength = 0
            let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
                if !inputState.fed {
                    inputState.fed = true
                    outStatus.pointee = .haveData
                    return inputState.buffer
                }
                outStatus.pointee = .endOfStream
                return nil
            }
            if converted.frameLength > 0, let channelData = converted.int16ChannelData {
                let count = Int(converted.frameLength)
                samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: count))
            }
            if status == .endOfStream || status == .error || status == .inputRanDry {
                break
            }
        }
        return samples.isEmpty ? nil : samples
    }
}

extension GuestAudioProfile {
    var rtcProcessingOptions: LKRTCAudioProcessingOptions {
        let speech = self == .speech
        return LKRTCAudioProcessingOptions(
            echoCancellationOptions: LKRTCAudioProcessingComponentOptions(
                enabled: true,
                mode: speech ? .automatic : .software
            ),
            noiseSuppressionOptions: LKRTCAudioProcessingComponentOptions(enabled: speech),
            autoGainControlOptions: LKRTCAudioProcessingComponentOptions(enabled: speech),
            highPassFilterOptions: LKRTCAudioProcessingComponentOptions(enabled: true)
        )
    }
}
