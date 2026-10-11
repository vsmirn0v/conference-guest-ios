#if DEBUG
import AVFoundation
import ConferenceCore
import LiveKit
import XCTest
@testable import RockNRoll

@MainActor
final class ReceiveRoomVideoTests: XCTestCase {
    func testEncodedRoomVideoRendersWhileMainThreadIsBlocked() async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Background renderer requires iOS 17") }
        guard let url = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_RECEIVE_ROOM_URL"] else { throw XCTSkip("Opt-in anonymous room receive check") }
        let service = JamService(), target = try JamTarget.parse(url)
        let sender = Room(roomOptions: RoomMediaPolicy.options), receiver = Room()
        var feed: Task<Void, Never>?
        let view = CallVideoView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        do {
            let senderName = "Receive rendering sender " + UUID().uuidString.prefix(8)
            let a = try await service.join(target, name: senderName), b = try await service.join(target, name: "Receive rendering receiver")
            try await sender.connect(url: a.serverURL.absoluteString, token: a.participantToken, connectOptions: ConnectOptions(autoSubscribe: false))
            try await receiver.connect(url: b.serverURL.absoluteString, token: b.participantToken)
            let track = await LocalVideoTrack.createBufferTrack(name: "Synthetic receive check", source: .camera,
                options: BufferCaptureOptions(dimensions: .h360_169, fps: 30))
            let capture = try XCTUnwrap(track.capturer as? BufferCapturer)
            var pixels: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixels)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, 96, CVPixelBufferGetBytesPerRow(buffer) * 360) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            feed = Task.detached {
                let clock = ContinuousClock(); var next = clock.now
                while !Task.isCancelled {
                    capture.capture(buffer)
                    next = max(next.advanced(by: .nanoseconds(33_333_333)), clock.now)
                    do { try await Task.sleep(until: next, clock: clock) } catch { return }
                }
            }
            _ = try await sender.localParticipant.publish(videoTrack: track, options: RoomMediaPolicy.videoOptions(preferredCodec: .h264))
            let deadline = Date().addingTimeInterval(12)
            var incoming: VideoTrack?
            while incoming == nil && Date() < deadline {
                incoming = receiver.remoteParticipants.values.filter { $0.name == senderName }.flatMap { $0.videoTracks }.compactMap { $0.track as? VideoTrack }.first
                if incoming == nil { try await Task.sleep(for: .milliseconds(100)) }
            }
            let received = try XCTUnwrap(incoming)
            view.track = .room(received)
            let receiveSource = RoomReceiveDelaySource(room: receiver)
            _ = await receiveSource.records()
            let delivery = try XCTUnwrap(view.deliveryForTesting)
            let recorder = RoomEnqueueRecorder()
            delivery.onEnqueuedForTesting = { sample, accepted in if accepted { recorder.record(sample) } }
            try await Task.sleep(for: .seconds(2))
            XCTAssertGreaterThan(recorder.count, 20, "Qualify encoded, received, decoded video before the UI stall")
            var window = ReceiveDelayStatistics()
            _ = window.ingest(await receiveSource.records())
            recorder.reset(); blockUI()
            // This in-process encoder is also affected by CPU adaptation and
            // SDK capture scheduling. The deterministic decoder tests separately
            // verify 30 fps pacing; here qualify real received pixels off-main.
            XCTAssertGreaterThan(recorder.count, 0)
            print("RECEIVE_ROOM_BLOCKED_UI received=\(recorder.count),window_ms=240")
            XCTAssertEqual(recorder.mainCount, 0)
            XCTAssertGreaterThan(recorder.size.height, 0)
            XCTAssertEqual(recorder.size.width / recorder.size.height, 16.0 / 9.0, accuracy: 0.001,
                           "SFU layer adaptation can reduce resolution but must preserve the whole image")
            XCTAssertLessThanOrEqual(recorder.size.width, 640)
            try await Task.sleep(for: .seconds(2))
            let intervals = window.ingest(await receiveSource.records())
            XCTAssertFalse(intervals.isEmpty, "Real RTP intervals must be available, not just synthetic unit counters")
            for interval in intervals {
                print("RECEIVE_ROOM_REAL_RTP kind=\(interval.kind) jitter_ms=\(String(describing: interval.jitterMS)) decode_ms=\(String(describing: interval.decodeMS)) fps=\(String(describing: interval.fps))")
            }
            feed?.cancel(); view.track = nil
            await sender.disconnect(); await receiver.disconnect()
        } catch {
            feed?.cancel(); view.track = nil
            await sender.disconnect(); await receiver.disconnect(); throw error
        }
    }
    private func blockUI() { Thread.sleep(forTimeInterval: 0.24) }
}
private final class RoomEnqueueRecorder: @unchecked Sendable {
    private let lock = NSLock(); private var frames = 0, main = 0, dimensions = CGSize.zero
    var count: Int { lock.lock(); defer { lock.unlock() }; return frames }
    var mainCount: Int { lock.lock(); defer { lock.unlock() }; return main }
    var size: CGSize { lock.lock(); defer { lock.unlock() }; return dimensions }
    func reset() { lock.lock(); frames = 0; main = 0; lock.unlock() }
    func record(_ sample: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        frames += 1; if Thread.isMainThread { main += 1 }
        if let pixels = CMSampleBufferGetImageBuffer(sample) { dimensions = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels)) }
    }
}
#endif
