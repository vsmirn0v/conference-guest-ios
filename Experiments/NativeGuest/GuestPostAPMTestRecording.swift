#if DEBUG
import Darwin
import Foundation

enum GuestPostAPMTestError: Error { case recordingNotClosed, recordingFinished }

/// Diagnostic PCM only. The callback copies float-S16 without changing its source.
/// Disk I/O and timeline dictionaries are created only after collector admission drains.
final class GuestPostAPMTestRecording: @unchecked Sendable {
    private struct Block {
        var sequence: Int64 = 0
        var frameOffset = 0, frames = 0
        var uptime = 0.0
    }
    private let lock = NSLock()
    private let pcm: UnsafeMutablePointer<Int16>
    private let blocks: UnsafeMutablePointer<Block>
    private let sampleCapacity: Int, blockCapacity: Int, frameLimit: Int
    private let rate: Int, channels: Int, initialization: Int64, releases: Int64, tapDrops: Int64
    private var active = true, closed = false, finished = false
    private var frames = 0, callbacks = 0, rejected = 0, invalid = 0, clipped = 0
    private var capDroppedFrames = 0, capDroppedCallbacks = 0
    private var capReached = false, formatChanged = false, invalidTime = false, sequenceGap = false
    private var firstUptime: Double?, lastUptime: Double?, maximumGap = 0.0, endedUptime = 0.0
    private var armUptime = 0.0
    private var lastSequence: Int64?, finalTapDrops: Int64 = 0
    private var contentionDrops: Int64 = 0
    let beganUptime = ProcessInfo.processInfo.systemUptime
    static let maximumEligibleCallbackGapSeconds = 0.05

    init?(sampleRate: Int, channels: Int, initialization: Int64, releases: Int64 = 0, tapDrops: Int64 = 0,
          maximumSeconds: Double = 120, maximumBytes: Int = 12_000_000) {
        guard (8_000...192_000).contains(sampleRate), sampleRate % 100 == 0, (1...2).contains(channels),
              maximumSeconds.isFinite, maximumSeconds > 0, maximumSeconds <= 120, maximumBytes >= 2 * channels else { return nil }
        self.rate = sampleRate; self.channels = channels; self.initialization = initialization
        self.releases = releases; self.tapDrops = tapDrops
        // Budget includes the entire fixed-width timing chunk as well as PCM.
        // RIFF/fmt/data contribute another 44 bytes, so exports are <=12,000,044.
        let budget = min(12_000_000, maximumBytes)
        let bytesPerBlock = sampleRate / 100 * channels * 2 + 32
        guard budget >= 16 + bytesPerBlock else { return nil }
        blockCapacity = min(12_000, max(1, Int((maximumSeconds * 100).rounded(.up))), (budget - 16) / bytesPerBlock)
        sampleCapacity = (budget - 16 - blockCapacity * 32) / 2
        frameLimit = min(sampleCapacity / channels, Int(Double(sampleRate) * maximumSeconds))
        pcm = .allocate(capacity: sampleCapacity); pcm.initialize(repeating: 0, count: sampleCapacity)
        blocks = .allocate(capacity: blockCapacity); blocks.initialize(repeating: Block(), count: blockCapacity)
        armUptime = beganUptime
    }
    deinit {
        pcm.deinitialize(count: sampleCapacity); pcm.deallocate()
        blocks.deinitialize(count: blockCapacity); blocks.deallocate()
    }

    func append(sampleRate: Int, channels: Int, initialization: Int64, sequence: Int64, uptime: Double,
                frames count: Int, channel: (Int) -> UnsafePointer<Float>) {
        guard lock.try() else { OSAtomicIncrement64Barrier(&contentionDrops); return }
        defer { lock.unlock() }
        guard active else { return }
        guard sampleRate == rate, channels == self.channels, initialization == self.initialization else {
            formatChanged = true; rejected += 1; return
        }
        guard count == rate / 100, count > 0, count <= 1_920 else { rejected += 1; return }
        guard sequence > 0, uptime.isFinite, uptime >= armUptime, uptime < Double(UInt64.max / 1_000_000_000),
              lastUptime.map({ uptime >= $0 }) ?? true else {
            invalidTime = true; rejected += 1; return
        }
        guard callbacks < blockCapacity, count <= frameLimit - frames else {
            capReached = true; capDroppedFrames += count; capDroppedCallbacks += 1; return
        }
        // The source has been shape-checked before asking for any channel pointer.
        var invalidBlock = false
        for c in 0..<channels {
            let source = channel(c)
            for f in 0..<count {
                let value = source[f]
                if !value.isFinite { invalid += 1; invalidBlock = true; continue }
                if value < -32_768 || value > 32_767 { clipped += 1 }
                pcm[(frames + f) * channels + c] = Int16(max(-32_768, min(32_767, value.rounded())))
            }
        }
        guard !invalidBlock else { rejected += 1; return }
        if let lastUptime { maximumGap = max(maximumGap, uptime - lastUptime) }
        if let lastSequence, lastSequence == Int64.max || sequence != lastSequence + 1 { sequenceGap = true }
        blocks[callbacks] = Block(sequence: sequence, frameOffset: frames, frames: count, uptime: uptime)
        frames += count; callbacks += 1
        firstUptime = firstUptime ?? uptime; lastUptime = uptime; lastSequence = sequence
    }

    func arm(at uptime: Double) {
        lock.lock(); defer { lock.unlock() }
        guard active && callbacks == 0 else { return }
        guard uptime.isFinite, uptime >= beganUptime else { invalidTime = true; return }
        armUptime = uptime
    }
    /// Called after the tap has removed this recording under its own callback lock.
    func close(initialization: Int64, releases: Int64, tapDrops: Int64,
               uptime: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        active = false; closed = true; endedUptime = uptime.isFinite ? uptime : 0
        invalidTime = invalidTime || !uptime.isFinite || !armUptime.isFinite || uptime < armUptime ||
            (lastUptime.map({ uptime < $0 }) ?? false)
        formatChanged = formatChanged || initialization != self.initialization || releases != self.releases
        finalTapDrops = max(0, tapDrops - self.tapDrops)
    }

    func finish(to url: URL) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                do {
                    lock.lock()
                    guard closed else { lock.unlock(); throw GuestPostAPMTestError.recordingNotClosed }
                    guard !finished else { lock.unlock(); throw GuestPostAPMTestError.recordingFinished }
                    finished = true
                    let drops = OSAtomicAdd64Barrier(0, &contentionDrops)
                    let firstDelay = firstUptime.map { $0 - armUptime }
                    let trailingGap = lastUptime.map { endedUptime - $0 }
                    let boundaryGapsValid = (firstDelay.map { $0 >= 0 && $0 <= Self.maximumEligibleCallbackGapSeconds } ?? false) &&
                        (trailingGap.map { $0 >= 0 && $0 <= Self.maximumEligibleCallbackGapSeconds } ?? false)
                    let byteCount = frames * channels * 2, timingBytes = 8 + callbacks * 32
                    let totalBytes = 44 + byteCount + 8 + timingBytes
                    guard totalBytes <= 12_000_044, totalBytes - 8 <= Int(UInt32.max) else {
                        lock.unlock(); throw CocoaError(.fileWriteInapplicableStringEncoding)
                    }
                    var result: [String: Any] = ["path": url.path, "frames": frames, "sampleRate": rate,
                        "channels": channels, "sourceChannels": channels, "encoding": "PCM16LE",
                        "sourceEncoding": "deinterleaved float-S16", "sourceFloatScale": 32_768,
                        "callbacks": callbacks, "rejectedCallbacks": rejected, "invalidSamples": invalid,
                        "clippedSamples": clipped, "contentionDroppedCallbacks": drops,
                        "tapContentionDroppedCallbacks": finalTapDrops, "capReached": capReached,
                        "capDroppedFrames": capDroppedFrames, "capDroppedCallbacks": capDroppedCallbacks,
                        "formatChanged": formatChanged, "invalidCallbackTime": invalidTime,
                        "sequenceGap": sequenceGap, "collectorAdmissionClosedAndDrained": closed,
                        "beganUptime": armUptime, "allocatedUptime": beganUptime, "endedUptime": endedUptime,
                        "firstCallbackUptime": firstUptime as Any? ?? NSNull(), "lastCallbackUptime": lastUptime as Any? ?? NSNull(),
                        "firstCallbackDelaySeconds": firstDelay as Any? ?? NSNull(),
                        "lastCallbackToCloseGapSeconds": trailingGap as Any? ?? NSNull(),
                        "boundaryGapsQualified": boundaryGapsValid && !invalidTime,
                        "maximumCallbackGapSeconds": maximumGap,
                        "maximumEligibleCallbackGapSeconds": Self.maximumEligibleCallbackGapSeconds,
                        "PCMSeconds": Double(frames) / Double(rate),
                        "callbackTimeline": ["storage": "RIFF-ctim", "version": 1, "count": callbacks,
                            "chunkOffsetBytes": 44 + byteCount, "payloadOffsetBytes": 52 + byteCount,
                            "entriesOffsetBytes": 60 + byteCount, "entryBytes": 32, "payloadBytes": timingBytes,
                            "fields": ["sequence:u64", "frameOffset:u64", "callbackUptimeNanos:u64", "frames:u32", "reserved:u32"],
                            "endianness": "little", "clock": "ProcessInfo.systemUptime nanoseconds"],
                        "retainedCapacityBytes": sampleCapacity * 2 + blockCapacity * MemoryLayout<Block>.stride,
                        "clock": "ProcessInfo.systemUptime callback receipt; not acoustic sample time",
                        "timeMapping": "WAV data contains accepted PCM blocks; RIFF ctim maps each block to wall-clock receipt; no gap concealment or resampling",
                        "provenance": "custom capture postprocessing after AEC/NS/AGC2/post-filter; before APM post-level adjustment, first-unmuted-frame zeroing and Opus",
                        "SDKAdapterAllocatesBufferWrapper": true, "SDKAdapterSkippedCallbacksDirectlyObservable": false,
                        "quantitativeEligible": frames > 0 && callbacks > 0 && drops == 0 && finalTapDrops == 0 &&
                            rejected == 0 && invalid == 0 && clipped == 0 && !capReached && !formatChanged &&
                            !invalidTime && !sequenceGap && boundaryGapsValid && maximumGap <= Self.maximumEligibleCallbackGapSeconds]
                    lock.unlock()
                    var header = Data("RIFF".utf8)
                    func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { header.append(contentsOf: $0) } }
                    func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { header.append(contentsOf: $0) } }
                    u32(UInt32(totalBytes - 8)); header.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(UInt16(channels))
                    u32(UInt32(rate)); u32(UInt32(rate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
                    header.append(Data("data".utf8)); u32(UInt32(byteCount))
                    guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                    try handle.write(contentsOf: header)
                    for offset in stride(from: 0, to: frames * channels, by: 32_768) {
                        try handle.write(contentsOf: Data(bytes: pcm + offset, count: min(32_768, frames * channels - offset) * 2))
                    }
                    var timing = Data("ctim".utf8)
                    func timing32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { timing.append(contentsOf: $0) } }
                    func timing64(_ value: UInt64) { var value = value.littleEndian; withUnsafeBytes(of: &value) { timing.append(contentsOf: $0) } }
                    timing32(UInt32(timingBytes)); timing32(1); timing32(UInt32(callbacks))
                    for index in 0..<callbacks {
                        let block = blocks[index]
                        timing64(UInt64(block.sequence)); timing64(UInt64(block.frameOffset))
                        timing64(UInt64((block.uptime * 1e9).rounded())); timing32(UInt32(block.frames)); timing32(0)
                    }
                    try handle.write(contentsOf: timing)
                    result["writtenBytes"] = totalBytes
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Retained by GuestSystemAudio. SDK holds this delegate weakly and serializes its
/// setter with Process; per-phase collector admission never changes that setter.
final class GuestPostAPMDiagnosticTap: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var recording: GuestPostAPMTestRecording?
    private var rate = 0, channels = 0, initialized = false, attached = false
    private var initialization: Int64 = 0, releases: Int64 = 0, sequence: Int64 = 0
    private var contentionDrops: Int64 = 0, lifecycleDrops: Int64 = 0

    func markAttached(_ value: Bool) { lock.lock(); attached = value; lock.unlock() }
    func initialize(sampleRate: Int, channels: Int) {
        OSAtomicIncrement64Barrier(&initialization)
        guard lock.try() else { OSAtomicIncrement64Barrier(&lifecycleDrops); return }
        rate = sampleRate; self.channels = channels; initialized = true; lock.unlock()
    }
    func release() {
        OSAtomicIncrement64Barrier(&releases)
        guard lock.try() else { OSAtomicIncrement64Barrier(&lifecycleDrops); return }
        initialized = false; lock.unlock()
    }
    func process(frames: Int, channels: Int, channel: (Int) -> UnsafePointer<Float>) {
        let value = OSAtomicIncrement64Barrier(&sequence)
        guard lock.try() else { OSAtomicIncrement64Barrier(&contentionDrops); return }
        defer { lock.unlock() }
        guard let recording else { return }
        recording.append(sampleRate: rate, channels: channels,
                         initialization: OSAtomicAdd64Barrier(0, &initialization), sequence: value,
                         uptime: ProcessInfo.processInfo.systemUptime, frames: frames, channel: channel)
    }
    func begin(maximumSeconds: Double = 120, maximumBytes: Int = 12_000_000) -> GuestPostAPMTestRecording? {
        lock.lock()
        let expectedRate = rate, expectedChannels = channels, expectedInitialization = OSAtomicAdd64Barrier(0, &initialization)
        let expectedReleases = OSAtomicAdd64Barrier(0, &releases)
        let available = attached && initialized && recording == nil && OSAtomicAdd64Barrier(0, &lifecycleDrops) == 0
        lock.unlock()
        guard available, let next = GuestPostAPMTestRecording(sampleRate: expectedRate, channels: expectedChannels,
            initialization: expectedInitialization, releases: expectedReleases,
            tapDrops: OSAtomicAdd64Barrier(0, &contentionDrops), maximumSeconds: maximumSeconds, maximumBytes: maximumBytes) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard attached && initialized && recording == nil && rate == expectedRate && channels == expectedChannels &&
                OSAtomicAdd64Barrier(0, &initialization) == expectedInitialization &&
                OSAtomicAdd64Barrier(0, &releases) == expectedReleases && OSAtomicAdd64Barrier(0, &lifecycleDrops) == 0 else { return nil }
        next.arm(at: ProcessInfo.processInfo.systemUptime)
        recording = next; return next
    }
    func end(_ value: GuestPostAPMTestRecording) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard recording === value else { return false }
        recording = nil
        value.close(initialization: OSAtomicAdd64Barrier(0, &initialization),
                    releases: OSAtomicAdd64Barrier(0, &releases), tapDrops: OSAtomicAdd64Barrier(0, &contentionDrops))
        return true
    }
    func endCurrent() {
        lock.lock(); defer { lock.unlock() }
        if let recording {
            self.recording = nil
            recording.close(initialization: OSAtomicAdd64Barrier(0, &initialization),
                            releases: OSAtomicAdd64Barrier(0, &releases), tapDrops: OSAtomicAdd64Barrier(0, &contentionDrops))
        }
    }
    var snapshot: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["attached": attached, "initialized": initialized, "sampleRate": rate, "channels": channels,
                "phaseArmed": recording != nil, "initializeCalls": OSAtomicAdd64Barrier(0, &initialization),
                "releaseCalls": OSAtomicAdd64Barrier(0, &releases), "processingCallbacks": OSAtomicAdd64Barrier(0, &sequence),
                "contentionDroppedCallbacks": OSAtomicAdd64Barrier(0, &contentionDrops),
                "lifecycleDroppedCallbacks": OSAtomicAdd64Barrier(0, &lifecycleDrops)]
    }
}

#if ROCK_COREAUDIO_EXPERIMENT && canImport(LiveKitWebRTC)
import LiveKitWebRTC
extension GuestPostAPMDiagnosticTap: LKRTCAudioCustomProcessingDelegate {
    func audioProcessingInitialize(sampleRate: Int, channels: Int) { initialize(sampleRate: sampleRate, channels: channels) }
    func audioProcessingProcess(audioBuffer: LKRTCAudioBuffer) {
        process(frames: audioBuffer.frames, channels: audioBuffer.channels) { UnsafePointer(audioBuffer.rawBuffer(forChannel: $0)) }
    }
    func audioProcessingRelease() { release() }
}
#endif
#endif
