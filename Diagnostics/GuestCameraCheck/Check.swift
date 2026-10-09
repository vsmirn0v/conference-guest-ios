import UIKit
import AVFoundation
import WebRTC
import JazzCore

@main final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = CameraCheck(); window.makeKeyAndVisible(); self.window = window
        return true
    }
}

final class CameraCheck: UIViewController, RTCVideoCapturerDelegate {
    private var capturer: RTCCameraVideoCapturer?
    private var cameraProxy: GuestCameraFrameDelegate?
    private var frames = 0
    private var report: [[String: Any]] = []
    private let lock = NSLock()
    private let text = UITextView()
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        text.frame = view.bounds; text.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        text.backgroundColor = .black; text.textColor = .white; text.isEditable = false
        view.addSubview(text)
        let button = UIButton(type: .system); button.setTitle("Check camera and codec", for: .normal)
        button.frame = CGRect(x: 20, y: 20, width: 300, height: 60)
        button.addTarget(self, action: #selector(start), for: .touchUpInside); view.addSubview(button)
        text.contentInset.top = 90
    }
    func log(_ row: [String: Any]) {
        lock.lock(); report.append(row); let current = report; lock.unlock()
        let data = try! JSONSerialization.data(withJSONObject: current, options: [.prettyPrinted, .sortedKeys])
        try? data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("camera-check.json"))
        DispatchQueue.main.async { self.text.text = String(decoding: data, as: UTF8.self) }
        print("CAMERA_CHECK " + String(decoding: try! JSONSerialization.data(withJSONObject: row, options: .sortedKeys), as: UTF8.self))
    }
    @objc func start() {
        Task { @MainActor in
            guard await AVCaptureDevice.requestAccess(for: .video) else { log(["permission": false]); return }
            RTCInitializeSSL(); CameraVideoCapturer.fixOrientation()
            guard let device = AVCaptureDevice.default(for: .video),
                  let format = RTCCameraVideoCapturer.supportedFormats(for: device).filter({
                      let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                      return d.width == 1920 && d.height == 1080
                  }).first else { log(["camera": "not found"]); return }
            coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            let capture = RTCCameraVideoCapturer(delegate: self); capturer = capture
            let proxy = GuestCameraFrameDelegate(camera: capture, device: device, downstream: self)
            cameraProxy = proxy; capture.delegate = proxy
            log(["device": device.localizedName, "position": device.position.rawValue,
                 "horizonCapture": coordinator!.videoRotationAngleForHorizonLevelCapture,
                 "horizonPreview": coordinator!.videoRotationAngleForHorizonLevelPreview])
            capture.startCapture(with: device, format: format, fps: 30) { error in
                self.log(["started": error == nil, "error": error?.localizedDescription ?? ""])
            }
            try? await Task.sleep(for: .seconds(6)); await capture.stopCapture()
            log(["cameraFrames": frames])
            await self.checkCodec()
            await LocalCameraPeer.check(log: self.log)
            await LocalCameraPeer.check(log: self.log, liveCamera: true)
        }
    }
    func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
        lock.lock(); frames += 1; let count = frames; lock.unlock()
        guard count == 1 || count == 90, let camera = capturer as? RTCCameraVideoCapturer,
              let cv = frame.buffer as? RTCCVPixelBuffer else { return }
        let buffer = cv.pixelBuffer
        var row: [String: Any] = ["frame": count, "width": frame.width, "height": frame.height,
                                "rotation": frame.rotation.rawValue, "rawWidth": CVPixelBufferGetWidth(buffer),
                                "rawHeight": CVPixelBufferGetHeight(buffer), "format": CVPixelBufferGetPixelFormatType(buffer),
                                "attachments": (CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any])?.mapValues { String(describing: $0) } ?? [:]]
        if let output = camera.captureSession.outputs.first as? AVCaptureVideoDataOutput, let connection = output.connection(with: .video) {
            row["connectionAngle"] = connection.videoRotationAngle
            row["connectionOrientation"] = connection.videoOrientation.rawValue
            row["mirrored"] = connection.isVideoMirrored
        }
        log(row)
    }
    func checkCodec() async {
        // Independent tagged patterns; no camera image is recorded or sent anywhere.
        for range in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] {
            for matrix in [kCVImageBufferYCbCrMatrix_ITU_R_601_4, kCVImageBufferYCbCrMatrix_ITU_R_709_2] {
                for cropped in [false, true] {
                    let result = await encode(range: range, matrix: matrix, cropped: cropped)
                    log(result)
                }
            }
        }
    }
    func encode(range: OSType, matrix: CFString, cropped: Bool) async -> [String: Any] {
        let codec = RTCVideoCodecInfo(name: "H264", parameters: ["profile-level-id": "42e01f", "packetization-mode": "1"])
        let encoder = RTCDefaultVideoEncoderFactory().createEncoder(codec)!
        let decoder = RTCDefaultVideoDecoderFactory().createDecoder(codec)!
        let settings = RTCVideoEncoderSettings(); settings.name = "H264"; settings.width = 320; settings.height = 240
        settings.startBitrate = 2000; settings.maxBitrate = 2000; settings.minBitrate = 200; settings.maxFramerate = 30; settings.qpMax = 56
        var output: [String: Any] = ["range": range, "matrix": matrix as String, "cropped": cropped, "patched": true]
        let resultLock = NSLock()
        decoder.setCallback { frame in
            var row: [String: Any] = ["decoded": true, "rotation": frame.rotation.rawValue]
            if let cv = frame.buffer as? RTCCVPixelBuffer {
                row["decodedFormat"] = CVPixelBufferGetPixelFormatType(cv.pixelBuffer)
                row["decodedAttachments"] = (CVBufferCopyAttachments(cv.pixelBuffer, .shouldPropagate) as? [String: Any])?.mapValues { String(describing: $0) } ?? [:]
            }
            let i420 = frame.buffer.toI420(); row["y"] = Int(i420.dataY[100 * Int(i420.strideY) + 100]); row["u"] = Int(i420.dataU[50 * Int(i420.strideU) + 50]); row["v"] = Int(i420.dataV[50 * Int(i420.strideV) + 50])
            resultLock.lock(); output.merge(row) { _, new in new }; resultLock.unlock()
        }
        encoder.setCallback { image, info in
            resultLock.lock(); if output["packet"] == nil { output["packet"] = image.buffer.prefix(96).base64EncodedString() }; resultLock.unlock()
            do {
                let data = image.buffer
                let color = H264ColorDescription(primaries: 1, transfer: 1, matrix: CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2) ? 1 : 6)
                image.buffer = H264ColorSignalling.applying(color, to: data)
            }
            let status = decoder.decode(image, missingFrames: false, codecSpecificInfo: info, renderTimeMs: 0)
            return status == 0
        }
        output["startDecode"] = decoder.startDecode(withNumberOfCores: 2)
        output["startEncode"] = encoder.startEncode(with: settings, numberOfCores: 2)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, cropped ? 640 : 320, cropped ? 480 : 240, range, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pixels = buffer!; CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddressOfPlane(pixels, 0), 80, CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) * CVPixelBufferGetHeightOfPlane(pixels, 0))
        let uv = CVPixelBufferGetBaseAddressOfPlane(pixels, 1)!.assumingMemoryBound(to: UInt8.self)
        for index in stride(from: 0, to: CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) * CVPixelBufferGetHeightOfPlane(pixels, 1), by: 2) { uv[index] = 90; uv[index+1] = 180 }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        CVBufferSetAttachment(pixels, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        CVBufferSetAttachment(pixels, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        let wrapped = cropped ? RTCCVPixelBuffer(pixelBuffer: pixels, adaptedWidth: 320, adaptedHeight: 240, cropWidth: 320, cropHeight: 240, cropX: 160, cropY: 120) : RTCCVPixelBuffer(pixelBuffer: pixels)
        for index in 0..<12 {
            let frame = RTCVideoFrame(buffer: wrapped, rotation: ._0, timeStampNs: Int64(index) * 33_333_333)
            frame.timeStamp = Int32(index * 3000)
            let status = encoder.encode(frame, codecSpecificInfo: nil, frameTypes: [NSNumber(value: index == 0 ? RTCFrameType.videoFrameKey.rawValue : RTCFrameType.videoFrameDelta.rawValue)])
            if status != 0 { resultLock.lock(); output["encodeError"] = status; resultLock.unlock() }
            try? await Task.sleep(for: .milliseconds(35))
        }
        try? await Task.sleep(for: .milliseconds(300))
        _ = encoder.release(); _ = decoder.release()
        resultLock.lock(); let result = output; resultLock.unlock()
        return result
    }
}
