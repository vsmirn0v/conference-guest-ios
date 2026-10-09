import CoreMedia
import CoreVideo

/// Drops redundant capture frames before IPC/encoding, without copying pixels.
/// Keep resolution/format changes immediate and avoid a queue or catch-up burst.
struct OutgoingVideoCadence {
    private struct Format: Equatable { let width: Int; let height: Int; let pixelType: OSType }
    private var format: Format?
    private var previous: Double?
    private var next: Double = 0
    private var rate = 0
    mutating func accept(_ sample: CMSampleBuffer, fps: Int) -> Bool {
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return false }
        let current = Format(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels), pixelType: CVPixelBufferGetPixelFormatType(pixels))
        return accept(time: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)), fps: fps, format: current)
    }
    private mutating func accept(time: Double, fps: Int, format current: Format) -> Bool {
        guard time.isFinite, time >= 0, fps > 0 else { return false }
        let changed = current != format || rate != fps || previous.map { time < $0 } == true
        previous = time
        if !changed && time + 1e-9 < next { return false }
        format = current; rate = fps
        let interval = 1 / Double(fps)
        next = changed || time - next >= interval ? time + interval : next + interval
        return true
    }
}
