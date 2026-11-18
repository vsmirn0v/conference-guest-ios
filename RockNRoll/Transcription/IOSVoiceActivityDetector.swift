import Accelerate
import Foundation

/// Pure-Swift energy & adaptive-noise-floor voice activity detector operating on 16 kHz mono PCM floats.
final class IOSVoiceActivityDetector {
    struct Configuration {
        let sampleRate: Int
        let frameSamples: Int
        let startMultiplier: Float
        let continueMultiplier: Float
        let minSpeechFloorRMS: Float
        let hangoverFrames: Int
        let minSpeechFrames: Int
        let maxSegmentFrames: Int
        let leadInFrames: Int

        static let `default` = Configuration(
            sampleRate: 16_000,
            frameSamples: 320, // 20 ms
            startMultiplier: 3.0,
            continueMultiplier: 1.8,
            minSpeechFloorRMS: 0.008,
            hangoverFrames: 25, // 500 ms
            minSpeechFrames: 12, // 240 ms
            maxSegmentFrames: 1_200, // 24 s (safely inside 30 s CoreML window)
            leadInFrames: 10 // 200 ms pre-roll
        )
    }

    struct CompletedSegment: Equatable {
        let samples: [Float]
    }

    private let config: Configuration
    private var residual: [Float] = []
    private var ringPreRoll: [[Float]] = []
    private var activeFrames: [[Float]] = []
    private var active = false
    private var silenceFrames = 0
    private var noiseFloorRMS: Float

    var isSpeechActive: Bool { active }
    var currentSegmentDurationSeconds: TimeInterval {
        Double(activeFrames.count * config.frameSamples) / Double(config.sampleRate)
    }

    init(configuration: Configuration = .default) {
        self.config = configuration
        self.noiseFloorRMS = configuration.minSpeechFloorRMS * 0.5
    }

    func append(_ samples16k: [Float]) -> [CompletedSegment] {
        guard !samples16k.isEmpty else { return [] }
        residual.append(contentsOf: samples16k)

        var completed: [CompletedSegment] = []
        var offset = 0
        while offset + config.frameSamples <= residual.count {
            let frame = Array(residual[offset..<(offset + config.frameSamples)])
            offset += config.frameSamples
            if let finished = processFrame(frame) {
                completed.append(finished)
            }
        }
        if offset > 0 {
            residual.removeFirst(offset)
        }
        return completed
    }

    func snapshotActiveSamples() -> [Float]? {
        guard active, activeFrames.count >= config.minSpeechFrames else { return nil }
        return activeFrames.flatMap { $0 }
    }

    func flush() -> [CompletedSegment] {
        var segments: [CompletedSegment] = []
        if !residual.isEmpty {
            var padded = residual
            if padded.count < config.frameSamples {
                padded.append(contentsOf: [Float](repeating: 0, count: config.frameSamples - padded.count))
            }
            residual.removeAll()
            if active {
                activeFrames.append(padded)
            }
        }
        if active, activeFrames.count >= config.minSpeechFrames {
            segments.append(CompletedSegment(samples: activeFrames.flatMap { $0 }))
        }
        resetState()
        return segments
    }

    func resetState() {
        residual.removeAll()
        ringPreRoll.removeAll()
        activeFrames.removeAll()
        active = false
        silenceFrames = 0
    }

    private func processFrame(_ frame: [Float]) -> CompletedSegment? {
        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frame.count))

        let startThreshold = max(config.minSpeechFloorRMS, noiseFloorRMS * config.startMultiplier)
        let continueThreshold = max(config.minSpeechFloorRMS * 0.6, noiseFloorRMS * config.continueMultiplier)

        if !active {
            ringPreRoll.append(frame)
            if ringPreRoll.count > config.leadInFrames {
                ringPreRoll.removeFirst(ringPreRoll.count - config.leadInFrames)
            }
            if rms >= startThreshold {
                active = true
                silenceFrames = 0
                activeFrames = ringPreRoll
                ringPreRoll.removeAll()
            } else {
                // Track ambient background slowly while silent.
                noiseFloorRMS = 0.96 * noiseFloorRMS + 0.04 * min(rms, config.minSpeechFloorRMS * 3)
            }
            return nil
        }

        activeFrames.append(frame)
        if rms >= continueThreshold {
            silenceFrames = 0
        } else {
            silenceFrames += 1
        }

        if activeFrames.count >= config.maxSegmentFrames || silenceFrames >= config.hangoverFrames {
            defer {
                active = false
                silenceFrames = 0
                activeFrames.removeAll()
            }
            let trimSilence = min(silenceFrames, max(0, activeFrames.count - config.minSpeechFrames))
            let voicedCount = activeFrames.count - trimSilence
            guard voicedCount >= config.minSpeechFrames else { return nil }
            return CompletedSegment(samples: activeFrames.prefix(activeFrames.count - max(0, trimSilence - 4)).flatMap { $0 })
        }
        return nil
    }
}
