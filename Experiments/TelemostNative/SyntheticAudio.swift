import AudioToolbox
import Foundation
import LiveKitWebRTC

/// Test-only ADM: generates a tone and measures decoded PCM; never opens a microphone.
final class SyntheticAudio: NSObject, LKRTCAudioDevice, @unchecked Sendable {
    let deviceInputSampleRate = 48_000.0
    let deviceOutputSampleRate = 48_000.0
    let inputIOBufferDuration = 0.01
    let outputIOBufferDuration = 0.01
    let inputNumberOfChannels = 1
    let outputNumberOfChannels = 1
    let inputLatency = 0.0
    let outputLatency = 0.0
    private(set) var isInitialized = false
    private(set) var isPlayoutInitialized = false
    private(set) var isRecordingInitialized = false
    private(set) var isPlaying = false
    private(set) var isRecording = false
    private var delegate: LKRTCAudioDeviceDelegate?
    private var worker: Thread?
    private let lock = NSLock()
    private var stopped = false
    private var sampleCount = 0
    private var sumSquares = 0.0

    func initialize(with delegate: LKRTCAudioDeviceDelegate) -> Bool {
        self.delegate = delegate; isInitialized = true; stopped = false
        let worker = Thread { [weak self] in self?.process() }
        worker.name = "Telemost synthetic audio"; self.worker = worker; worker.start()
        return true
    }
    func terminateDevice() -> Bool {
        lock.lock(); stopped = true; lock.unlock()
        while worker?.isFinished == false { Thread.sleep(forTimeInterval: 0.001) }
        delegate = nil; worker = nil; isInitialized = false
        return true
    }
    func initializePlayout() -> Bool { isPlayoutInitialized = true; return true }
    func initializeRecording() -> Bool { isRecordingInitialized = true; return true }
    func startPlayout() -> Bool { lock.lock(); isPlaying = true; lock.unlock(); return true }
    func stopPlayout() -> Bool { lock.lock(); isPlaying = false; lock.unlock(); return true }
    func startRecording() -> Bool { lock.lock(); isRecording = true; lock.unlock(); return true }
    func stopRecording() -> Bool { lock.lock(); isRecording = false; lock.unlock(); return true }
    var receivedRMS: Double {
        lock.lock(); defer { lock.unlock() }
        return sampleCount > 0 ? sqrt(sumSquares / Double(sampleCount)) : 0
    }
    func report() {
        lock.lock(); let samples = sampleCount; let power = sumSquares; lock.unlock()
        probeLog("decoded-pcm", ["samples": samples, "rms": samples > 0 ? sqrt(power / Double(samples)) : 0])
    }
    private func process() {
        var sampleIndex = 0
        var input = [Int16](repeating: 0, count: 480)
        var output = [Int16](repeating: 0, count: 480)
        var deadline = ProcessInfo.processInfo.systemUptime
        while true {
            lock.lock(); let stop = stopped; let play = isPlaying; let record = isRecording; lock.unlock()
            if stop { return }
            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp(); timestamp.mSampleTime = Double(sampleIndex); timestamp.mFlags = .sampleTimeValid
            if record {
                for i in input.indices { input[i] = Int16(3_000 * sin(Double(sampleIndex + i) * 2 * .pi * 440 / 48_000)) }
                input.withUnsafeMutableBytes { bytes in
                    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 960, mData: bytes.baseAddress))
                    _ = delegate?.deliverRecordedData(&flags, &timestamp, 0, 480, &list, nil, nil)
                }
            }
            if play {
                output.withUnsafeMutableBytes { bytes in
                    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 960, mData: bytes.baseAddress))
                    _ = delegate?.getPlayoutData(&flags, &timestamp, 0, 480, &list)
                }
                let energy = output.reduce(0.0) { $0 + pow(Double($1) / 32768, 2) }
                lock.lock(); sampleCount += output.count; sumSquares += energy; lock.unlock()
            }
            sampleIndex += 480; deadline += 0.01
            Thread.sleep(forTimeInterval: max(0.001, deadline - ProcessInfo.processInfo.systemUptime))
        }
    }
}
