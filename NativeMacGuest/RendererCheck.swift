#if DEBUG
import AppKit
import CoreVideo
import Foundation
import LiveKitWebRTC
import MetalKit

private enum CompanionRendererCheckError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let message): return message } }
}

private final class CompanionInvalidCropBuffer: LKRTCCVPixelBuffer {
    override var cropX: Int32 { -1 }
}

private struct CompanionRendererPixels {
    let width: Int
    let height: Int
    let rowBytes: Int
    let bytes: [UInt8]
    func rgb(x: Int, y: Int) -> [Int] {
        let offset = y * rowBytes + x * 4
        return [Int(bytes[offset + 2]), Int(bytes[offset + 1]), Int(bytes[offset])]
    }
}

/// The blit reads the drawable after the production CI render on the SAME GPU
/// command. No screenshot, CPU CI rendering, or parallel reference renderer.
private final class CompanionRendererReadback: @unchecked Sendable {
    private let lock = NSLock()
    private let timestamp: Int64
    private var claimed = false
    private var completed: Result<CompanionRendererPixels, CompanionRendererCheckError>?
    init(timestamp: Int64) { self.timestamp = timestamp }
    var result: Result<CompanionRendererPixels, CompanionRendererCheckError>? {
        lock.lock(); defer { lock.unlock() }; return completed
    }
    private func finish(_ result: Result<CompanionRendererPixels, CompanionRendererCheckError>) {
        lock.lock(); defer { lock.unlock() }
        if completed == nil { completed = result }
    }
    func encode(command: MTLCommandBuffer, texture: MTLTexture, timestamp: Int64) {
        lock.lock()
        guard timestamp == self.timestamp, !claimed else { lock.unlock(); return }
        claimed = true; lock.unlock()
        guard texture.pixelFormat == .bgra8Unorm else {
            finish(.failure(.failed("Unexpected drawable pixel format: \(texture.pixelFormat.rawValue)"))); return
        }
        let width = texture.width, height = texture.height
        let rowBytes = (width * 4 + 255) / 256 * 256
        guard width > 0, height > 0,
              let buffer = texture.device.makeBuffer(length: rowBytes * height, options: .storageModeShared),
              let blit = command.makeBlitCommandEncoder() else {
            finish(.failure(.failed("Metal drawable readback allocation failed"))); return
        }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height)
        blit.endEncoding()
        command.addCompletedHandler { [self] command in
            guard command.status == .completed else {
                finish(.failure(.failed("Drawable GPU command failed: \(command.error?.localizedDescription ?? String(command.status.rawValue))")))
                return
            }
            let bytes = Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: rowBytes * height))
            finish(.success(.init(width: width, height: height, rowBytes: rowBytes, bytes: bytes)))
        }
    }
}

enum CompanionRendererCheck {
    private static let colors = [[240, 20, 20], [20, 230, 20], [20, 20, 240], [235, 225, 20]]
    private struct Fixture {
        let name: String
        let frame: LKRTCVideoFrame
        let mirrored: Bool
        /// Pixel order in display coordinates: top-left, top-right, bottom-left, bottom-right.
        let quadrants: [Int]
        let cropped: Bool
    }

    /// Call from an application delegate's MainActor Task with NSApplication's
    /// event loop running. Returns only after actual drawable GPU pixel checks.
    @MainActor static func run() async throws -> Int {
        let fixtures = try fixtures()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Native Guest renderer check — generated pixels only"
        window.center()
        defer { window.orderOut(nil); window.close() }
        for fixture in fixtures {
            let sink = CompanionVideoSink(mirrored: fixture.mirrored)
            defer { sink.stop(); sink.onEncodedDrawableForTesting = nil }
            guard sink.view.device != nil else { throw CompanionRendererCheckError.failed("Metal device unavailable") }
            sink.view.autoResizeDrawable = false
            sink.view.colorPixelFormat = .bgra8Unorm
            sink.view.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
            window.contentView = sink.view
            window.setContentSize(NSSize(width: 320, height: 240))
            sink.view.drawableSize = CGSize(width: 320, height: 240)
            window.makeKeyAndOrderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            let capture = CompanionRendererReadback(timestamp: fixture.frame.timeStampNs)
            sink.onEncodedDrawableForTesting = { command, texture, timestamp in
                capture.encode(command: command, texture: texture, timestamp: timestamp)
            }
            sink.renderFrame(fixture.frame)
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            var output: CompanionRendererPixels?
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                if let result = capture.result {
                    output = try result.get()
                    if sink.frames > 0 { break }
                }
                sink.view.draw()
                try await Task.sleep(nanoseconds: 33_333_333)
            }
            guard let output, sink.frames > 0 else {
                throw CompanionRendererCheckError.failed("\(fixture.name): actual drawable GPU completion timed out")
            }
            try verify(output, fixture: fixture)
            let metrics = sink.preparationEvidenceForTesting
            let native = fixture.frame.buffer is LKRTCCVPixelBuffer
            guard metrics[native ? "nativePreparations" : "genericPreparations"] == 1 else {
                throw CompanionRendererCheckError.failed("\(fixture.name): unexpected preparation path \(metrics)")
            }
            print("PASS: native drawable \(fixture.name) \(output.width)x\(output.height) GPU-completed")
        }
        return fixtures.count + (try await backpressure(window: window))
    }

    @MainActor private static func wait(_ description: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CompanionRendererCheckError.failed(description)
    }

    @MainActor private static func install(_ sink: CompanionVideoSink, in window: NSWindow) {
        sink.view.autoResizeDrawable = false
        sink.view.colorPixelFormat = .bgra8Unorm
        sink.view.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        window.contentView = sink.view
        window.setContentSize(NSSize(width: 320, height: 240))
        sink.view.drawableSize = CGSize(width: 320, height: 240)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    @MainActor private static func backpressure(window: NSWindow) async throws -> Int {
        // The real generic I420 preparation is blocked while MainActor continues
        // through multiple event-loop turns. A burst must retain only its last input.
        let planar = i420()
        for stopBlockedWorker in [false, true] {
            let sink = CompanionVideoSink(mirrored: false)
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal(); sink.stop() }
            install(sink, in: window)
            sink.onPreparationForTesting = { timestamp in
                precondition(!Thread.isMainThread, "Pixel preparation ran on main")
                if timestamp == 1001 { _ = gate.wait(timeout: .now() + 5) }
            }
            let capture = CompanionRendererReadback(timestamp: 1100)
            sink.onEncodedDrawableForTesting = { command, texture, timestamp in
                precondition(Thread.isMainThread)
                capture.encode(command: command, texture: texture, timestamp: timestamp)
            }
            sink.renderFrame(LKRTCVideoFrame(buffer: planar, rotation: ._0, timeStampNs: 1001))
            try await wait("I420 worker did not start") { sink.preparationEvidenceForTesting["preparationInFlight"] == 1 }
            for timestamp in 1002...1100 {
                sink.renderFrame(LKRTCVideoFrame(buffer: planar, rotation: ._0, timeStampNs: Int64(timestamp)))
            }
            // This callback can execute only if main is free while conversion waits.
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            let blocked = sink.preparationEvidenceForTesting
            guard blocked["pendingInputs"] == 1, blocked["preparationInFlight"] == 1,
                  blocked["submittedCommands"] == 0, (blocked["replacedInputs"] ?? 0) >= 98 else {
                throw CompanionRendererCheckError.failed("I420 worker backpressure is not bounded: \(blocked)")
            }
            if stopBlockedWorker { sink.stop() }
            gate.signal()
            if stopBlockedWorker {
                try await wait("Stopped I420 worker did not retire") { sink.preparationEvidenceForTesting["preparationInFlight"] == 0 }
                let state = sink.preparationEvidenceForTesting
                guard state["submittedCommands"] == 0, state["pendingInputs"] == 0,
                      state["preparedTimestamp"] == -1, sink.frames == 0 else {
                    throw CompanionRendererCheckError.failed("Late worker published after stop: \(state)")
                }
            } else {
                try await wait("Latest I420 frame did not reach the real GPU") { capture.result != nil && sink.frames > 0 }
                let output = try capture.result!.get()
                try verify(output, fixture: Fixture(name: "worker-latest-I420", frame: LKRTCVideoFrame(buffer: planar, rotation: ._0, timeStampNs: 1100),
                    mirrored: false, quadrants: [0, 1, 2, 3], cropped: false))
                let state = sink.preparationEvidenceForTesting
                guard state["preparations"] == 2, state["genericPreparations"] == 2,
                      state["preparedTimestamp"] == 1100 else {
                    throw CompanionRendererCheckError.failed("I420 burst converted an obsolete backlog: \(state)")
                }
                let preparations = state["preparations"], frames = sink.frames
                let commands = state["submittedCommands"] ?? 0
                sink.setPresentation(crop: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), zoom: 1.2, pan: .zero)
                try await wait("Cached presentation did not repaint") {
                    (sink.preparationEvidenceForTesting["submittedCommands"] ?? 0) > commands && sink.preparationEvidenceForTesting["gpuInFlight"] == 0
                }
                sink.view.drawableSize = CGSize(width: 240, height: 320)
                sink.mtkView(sink.view, drawableSizeWillChange: sink.view.drawableSize)
                try await wait("Cached resize did not repaint") { sink.preparationEvidenceForTesting["gpuInFlight"] == 0 && sink.preparationEvidenceForTesting["drawScheduled"] == 0 }
                guard sink.preparationEvidenceForTesting["preparations"] == preparations, sink.frames == frames else {
                    throw CompanionRendererCheckError.failed("Presentation/resize reconverted or recounted the same frame")
                }
                let unchangedCommands = sink.preparationEvidenceForTesting["submittedCommands"]
                for _ in 0..<1000 {
                    sink.setPresentation(crop: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), zoom: 1.2, pan: .zero)
                }
                try await Task.sleep(nanoseconds: 100_000_000)
                guard sink.preparationEvidenceForTesting["submittedCommands"] == unchangedCommands else {
                    throw CompanionRendererCheckError.failed("Unchanged SwiftUI presentation rebound a cached GPU frame")
                }
                print("PASS: native drawable ignores 1000 unchanged presentation rebinds")
            }
            print("PASS: native drawable I420 worker heartbeat/latest-only/stop=\(stopBlockedWorker)")
        }
        let native = LKRTCCVPixelBuffer(pixelBuffer: try bgra(cropped: false))
        for stopBlockedGPU in [false, true] {
            let sink = CompanionVideoSink(mirrored: false)
            defer { sink.stop() }
            install(sink, in: window)
            guard let event = sink.view.device?.makeSharedEvent() else {
                throw CompanionRendererCheckError.failed("Metal shared event unavailable")
            }
            defer { event.signaledValue = 1 }
            var encoded: [Int64] = []
            sink.onEncodedDrawableForTesting = { command, _, timestamp in
                precondition(Thread.isMainThread)
                encoded.append(timestamp)
                if timestamp == 2001 { command.encodeWaitForEvent(event, value: 1) }
            }
            sink.renderFrame(LKRTCVideoFrame(buffer: native, rotation: ._0, timeStampNs: 2001))
            try await wait("GPU command was not admitted") { sink.preparationEvidenceForTesting["submittedCommands"] == 1 }
            for timestamp in 2002...2100 {
                sink.renderFrame(LKRTCVideoFrame(buffer: native, rotation: ._0, timeStampNs: Int64(timestamp)))
            }
            try await wait("GPU backpressure did not retain the latest prepared image") { sink.preparationEvidenceForTesting["preparedTimestamp"] == 2100 }
            let blocked = sink.preparationEvidenceForTesting
            guard blocked["gpuInFlight"] == 1, blocked["submittedCommands"] == 1,
                  blocked["drawScheduled"] == 0, encoded == [2001], sink.frames == 0 else {
                throw CompanionRendererCheckError.failed("GPU commands accumulated under backpressure: \(blocked)")
            }
            if stopBlockedGPU { sink.stop() }
            event.signaledValue = 1
            if stopBlockedGPU {
                try await wait("Stopped GPU command did not complete") { sink.preparationEvidenceForTesting["gpuInFlight"] == 0 }
                guard sink.frames == 0, encoded == [2001], sink.preparationEvidenceForTesting["preparedTimestamp"] == -1 else {
                    throw CompanionRendererCheckError.failed("Late GPU completion published/recounted after stop")
                }
            } else {
                try await wait("Latest prepared image did not follow GPU completion") { sink.frames == 2 }
                guard encoded == [2001, 2100] else {
                    throw CompanionRendererCheckError.failed("GPU submitted stale prepared frames: \(encoded)")
                }
            }
            print("PASS: native drawable actual GPU backpressure/latest-only/stop=\(stopBlockedGPU)")
        }
        let invalid = CompanionVideoSink(mirrored: false)
        defer { invalid.stop() }
        install(invalid, in: window)
        invalid.renderFrame(LKRTCVideoFrame(buffer: CompanionInvalidCropBuffer(pixelBuffer: try bgra(cropped: false)),
                                           rotation: ._0, timeStampNs: 3001))
        try await wait("Malformed crop was not checked on worker") {
            invalid.preparationEvidenceForTesting["preparationAttempts"] == 1 && invalid.preparationEvidenceForTesting["preparationInFlight"] == 0
        }
        guard invalid.preparationEvidenceForTesting["preparations"] == 0,
              invalid.preparationEvidenceForTesting["submittedCommands"] == 0 else {
            throw CompanionRendererCheckError.failed("Malformed CV metadata was rendered or converted through I420")
        }
        print("PASS: native drawable rejects malformed CV crop metadata")
        return 6
    }

    private static func verify(_ output: CompanionRendererPixels, fixture: Fixture) throws {
        let quarterTurn = fixture.frame.rotation.rawValue == 90 || fixture.frame.rotation.rawValue == 270
        let width = Double(quarterTurn ? fixture.frame.height : fixture.frame.width)
        let height = Double(quarterTurn ? fixture.frame.width : fixture.frame.height)
        let scale = min(Double(output.width) / width, Double(output.height) / height)
        let contentWidth = width * scale, contentHeight = height * scale
        let left = (Double(output.width) - contentWidth) / 2, top = (Double(output.height) - contentHeight) / 2
        func check(_ x: Double, _ y: Double, expected: [Int], label: String, tolerance: Int = 65) throws {
            let px = max(0, min(output.width - 1, Int(x))), py = max(0, min(output.height - 1, Int(y)))
            let actual = output.rgb(x: px, y: py)
            guard zip(actual, expected).allSatisfy({ abs($0 - $1) <= tolerance }) else {
                throw CompanionRendererCheckError.failed("\(fixture.name) \(label) at \(px),\(py): RGB \(actual), expected \(expected)")
            }
        }
        for (index, point) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)].enumerated() {
            try check(left + point.0 * contentWidth, top + point.1 * contentHeight,
                      expected: colors[fixture.quadrants[index]], label: "quadrant \(index)")
        }
        if fixture.cropped {
            // Magenta exists outside the native crop. Center-only checks could
            // incorrectly pass a renderer that ignored crop/adaptation metadata.
            for (index, point) in [(0.06, 0.20), (0.94, 0.20), (0.06, 0.80), (0.94, 0.80)].enumerated() {
                try check(left + point.0 * contentWidth, top + point.1 * contentHeight,
                          expected: colors[fixture.quadrants[index]], label: "cropped edge \(index)")
            }
        }
        if left > 8 {
            try check(2, Double(output.height) / 2, expected: [0, 0, 0], label: "left aspect-fit bar", tolerance: 20)
            try check(Double(output.width - 3), Double(output.height) / 2, expected: [0, 0, 0], label: "right aspect-fit bar", tolerance: 20)
        }
        if top > 8 {
            try check(Double(output.width) / 2, 2, expected: [0, 0, 0], label: "top aspect-fit bar", tolerance: 20)
            try check(Double(output.width) / 2, Double(output.height - 3), expected: [0, 0, 0], label: "bottom aspect-fit bar", tolerance: 20)
        }
    }

    private static func fixtures() throws -> [Fixture] {
        let native = LKRTCCVPixelBuffer(pixelBuffer: try bgra(cropped: false))
        let cropped = LKRTCCVPixelBuffer(pixelBuffer: try bgra(cropped: true), adaptedWidth: 32, adaptedHeight: 24,
                                        cropWidth: 64, cropHeight: 48, cropX: 32, cropY: 24)
        let planar = i420()
        let fullAdapted = LKRTCCVPixelBuffer(pixelBuffer: try bgra(cropped: false), adaptedWidth: 80, adaptedHeight: 80,
                                            cropWidth: 128, cropHeight: 96, cropX: 0, cropY: 0)
        let asymmetric = LKRTCCVPixelBuffer(pixelBuffer: try bgra(cropped: true, region: CGRect(x: 8, y: 16, width: 96, height: 64)),
                                           adaptedWidth: 48, adaptedHeight: 64, cropWidth: 96, cropHeight: 64, cropX: 8, cropY: 16)
        let descriptions: [(String, LKRTCVideoFrameBuffer, LKRTCVideoRotation, Bool, [Int], Bool)] = [
            ("CV-0", native, ._0, false, [0, 1, 2, 3], false),
            ("CV-0-mirror", native, ._0, true, [1, 0, 3, 2], false),
            ("CV-90", native, ._90, false, [2, 0, 3, 1], false),
            ("CV-90-mirror", native, ._90, true, [0, 2, 1, 3], false),
            ("crop-adapt-0", cropped, ._0, false, [0, 1, 2, 3], true),
            ("crop-adapt-90-mirror", cropped, ._90, true, [0, 2, 1, 3], true),
            ("padded-I420-0", planar, ._0, false, [0, 1, 2, 3], false),
            ("padded-I420-90-mirror", planar, ._90, true, [0, 2, 1, 3], false),
            ("CV-full-adapt-square", fullAdapted, ._0, false, [0, 1, 2, 3], false),
            ("CV-asymmetric-crop-adapt", asymmetric, ._0, false, [0, 1, 2, 3], true),
            ("CV-asymmetric-crop-adapt-90-mirror", asymmetric, ._90, true, [0, 2, 1, 3], true),
            ("CV-asymmetric-crop-adapt-270", asymmetric, ._270, false, [1, 3, 0, 2], true)
        ]
        return descriptions.enumerated().map { index, fixture in
            Fixture(name: fixture.0, frame: LKRTCVideoFrame(buffer: fixture.1, rotation: fixture.2, timeStampNs: Int64(index + 1)),
                    mirrored: fixture.3, quadrants: fixture.4, cropped: fixture.5)
        }
    }

    private static func bgra(cropped: Bool, region: CGRect? = nil) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 128, 96, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &value) == kCVReturnSuccess, let value else {
            throw CompanionRendererCheckError.failed("Fixture CVPixelBuffer allocation failed")
        }
        CVPixelBufferLockBaseAddress(value, []); defer { CVPixelBufferUnlockBaseAddress(value, []) }
        guard let base = CVPixelBufferGetBaseAddress(value)?.assumingMemoryBound(to: UInt8.self) else {
            throw CompanionRendererCheckError.failed("Fixture CVPixelBuffer storage unavailable")
        }
        let stride = CVPixelBufferGetBytesPerRow(value)
        let region = region ?? (cropped ? CGRect(x: 32, y: 24, width: 64, height: 48) : CGRect(x: 0, y: 0, width: 128, height: 96))
        for y in 0..<96 { for x in 0..<128 {
            let outside = cropped && !region.contains(CGPoint(x: x, y: y))
            let rgb = outside ? [255, 0, 255] : colors[(CGFloat(y) < region.midY ? 0 : 2) + (CGFloat(x) < region.midX ? 0 : 1)]
            let offset = y * stride + x * 4
            base[offset] = UInt8(rgb[2]); base[offset + 1] = UInt8(rgb[1])
            base[offset + 2] = UInt8(rgb[0]); base[offset + 3] = 255
        } }
        return value
    }

    private static func i420() -> LKRTCMutableI420Buffer {
        let buffer = LKRTCMutableI420Buffer(width: 96, height: 64, strideY: 112, strideU: 64, strideV: 64)
        memset(buffer.mutableDataY, 0xA5, Int(buffer.strideY) * 64)
        memset(buffer.mutableDataU, 0xA5, Int(buffer.strideU) * 32)
        memset(buffer.mutableDataV, 0xA5, Int(buffer.strideV) * 32)
        // Video-range BT.601 primaries, matching the generic I420 converter contract.
        let yuv: [(UInt8, UInt8, UInt8)] = [(81, 90, 240), (145, 54, 34), (41, 240, 110), (210, 16, 146)]
        for y in 0..<64 { for x in 0..<96 {
            buffer.mutableDataY[y * Int(buffer.strideY) + x] = yuv[(y < 32 ? 0 : 2) + (x < 48 ? 0 : 1)].0
        } }
        for y in 0..<32 { for x in 0..<48 {
            let color = yuv[(y < 16 ? 0 : 2) + (x < 24 ? 0 : 1)]
            buffer.mutableDataU[y * Int(buffer.strideU) + x] = color.1
            buffer.mutableDataV[y * Int(buffer.strideV) + x] = color.2
        } }
        return buffer
    }
}
#endif
