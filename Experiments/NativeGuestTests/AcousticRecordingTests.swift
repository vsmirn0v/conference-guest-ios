@preconcurrency import AVFoundation
import Foundation

@main struct AcousticRecordingTests {
    static func main() async throws {
        var lifetime = GuestAudioTestCaptureLifetime()
        precondition(lifetime.gateStatus(rawValue: 0) == .notApplicable)
        lifetime.beginPrimaryConnect() // Includes a connect that fails before returning an owner.
        precondition(lifetime.gateStatus(rawValue: 0) == .unconfirmed)
        precondition(lifetime.gateStatus(rawValue: 1) == .verifiedMuted)
        lifetime.beginPrimaryConnect() // Reconnect/retirement must never reset ownership history.
        precondition(lifetime.gateStatus(rawValue: 0) == .unconfirmed)
        precondition(lifetime.gateStatus(rawValue: -1) == .unconfirmed)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("acoustic-recording-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for common: AVAudioCommonFormat in [.pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32] {
            for interleaved in [true, false] {
                let recording = GuestAudioTestRecording(maximumSeconds: 1, maximumBytes: 4000)
                recording.append(buffer(common, interleaved: interleaved))
                let url = directory.appendingPathComponent("\(common.rawValue)-\(interleaved).wav")
                let evidence = try await recording.finish(to: url)
                precondition(evidence["frames"] as? Int == 480 && evidence["channels"] as? Int == 1)
                precondition(evidence["sourceChannels"] as? Int == 2 && evidence["quantitativeEligible"] as? Bool == true)
                let speech = try GuestAudioTestSpeech(url: url)
                precondition(speech.samples.count == 480 && speech.samples.allSatisfy { $0 == 4096 })
                precondition((speech.evidence["sha256"] as? String)?.count == 64)
                do { _ = try await recording.finish(to: url); preconditionFailure("Second finalize must fail") }
                catch GuestAudioTestError.recordingFinished {}
            }
        }
        let bounded = GuestAudioTestRecording(maximumSeconds: 120, maximumBytes: 960)
        bounded.append(buffer(.pcmFormatInt16, interleaved: true)); bounded.append(buffer(.pcmFormatInt16, interleaved: true))
        let capped = try await bounded.finish(to: directory.appendingPathComponent("capped.wav"))
        precondition(capped["frames"] as? Int == 480 && capped["writtenBytes"] as? Int == 1004)
        precondition(capped["capReached"] as? Bool == true && capped["quantitativeEligible"] as? Bool == false)
        let changed = GuestAudioTestRecording(maximumBytes: 4000)
        changed.append(buffer(.pcmFormatFloat32, interleaved: false))
        changed.append(buffer(.pcmFormatFloat32, interleaved: false, rate: 44_100))
        let mismatch = try await changed.finish(to: directory.appendingPathComponent("changed.wav"))
        precondition(mismatch["frames"] as? Int == 480 && mismatch["formatChanged"] as? Bool == true)
        precondition(mismatch["rejectedCallbacks"] as? Int == 1 && mismatch["quantitativeEligible"] as? Bool == false)
        let invalid = GuestAudioTestRecording(maximumBytes: 4000), nan = buffer(.pcmFormatFloat32, interleaved: false)
        nan.floatChannelData![0][0] = .nan; invalid.append(nan)
        let nonfinite = try await invalid.finish(to: directory.appendingPathComponent("invalid.wav"))
        precondition(nonfinite["invalidSamples"] as? Int == 1 && nonfinite["quantitativeEligible"] as? Bool == false)
        let empty = GuestAudioTestRecording(maximumBytes: 4000)
        let emptyURL = directory.appendingPathComponent("empty.wav")
        let emptyEvidence = try await empty.finish(to: emptyURL)
        precondition(emptyEvidence["frames"] as? Int == 0 && emptyEvidence["quantitativeEligible"] as? Bool == false)
        do { _ = try GuestAudioTestSpeech(url: emptyURL); preconditionFailure("Empty source must fail") }
        catch GuestAudioTestError.invalidSpeechWAV {}
        let concurrent = GuestAudioTestRecording(maximumBytes: 4000), pcm = buffer(.pcmFormatInt16, interleaved: true)
        DispatchQueue.concurrentPerform(iterations: 32) { _ in concurrent.append(pcm) }
        let contended = try await concurrent.finish(to: directory.appendingPathComponent("concurrent.wav"))
        precondition((contended["frames"] as? Int ?? Int.max) <= 2000)
        precondition(contended["quantitativeEligible"] as? Bool == false)
        print("PASS: bounded diagnostic WAV formats, downmix, source identity, cap, format change, nonfinite rejection, repeat finalize and concurrent append smoke test")
    }
    static func buffer(_ common: AVAudioCommonFormat, interleaved: Bool, rate: Double = 48_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: common, sampleRate: rate, channels: 2, interleaved: interleaved)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!; pcm.frameLength = 480
        for (index, buffer) in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList).enumerated() {
            func fill<T>(_ type: T.Type, _ convert: (Double) -> T) {
                let values = buffer.mData!.assumingMemoryBound(to: T.self)
                for sample in 0..<(Int(buffer.mDataByteSize) / MemoryLayout<T>.size) {
                    let channel = interleaved ? sample % 2 : index
                    values[sample] = convert(channel == 0 ? 0.5 : -0.25)
                }
            }
            switch common {
            case .pcmFormatFloat32: fill(Float.self) { Float($0) }
            case .pcmFormatFloat64: fill(Double.self) { $0 }
            case .pcmFormatInt16: fill(Int16.self) { Int16($0 * 32768) }
            case .pcmFormatInt32: fill(Int32.self) { Int32($0 * 2147483648) }
            default: preconditionFailure()
            }
        }
        return pcm
    }
}
