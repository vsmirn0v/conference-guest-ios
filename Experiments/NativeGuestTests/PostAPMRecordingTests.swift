import Foundation

@main struct PostAPMRecordingTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool) { precondition(condition()); checks += 1 }
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("post-apm-recording-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tap = GuestPostAPMDiagnosticTap(); tap.markAttached(true); tap.initialize(sampleRate: 48_000, channels: 2)
        let first = tap.begin(maximumSeconds: 1, maximumBytes: 10_000)!
        var left = (0..<480).map { Float([-32_768, -16_384, 0, 16_384, 32_767][$0 % 5]) }
        let original = left.map(\.bitPattern), right = [Float](repeating: -8_192, count: 480)
        left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in
            tap.process(frames: 480, channels: 2) { $0 == 0 ? l.baseAddress! : r.baseAddress! }
        } }
        check(left.map(\.bitPattern) == original)
        check(tap.end(first)); check(!tap.end(first))
        let url = directory.appendingPathComponent("scale.wav"), result = try await first.finish(to: url)
        let data = try Data(contentsOf: url)
        check(text(data, 0, 4) == "RIFF" && Int(u32(data, 4)) + 8 == data.count)
        check(text(data, 8, 4) == "WAVE" && text(data, 12, 4) == "fmt ")
        check(u16(data, 22) == 2 && u32(data, 24) == 48_000 && u16(data, 34) == 16)
        check(u32(data, 40) == 1_920)
        for f in 0..<480 {
            check(Int16(bitPattern: u16(data, 44 + f * 4)) == Int16(left[f]))
            check(Int16(bitPattern: u16(data, 46 + f * 4)) == -8_192)
        }
        check(Double(Int16(bitPattern: u16(data, 44))) / 32_768 == -1)
        check(Double(Int16(bitPattern: u16(data, 48))) / 32_768 == -0.5)
        check(Double(Int16(bitPattern: u16(data, 56))) / 32_768 == 0.5)
        check(Double(Int16(bitPattern: u16(data, 60))) / 32_768 == 32_767.0 / 32_768)
        let rows = timeline(data)
        check(rows.count == 1 && rows[0].sequence == 1 && rows[0].offset == 0 && rows[0].frames == 480)
        check(rows[0].time > 0 && rows[0].reserved == 0)
        check(result["quantitativeEligible"] as? Bool == true)
        check(result["SDKAdapterAllocatesBufferWrapper"] as? Bool == true)
        check(result["writtenBytes"] as? Int == data.count && data.count <= 10_044)
        let metadataBytes = try JSONSerialization.data(withJSONObject: result)
        check(metadataBytes.count < 8_192)
        do { _ = try await first.finish(to: url); preconditionFailure("repeat finish") }
        catch GuestPostAPMTestError.recordingFinished { checks += 1 }

        let empty = tap.begin(maximumSeconds: 1, maximumBytes: 10_000)!
        do { _ = try await empty.finish(to: directory.appendingPathComponent("open.wav")); preconditionFailure("finish open") }
        catch GuestPostAPMTestError.recordingNotClosed { checks += 1 }
        check(tap.end(empty))
        let emptyEvidence = try await empty.finish(to: directory.appendingPathComponent("empty.wav"))
        check(emptyEvidence["quantitativeEligible"] as? Bool == false)

        for (name, values, expectedInvalid, expectedClipped) in [
            ("nonfinite", [Float.nan, Float.infinity], 2, 0),
            ("clipped", [Float(32_768), Float(-32_769)], 0, 2)] {
            let rec = GuestPostAPMTestRecording(sampleRate: 48_000, channels: 1, initialization: 1, maximumBytes: 4_000)!
            left = [Float](repeating: 0, count: 480); left[0] = values[0]; left[1] = values[1]
            left.withUnsafeBufferPointer { b in rec.append(sampleRate: 48_000, channels: 1, initialization: 1,
                sequence: 1, uptime: rec.beganUptime, frames: 480) { _ in b.baseAddress! } }
            rec.close(initialization: 1, releases: 0, tapDrops: 0)
            let evidence = try await rec.finish(to: directory.appendingPathComponent(name + ".wav"))
            check(evidence["invalidSamples"] as? Int == expectedInvalid && evidence["clippedSamples"] as? Int == expectedClipped)
            check(evidence["quantitativeEligible"] as? Bool == false)
        }
        for mode in ["shape", "format", "initialize", "sequence", "gap", "time"] {
            let rec = GuestPostAPMTestRecording(sampleRate: 48_000, channels: 1, initialization: 1, maximumBytes: 8_000)!
            let zeros = [Float](repeating: 0, count: 1_921)
            zeros.withUnsafeBufferPointer { b in
                rec.append(sampleRate: 48_000, channels: 1, initialization: 1, sequence: 1, uptime: rec.beganUptime, frames: 480) { _ in b.baseAddress! }
                rec.append(sampleRate: mode == "format" ? 32_000 : 48_000, channels: 1,
                    initialization: mode == "initialize" ? 2 : 1, sequence: mode == "sequence" ? 3 : 2,
                    uptime: mode == "time" ? .nan : rec.beganUptime + (mode == "gap" ? 0.06 : 0.01), frames: mode == "shape" ? 1_921 : 480) { _ in
                    precondition(mode != "shape" && mode != "format" && mode != "initialize" && mode != "time")
                    return b.baseAddress!
                }
            }
            rec.close(initialization: 1, releases: 0, tapDrops: 0)
            let evidence = try await rec.finish(to: directory.appendingPathComponent(mode + ".wav"))
            check(evidence["quantitativeEligible"] as? Bool == false)
        }
        let capped = GuestPostAPMTestRecording(sampleRate: 48_000, channels: 1, initialization: 1, maximumBytes: 1_016)!
        let zero = [Float](repeating: 0, count: 480)
        zero.withUnsafeBufferPointer { b in
            for i in 1...2 { capped.append(sampleRate: 48_000, channels: 1, initialization: 1,
                sequence: Int64(i), uptime: capped.beganUptime + Double(i) / 100, frames: 480) { _ in b.baseAddress! } }
        }
        capped.close(initialization: 1, releases: 0, tapDrops: 0)
        let cappedURL = directory.appendingPathComponent("cap.wav"), cap = try await capped.finish(to: cappedURL)
        check(cap["capReached"] as? Bool == true && cap["capDroppedFrames"] as? Int == 480)
        let capData = try Data(contentsOf: cappedURL)
        check(cap["quantitativeEligible"] as? Bool == false && timeline(capData).count == 1)
        check(GuestPostAPMTestRecording(sampleRate: Int.max, channels: 1, initialization: 1) == nil)
        check(GuestPostAPMTestRecording(sampleRate: 48_000, channels: 3, initialization: 1) == nil)
        check(GuestPostAPMTestRecording(sampleRate: 48_000, channels: 1, initialization: 1, maximumSeconds: .nan) == nil)
        check(GuestPostAPMTestRecording(sampleRate: 48_000, channels: 1, initialization: 1, maximumBytes: 1) == nil)

        for mode in ["leading", "trailing", "closeBeforeLast", "nonfiniteClose", "complete"] {
            let rec = GuestPostAPMTestRecording(sampleRate: 48_000, channels: 1, initialization: 1, maximumBytes: 4_000)!
            let first = rec.beganUptime + (mode == "leading" ? 0.06 : 0.01)
            zero.withUnsafeBufferPointer { b in rec.append(sampleRate: 48_000, channels: 1, initialization: 1,
                sequence: 1, uptime: first, frames: 480) { _ in b.baseAddress! } }
            let close = mode == "nonfiniteClose" ? Double.nan :
                rec.beganUptime + (mode == "closeBeforeLast" ? 0.005 : mode == "complete" ? 0.02 : 0.07)
            rec.close(initialization: 1, releases: 0, tapDrops: 0, uptime: close)
            let evidence = try await rec.finish(to: directory.appendingPathComponent(mode + ".wav"))
            check(evidence["quantitativeEligible"] as? Bool == (mode == "complete"))
            check(evidence["boundaryGapsQualified"] as? Bool == (mode == "complete"))
            if mode == "leading" { check((evidence["firstCallbackDelaySeconds"] as? Double ?? 0) > 0.05) }
            if mode == "trailing" { check((evidence["lastCallbackToCloseGapSeconds"] as? Double ?? 0) > 0.05) }
            if mode == "closeBeforeLast" || mode == "nonfiniteClose" { check(evidence["invalidCallbackTime"] as? Bool == true) }
            _ = try JSONSerialization.data(withJSONObject: evidence)
        }

        // The exact production tap holds admission across the copy. End cannot
        // return while an admitted callback still accesses the phase's memory.
        let heldTap = GuestPostAPMDiagnosticTap(); heldTap.markAttached(true); heldTap.initialize(sampleRate: 48_000, channels: 1)
        let held = heldTap.begin(maximumSeconds: 1, maximumBytes: 8_000)!
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), callbackDone = DispatchSemaphore(value: 0)
        let ended = LockedBool()
        DispatchQueue.global().async {
            zero.withUnsafeBufferPointer { b in heldTap.process(frames: 480, channels: 1) { _ in
                entered.signal(); release.wait(); return b.baseAddress!
            } }
            callbackDone.signal()
        }
        await wait(entered)
        DispatchQueue.global().async { ended.set(heldTap.end(held)) }
        try await Task.sleep(nanoseconds: 20_000_000); check(!ended.get())
        // Contention is rejected without reading the supplied source pointer.
        heldTap.process(frames: 480, channels: 1) { _ in preconditionFailure("contended source access") }
        release.signal(); await wait(callbackDone)
        for _ in 0..<100 where !ended.get() { try await Task.sleep(nanoseconds: 1_000_000) }
        check(ended.get())
        let heldEvidence = try await held.finish(to: directory.appendingPathComponent("held.wav"))
        check(heldEvidence["callbacks"] as? Int == 1 && heldEvidence["tapContentionDroppedCallbacks"] as? Int64 == 1)
        check(heldEvidence["quantitativeEligible"] as? Bool == false)
        let next = heldTap.begin(maximumSeconds: 1, maximumBytes: 8_000)!
        check(!heldTap.end(held)) // Old completion cannot detach a newer phase.
        zero.withUnsafeBufferPointer { b in heldTap.process(frames: 480, channels: 1) { _ in b.baseAddress! } }
        check(heldTap.end(next))
        let nextURL = directory.appendingPathComponent("next.wav"), nextEvidence = try await next.finish(to: nextURL)
        check(nextEvidence["callbacks"] as? Int == 1 && nextEvidence["quantitativeEligible"] as? Bool == true)
        let nextData = try Data(contentsOf: nextURL)
        check(timeline(nextData).first?.sequence == 3)
        heldTap.process(frames: 480, channels: 1) { _ in preconditionFailure("closed phase source access") }

        // Maximum retained duration includes all timing rows without overflowing
        // either RIFF's checked sizes or the existing typed export's byte cap.
        let maximum = GuestPostAPMTestRecording(sampleRate: 48_000, channels: 1, initialization: 1)!
        zero.withUnsafeBufferPointer { b in
            for i in 0..<12_000 { maximum.append(sampleRate: 48_000, channels: 1, initialization: 1,
                sequence: Int64(i + 1), uptime: maximum.beganUptime + Double(i) / 100, frames: 480) { _ in b.baseAddress! } }
        }
        maximum.close(initialization: 1, releases: 0, tapDrops: 0, uptime: maximum.beganUptime + 120)
        let maxURL = directory.appendingPathComponent("maximum.wav"), maxEvidence = try await maximum.finish(to: maxURL)
        let maxData = try Data(contentsOf: maxURL), maxRows = timeline(maxData)
        check(maxData.count <= 12_000_044 && maxRows.count == 12_000)
        check(maxEvidence["quantitativeEligible"] as? Bool == true)
        check(maxRows.enumerated().allSatisfy { $0.element.sequence == UInt64($0.offset + 1) &&
            $0.element.offset == UInt64($0.offset * 480) && $0.element.frames == 480 && $0.element.reserved == 0 })
        check(zip(maxRows, maxRows.dropFirst()).allSatisfy { pair in pair.0.time < pair.1.time })
        let maximumMetadataBytes = try JSONSerialization.data(withJSONObject: maxEvidence)
        check(maximumMetadataBytes.count < 8_192)
        print("PASS: \(checks) post-APM FloatS16/PCM/timeline/shape/cap/format/privacy-neutral collector and drain checks")
    }
    struct Row { var sequence: UInt64, offset: UInt64, time: UInt64; var frames: UInt32, reserved: UInt32 }
    static func wait(_ semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { semaphore.wait(); continuation.resume() }
        }
    }
    static func text(_ data: Data, _ offset: Int, _ count: Int) -> String { String(decoding: data[offset..<(offset + count)], as: UTF8.self) }
    static func u16(_ data: Data, _ offset: Int) -> UInt16 { UInt16(data[offset]) | UInt16(data[offset + 1]) << 8 }
    static func u32(_ data: Data, _ offset: Int) -> UInt32 { UInt32(u16(data, offset)) | UInt32(u16(data, offset + 2)) << 16 }
    static func u64(_ data: Data, _ offset: Int) -> UInt64 { UInt64(u32(data, offset)) | UInt64(u32(data, offset + 4)) << 32 }
    static func timeline(_ data: Data) -> [Row] {
        let offset = 44 + Int(u32(data, 40)), bytes = Int(u32(data, offset + 4)), count = Int(u32(data, offset + 12))
        precondition(text(data, offset, 4) == "ctim" && u32(data, offset + 8) == 1)
        precondition(bytes == 8 + count * 32 && offset + 8 + bytes == data.count)
        return (0..<count).map { i in
            let start = offset + 16 + i * 32
            return Row(sequence: u64(data, start), offset: u64(data, start + 8), time: u64(data, start + 16),
                       frames: u32(data, start + 24), reserved: u32(data, start + 28))
        }
    }
    final class LockedBool: @unchecked Sendable {
        private let lock = NSLock(); private var value = false
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ value: Bool) { lock.lock(); self.value = value; lock.unlock() }
    }
}
