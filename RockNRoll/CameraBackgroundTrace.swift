#if DEBUG
import AVFoundation
import UIKit

/// Opt-in, bounded diagnostics; no room URLs, names or pixels are recorded.
@MainActor
enum CameraBackgroundTrace {
    private static let enabled = ProcessInfo.processInfo.environment["CONFERENCE_TEST_CAMERA_TRACE"] == "1"
    private static let queue = DispatchQueue(label: "dev.vsmirn0v.camera-trace")
    private static var observers: [NSObjectProtocol] = []
    static func start() {
        guard enabled, observers.isEmpty else { return }
        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.interruptionEndedNotification,
                     AVCaptureSession.runtimeErrorNotification, UIApplication.didEnterBackgroundNotification,
                     UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    var fields: [String: Any] = [:]
                    if let session = note.object as? AVCaptureSession {
                        fields["running"] = session.isRunning; fields["interrupted"] = session.isInterrupted
                        fields["supported"] = session.isMultitaskingCameraAccessSupported
                        fields["enabled"] = session.isMultitaskingCameraAccessEnabled
                    }
                    fields["reason"] = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber
                    fields["error"] = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.code
                    event(note.name.rawValue, fields)
                }
            })
        }
        event("trace-start")
        Task { @MainActor in
            for _ in 0..<300 {
                try? await Task.sleep(for: .seconds(2))
                event("capture-sample", ["captures": GuestCaptureDeviceObserver.backgroundTrace()])
            }
        }
    }
    static func event(_ event: String, _ fields: [String: Any] = [:]) {
        guard enabled, let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        var entry = fields
        entry["time"] = Date().timeIntervalSince1970; entry["event"] = event
        entry["appState"] = UIApplication.shared.applicationState.rawValue
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(10)
        let data = line
        queue.async {
            let file = directory.appendingPathComponent("camera-background.jsonl")
            var contents = (try? Data(contentsOf: file)) ?? Data()
            if contents.count > 262_144 { contents.removeAll(keepingCapacity: true) }
            contents.append(data); try? contents.write(to: file, options: .atomic)
        }
    }
    static func outgoing(records: [CameraUplinkStatistics.Record], cameraMID: String) {
        guard enabled else { return }
        let rows = records.filter { $0.type == "outbound-rtp" && $0.values["kind"] as? String == "video" && $0.values["mid"] as? String == cameraMID }
        outgoing(encoded: rows.reduce(0) { $0 + (($1.values["framesEncoded"] as? NSNumber)?.int64Value ?? 0) },
                 bytes: rows.reduce(0) { $0 + (($1.values["bytesSent"] as? NSNumber)?.int64Value ?? 0) })
    }
    static func outgoing(encoded: Int64, bytes: Int64) {
        event("camera-outbound", ["framesEncoded": encoded, "bytesSent": bytes])
    }
}
#endif
