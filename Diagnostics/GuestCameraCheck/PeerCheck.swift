import Foundation
import AVFoundation
import WebRTC

final class LocalCameraPeer: NSObject, RTCPeerConnectionDelegate, RTCVideoRenderer {
    let factory: RTCPeerConnectionFactory
    var peer: RTCPeerConnection!
    var other: LocalCameraPeer?
    var frames = 0
    var last: [String: Any] = [:]
    private let lock = NSLock()
    private var queued: [RTCIceCandidate] = []
    private var rendered: Set<String> = []
    private var tracks: [RTCVideoTrack] = []
    init(factory: RTCPeerConnectionFactory) {
        self.factory = factory; super.init()
        let configuration = RTCConfiguration(); configuration.sdpSemantics = .unifiedPlan
        peer = factory.peerConnection(with: configuration, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
    }
    func remote(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(sdp) { e in if let e { c.resume(throwing: e) } else { c.resume() } }
        }
        lock.lock(); let pending = queued; queued.removeAll(); lock.unlock()
        for value in pending { peer.add(value) { _ in } }
    }
    func local(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(sdp) { e in if let e { c.resume(throwing: e) } else { c.resume() } }
        }
    }
    func description(offer: Bool) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { c in
            let completion: (RTCSessionDescription?, Error?) -> Void = { sdp, error in
                if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: error ?? NSError(domain: "SDP", code: 1)) }
            }
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            if offer { peer.offer(for: constraints, completionHandler: completion) }
            else { peer.answer(for: constraints, completionHandler: completion) }
        }
    }
    func peerConnection(_ p: RTCPeerConnection, didChange s: RTCSignalingState) {}
    func peerConnection(_ p: RTCPeerConnection, didAdd s: RTCMediaStream) {}
    func peerConnection(_ p: RTCPeerConnection, didRemove s: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ p: RTCPeerConnection) {}
    func peerConnection(_ p: RTCPeerConnection, didChange s: RTCIceConnectionState) {}
    func peerConnection(_ p: RTCPeerConnection, didChange s: RTCIceGatheringState) {}
    func peerConnection(_ p: RTCPeerConnection, didGenerate c: RTCIceCandidate) {
        guard let other else { return }
        other.lock.lock(); let ready = other.peer.remoteDescription != nil
        if !ready { other.queued.append(c) }; other.lock.unlock()
        if ready { other.peer.add(c) { _ in } }
    }
    func peerConnection(_ p: RTCPeerConnection, didRemove c: [RTCIceCandidate]) {}
    func peerConnection(_ p: RTCPeerConnection, didOpen c: RTCDataChannel) {}
    func peerConnection(_ p: RTCPeerConnection, didAdd r: RTCRtpReceiver, streams: [RTCMediaStream]) {
        if let track = r.track as? RTCVideoTrack { attach(track) }
    }
    func attach(_ track: RTCVideoTrack) {
        lock.lock(); let added = rendered.insert(track.trackId).inserted; lock.unlock()
        if added { lock.lock(); tracks.append(track); lock.unlock(); track.isEnabled = true; track.add(self) }
    }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        var row: [String: Any] = ["width": frame.width, "height": frame.height, "rotation": frame.rotation.rawValue]
        if let cv = frame.buffer as? RTCCVPixelBuffer {
            row["attachments"] = (CVBufferCopyAttachments(cv.pixelBuffer, .shouldPropagate) as? [String: Any])?.mapValues { String(describing: $0) } ?? [:]
        }
        let i420 = frame.buffer.toI420()
        row["y"] = Int(i420.dataY[100 * Int(i420.strideY) + 100])
        lock.lock(); frames += 1; last = row; lock.unlock()
    }
    static func check(log: @escaping ([String: Any]) -> Void, liveCamera: Bool = false) async {
        GuestH264ColorEncoder.prepare()
        let encoder = RTCDefaultVideoEncoderFactory(); encoder.preferredCodec = encoder.supportedCodecs().first { $0.name == "H264" }!
        let factory = RTCPeerConnectionFactory(encoderFactory: H264OnlyEncoder(base: encoder), decoderFactory: RTCDefaultVideoDecoderFactory())
        let sender = LocalCameraPeer(factory: factory), receiver = LocalCameraPeer(factory: factory)
        sender.other = receiver; receiver.other = sender
        defer { sender.other = nil; receiver.other = nil; sender.peer.close(); receiver.peer.close(); sender.tracks.forEach { $0.remove(sender) }; receiver.tracks.forEach { $0.remove(receiver) }; sender.tracks.removeAll(); receiver.tracks.removeAll() }
        let source = factory.videoSource(); source.adaptOutputFormat(toWidth: 320, height: liveCamera ? 180 : 240, fps: 30)
        let track = factory.videoTrack(with: source, trackId: "camera-color-check")
        let initSettings = RTCRtpTransceiverInit(); initSettings.direction = .sendOnly
        _ = sender.peer.addTransceiver(with: track, init: initSettings)!
        do {
            let offer = try await sender.description(offer: true); try await sender.local(offer); try await receiver.remote(offer)
            let answer = try await receiver.description(offer: false); try await receiver.local(answer); try await sender.remote(answer)
            try await Task.sleep(for: .seconds(1))
            for value in receiver.peer.receivers { if let track = value.track as? RTCVideoTrack { receiver.attach(track) } }
            if liveCamera {
                guard let device = AVCaptureDevice.default(for: .video),
                      let format = RTCCameraVideoCapturer.supportedFormats(for: device).first(where: {
                          let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                          return d.width == 1920 && d.height == 1080
                      }) else { log(["cameraPeerError": "No qualified camera"]); return }
                let capture = RTCCameraVideoCapturer(delegate: source)
                let proxy = GuestCameraFrameDelegate(camera: capture, device: device, downstream: source)
                capture.delegate = proxy
                try await capture.startCapture(with: device, format: format, fps: 30)
                try await Task.sleep(for: .seconds(6))
                await capture.stopCapture(); proxy.retire()
                try await Task.sleep(for: .milliseconds(250))
            } else {
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
                let pixels = buffer!; CVPixelBufferLockBaseAddress(pixels, [])
                memset(CVPixelBufferGetBaseAddressOfPlane(pixels, 0), 80, CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) * 480)
                let uv = CVPixelBufferGetBaseAddressOfPlane(pixels, 1)!.assumingMemoryBound(to: UInt8.self)
                for i in stride(from: 0, to: CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) * 240, by: 2) { uv[i] = 90; uv[i+1] = 180 }
                CVPixelBufferUnlockBaseAddress(pixels, [])
                for key in [kCVImageBufferYCbCrMatrixKey, kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey] {
                    CVBufferSetAttachment(pixels, key, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                }
                let capture = RTCVideoCapturer(delegate: source)
                for _ in 0..<150 {
                    source.capturer(capture, didCapture: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0, timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1e9)))
                    try await Task.sleep(for: .milliseconds(33))
                }
            }
            receiver.lock.lock(); var result = receiver.last; result["frames"] = receiver.frames; receiver.lock.unlock()
            result["peerLoopback"] = true; result["liveCamera"] = liveCamera; result["senderState"] = sender.peer.connectionState.rawValue; result["receiverState"] = receiver.peer.connectionState.rawValue; log(result)
            let received: RTCStatisticsReport = await withCheckedContinuation { c in receiver.peer.statistics { c.resume(returning: $0) } }
            for item in received.statistics.values where item.type == "inbound-rtp" { log(["receivedStat": item.values.description]) }
            #if DEBUG
            log(["encoderInputs": GuestH264ColorEncoder.evidenceForTesting()])
            #endif
            let report: RTCStatisticsReport = await withCheckedContinuation { c in sender.peer.statistics { c.resume(returning: $0) } }
            for item in report.statistics.values where ["outbound-rtp", "media-source", "codec"].contains(item.type) {
                var row: [String: Any] = ["statType": item.type, "statID": item.id]
                for key in ["kind", "mid", "frames", "framesEncoded", "frameWidth", "frameHeight", "encoderImplementation", "powerEfficientEncoder", "mediaSourceId", "qualityLimitationReason", "mimeType"] { row[key] = item.values[key] }
                log(row)
            }
        } catch { log(["peerError": error.localizedDescription]) }
    }
}

private final class H264OnlyEncoder: NSObject, RTCVideoEncoderFactory {
    let base: RTCDefaultVideoEncoderFactory
    init(base: RTCDefaultVideoEncoderFactory) { self.base = base }
    func supportedCodecs() -> [RTCVideoCodecInfo] { base.supportedCodecs().filter { $0.name == "H264" } }
    func createEncoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoEncoder)? { base.createEncoder(info) }
}
