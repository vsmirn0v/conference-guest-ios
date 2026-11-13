import AVFoundation
import Foundation

/// One microphone move between meetings, as logged for diagnostics
/// (`talk-handover`). Steps come from the target engine: permission,
/// activation, then the service's step (Guest `unmuteConfirmation`,
/// Telemost/TrueConf `renegotiation`).
struct TalkHandoverRecord: Equatable {
    var from: String?
    var to: String
    var releaseMilliseconds: Double?
    var assumeMilliseconds: Double?
    var totalMilliseconds: Double
    var steps: [String: Double]
    var keptWarm: Bool
    var live: Bool

    var fields: [String: Any] {
        var value: [String: Any] = ["to": to, "totalMs": Self.round(totalMilliseconds), "keptWarm": keptWarm, "live": live,
                                    "steps": steps.mapValues(Self.round)]
        if let from { value["from"] = from }
        if let releaseMilliseconds { value["releaseMs"] = Self.round(releaseMilliseconds) }
        if let assumeMilliseconds { value["assumeMs"] = Self.round(assumeMilliseconds) }
        return value
    }
    private static func round(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}

/// A spoken test clip from the macOS system voice, for trying voice replies
/// before any voice model is installed.
enum VoiceReplySample {
    /// The system reports the end of synthesis only with an empty buffer; when a voice
    /// asset is missing or Personal Voice access is withdrawn mid-way it may never send
    /// one, so the wait ends after `timeout` with nothing (a card would otherwise stay
    /// "speaking" forever).
    @MainActor static func make(text: String, language: String = Locale.preferredLanguages.first ?? "en-US",
                     voice: AVSpeechSynthesisVoice? = nil, timeout: TimeInterval = 30) async -> AVAudioPCMBuffer? {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice ?? AVSpeechSynthesisVoice(language: language) ?? AVSpeechSynthesisVoice(language: "en-US")
        let synthesizer = AVSpeechSynthesizer()
        let collected = Collected()
        return await bounded(timeout: timeout, cancel: { synthesizer.stopSpeaking(at: .immediate) }) { finish in
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { finish(collected.joined()); _ = synthesizer; return }
                collected.append(pcm)
            }
        }
    }

    /// Runs `start`, which calls `finish` once with the result; nil after `timeout`.
    @MainActor static func bounded(timeout: TimeInterval, cancel: @escaping @MainActor () -> Void = {},
                        _ start: (@escaping (AVAudioPCMBuffer?) -> Void) -> Void) async -> AVAudioPCMBuffer? {
        let once = Once()
        guard !Task.isCancelled, timeout.isFinite, timeout > 0 else { return nil }
        let timer = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(timeout))
                if once.resume(nil) { cancel() }
            } catch {}
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                once.continuation = continuation
                start { once.resume($0) }
            }
        } onCancel: {
            Task { @MainActor in
                if once.resume(nil) { cancel() }
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        var continuation: CheckedContinuation<AVAudioPCMBuffer?, Never>?
        @discardableResult func resume(_ value: AVAudioPCMBuffer?) -> Bool {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            pending?.resume(returning: value)
            return pending != nil
        }
    }

    private final class Collected: @unchecked Sendable {
        private var buffers: [AVAudioPCMBuffer] = []
        private let lock = NSLock()
        func append(_ buffer: AVAudioPCMBuffer) {
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for (from, to) in zip(source, target) {
                guard let input = from.mData, let output = to.mData else { continue }
                memcpy(output, input, Int(min(from.mDataByteSize, to.mDataByteSize)))
            }
            lock.lock(); buffers.append(copy); lock.unlock()
        }
        /// One buffer in the first buffer's format; nil when nothing was spoken.
        func joined() -> AVAudioPCMBuffer? {
            lock.lock(); defer { lock.unlock() }
            guard let first = buffers.first else { return nil }
            let total = buffers.filter { $0.format == first.format }.reduce(0) { $0 + Int($1.frameLength) }
            guard let output = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: AVAudioFrameCount(total)) else { return nil }
            let frameBytes = Int(first.format.streamDescription.pointee.mBytesPerFrame)
            for buffer in buffers where buffer.format == first.format {
                let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                let target = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
                for (from, to) in zip(source, target) {
                    guard let input = from.mData, let base = to.mData else { continue }
                    memcpy(base.advanced(by: Int(output.frameLength) * frameBytes), input, Int(buffer.frameLength) * frameBytes)
                }
                output.frameLength += buffer.frameLength
            }
            return output
        }
    }
}
