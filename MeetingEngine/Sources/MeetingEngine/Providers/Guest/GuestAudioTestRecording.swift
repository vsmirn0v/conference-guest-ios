#if DEBUG
import AVFoundation
import CryptoKit
import Darwin
import Foundation

enum GuestAudioTestError: Error { case invalidSpeechWAV, recordingFinished, invalidCommand }

/// Process-lifetime history: a failed or retired connection never erases the
/// obligation to prove its microphone gate closed. A pre-connect network-only
/// failure has no primary capture gate to restore.
struct GuestAudioTestCaptureLifetime {
    enum GateStatus: String { case notApplicable, verifiedMuted, unconfirmed }
    private(set) var primaryConnectAttempted = false
    mutating func beginPrimaryConnect() { primaryConnectAttempted = true }
    func gateStatus(rawValue: Int32) -> GateStatus {
        guard primaryConnectAttempted else { return .notApplicable }
        return rawValue == 1 ? .verifiedMuted : .unconfirmed
    }
}

/// Diagnostic sink only. Retains at most 12 MB of mono Int16 PCM; never performs
/// file I/O or waits for a lock on an audio callback. A lossy record is evidence
/// of missing data, never a quantitative acoustic qualification.
final class GuestAudioTestRecording: @unchecked Sendable {
    private let lock = NSLock()
    private let storage: UnsafeMutablePointer<Int16>
    private let capacity: Int
    private let seconds: Double
    private var active = true, finished = false
    private var frames = 0, callbacks = 0, invalidSamples = 0, clippedSamples = 0
    private var rejectedCallbacks = 0, capReached = false, formatChanged = false
    private var capDroppedFrames = 0, capDroppedCallbacks = 0
    private var sampleRate = 0.0, sourceChannels = 0
    private var firstUptime: Double?, lastUptime: Double?, maximumCallbackGap = 0.0
    private var contentionDrops: Int32 = 0
    let beganUptime = ProcessInfo.processInfo.systemUptime

    init(maximumSeconds: Double = 120, maximumBytes: Int = 12_000_000) {
        seconds = min(120, max(0.01, maximumSeconds.isFinite ? maximumSeconds : 120))
        capacity = min(6_000_000, max(1, maximumBytes / 2))
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }
    deinit { storage.deinitialize(count: capacity); storage.deallocate() }

    func append(_ pcm: AVAudioPCMBuffer) {
        guard lock.try() else {
            OSAtomicIncrement32Barrier(&contentionDrops)
            return
        }
        defer { lock.unlock() }
        guard active else { return }
        let rate = pcm.format.sampleRate, channels = Int(pcm.format.channelCount), count = Int(pcm.frameLength)
        guard (8_000...192_000).contains(rate), (1...8).contains(channels), (1...16_384).contains(count) else {
            rejectedCallbacks += 1; return
        }
        if sampleRate == 0 { sampleRate = rate; sourceChannels = channels }
        guard sampleRate == rate, sourceChannels == channels else { formatChanged = true; rejectedCallbacks += 1; return }
        let limit = min(capacity, Int(rate * seconds))
        let copied = min(count, max(0, limit - frames))
        guard copied > 0 else { capReached = true; capDroppedFrames += count; capDroppedCallbacks += 1; return }
        let buffers = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        let interleaved = pcm.format.isInterleaved
        guard buffers.count == (interleaved ? 1 : channels), buffers.allSatisfy({ $0.mData != nil }) else {
            rejectedCallbacks += 1; return
        }
        func copy<T>(_ type: T.Type, normalize: (T) -> Double) -> Bool {
            guard buffers.enumerated().allSatisfy({ _, buffer in
                Int(buffer.mDataByteSize) >= copied * (interleaved ? channels : 1) * MemoryLayout<T>.size
            }) else { return false }
            for frame in 0..<copied {
                var sum = 0.0
                for channel in 0..<channels {
                    let buffer = buffers[interleaved ? 0 : channel]
                    let value = normalize(buffer.mData!.assumingMemoryBound(to: T.self)[interleaved ? frame * channels + channel : frame])
                    if value.isFinite { sum += value } else { invalidSamples += 1 }
                }
                let value = sum / Double(channels)
                if value < -1 || value > 1 { clippedSamples += 1 }
                storage[frames + frame] = Int16(max(-32768, min(32767, (value * 32768).rounded())))
            }
            return true
        }
        let supported: Bool
        switch pcm.format.commonFormat {
        case .pcmFormatFloat32: supported = copy(Float.self) { Double($0) }
        case .pcmFormatFloat64: supported = copy(Double.self) { $0 }
        case .pcmFormatInt16: supported = copy(Int16.self) { Double($0) / 32768 }
        case .pcmFormatInt32: supported = copy(Int32.self) { Double($0) / 2147483648 }
        default: supported = false
        }
        guard supported else { rejectedCallbacks += 1; return }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastUptime { maximumCallbackGap = max(maximumCallbackGap, now - lastUptime) }
        firstUptime = firstUptime ?? now; lastUptime = now
        frames += copied; callbacks += 1
        if copied < count { capDroppedFrames += count - copied; capDroppedCallbacks += 1 }
        if copied < count || frames == limit { capReached = true }
    }

    func finish(to url: URL) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                do {
                    lock.lock()
                    guard !finished else { lock.unlock(); throw GuestAudioTestError.recordingFinished }
                    active = false; finished = true
                    let count = frames, rate = sampleRate > 0 ? sampleRate : 48_000
                    let drops = OSAtomicAdd32Barrier(0, &contentionDrops)
                    var result: [String: Any] = ["path": url.path, "frames": count, "sampleRate": rate,
                        "channels": 1, "encoding": "PCM16LE", "sourceChannels": sourceChannels,
                        "callbacks": callbacks, "rejectedCallbacks": rejectedCallbacks, "contentionDroppedCallbacks": drops,
                        "capReached": capReached, "formatChanged": formatChanged, "invalidSamples": invalidSamples,
                        "capDroppedFrames": capDroppedFrames, "capDroppedCallbacks": capDroppedCallbacks,
                        "clippedSamples": clippedSamples, "maximumCallbackGapSeconds": maximumCallbackGap,
                        "beganUptime": beganUptime, "firstCallbackUptime": firstUptime as Any? ?? NSNull(),
                        "lastCallbackUptime": lastUptime as Any? ?? NSNull(), "endedUptime": ProcessInfo.processInfo.systemUptime,
                        "PCMSeconds": Double(count) / rate, "retainedCapacityBytes": capacity * 2,
                        "clock": "ProcessInfo.systemUptime; callback receipt, not acoustic sample time",
                        "quantitativeEligible": count > 0 && drops == 0 && rejectedCallbacks == 0 && !capReached && !formatChanged && invalidSamples == 0 && clippedSamples == 0]
                    lock.unlock()
                    // Immutable after active=false; bounded block writes need no full-sized Data copy.
                    var header = Data("RIFF".utf8)
                    func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { header.append(contentsOf: $0) } }
                    func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { header.append(contentsOf: $0) } }
                    u32(UInt32(36 + count * 2)); header.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
                    u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16); header.append(Data("data".utf8)); u32(UInt32(count * 2))
                    guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.write(contentsOf: header)
                    for offset in stride(from: 0, to: count, by: 32_768) {
                        try handle.write(contentsOf: Data(bytes: storage + offset, count: min(32_768, count - offset) * 2))
                    }
                    result["writtenBytes"] = 44 + count * 2
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Formal PCM WAV parser, loaded before publication. No conversion, resampling,
/// or tone fallback can silently change the acoustic test stimulus.
final class GuestAudioTestSpeech: @unchecked Sendable {
    let samples: [Int16]
    let evidence: [String: Any]
    convenience init(url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let bytes = attributes[.size] as? NSNumber, bytes.intValue <= 12_001_024 else { throw GuestAudioTestError.invalidSpeechWAV }
        let data = try Data(contentsOf: url)
        try self.init(data: data, source: url.path)
    }
    init(data: Data, source: String) throws {
        guard data.count <= 12_001_024 else { throw GuestAudioTestError.invalidSpeechWAV }
        func text(_ offset: Int, _ count: Int) -> String { String(decoding: data[offset..<(offset + count)], as: UTF8.self) }
        func u16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        guard data.count >= 44, text(0, 4) == "RIFF", text(8, 4) == "WAVE", u32(4) + 8 == data.count else { throw GuestAudioTestError.invalidSpeechWAV }
        var offset = 12, validFormat = false, pcm: Range<Int>?
        while offset + 8 <= data.count {
            let size = u32(offset + 4), start = offset + 8
            guard size <= data.count - start else { throw GuestAudioTestError.invalidSpeechWAV }
            switch text(offset, 4) {
            case "fmt ":
                guard size >= 16, u16(start) == 1, u16(start + 2) == 1, u32(start + 4) == 48_000,
                      u32(start + 8) == 96_000, u16(start + 12) == 2, u16(start + 14) == 16 else { throw GuestAudioTestError.invalidSpeechWAV }
                validFormat = true
            case "data": guard pcm == nil else { throw GuestAudioTestError.invalidSpeechWAV }; pcm = start..<(start + size)
            default: break
            }
            offset = start + size + size % 2
        }
        guard offset == data.count, validFormat, let pcm, pcm.count >= 960, pcm.count % 2 == 0, pcm.count <= 11_520_000 else { throw GuestAudioTestError.invalidSpeechWAV }
        samples = stride(from: pcm.lowerBound, to: pcm.upperBound, by: 2).map { Int16(bitPattern: UInt16(u16($0))) }
        guard samples.contains(where: { $0 != 0 }) else { throw GuestAudioTestError.invalidSpeechWAV }
        evidence = ["path": source, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "frames": samples.count, "sampleRate": 48_000, "channels": 1, "encoding": "PCM16LE",
            "seconds": Double(samples.count) / 48_000, "looping": true, "silenceUntilCommand": true]
    }
}
#endif
