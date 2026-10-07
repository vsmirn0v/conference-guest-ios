import Foundation
import CoreImage
import CoreMedia
import QuartzCore
import Darwin

func input(_ width: Int, _ height: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    CVPixelBufferLockBaseAddress(buffer!, [])
    memset(CVPixelBufferGetBaseAddress(buffer!), 200, CVPixelBufferGetDataSize(buffer!))
    CVPixelBufferUnlockBaseAddress(buffer!, [])
    return buffer!
}
@main struct Bench {
    static func main() {
        let camera = input(1280, 720)
        for profile in ["stage-card", "drawing"] {
            let compositor = PresenterCompositor()
            var scene = PresenterScene(); scene.backdrop = .stage
            scene.strokes = (0..<32).map { row in (0..<128).map { point in CGPoint(x: CGFloat(point) / 128, y: CGFloat(row) / 40) } }
            if profile != "drawing" { scene.strokes = [] }
            var times: [Double] = []
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            let beforeCPU = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
            for index in 0..<130 {
                if profile == "drawing" { scene.draftStroke = (0..<128).map { CGPoint(x: CGFloat($0) / 128, y: CGFloat(index % 40) / 40) } }
                let before = CACurrentMediaTime()
                autoreleasepool { precondition(compositor.render(scene: scene, camera: camera, time: CMTime(value: Int64(index), timescale: 15)) != nil) }
                if index >= 10 { times.append((CACurrentMediaTime() - before) * 1000) }
            }
            getrusage(RUSAGE_SELF, &usage)
            let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6 - beforeCPU
            let sorted = times.sorted()
            print("\(profile),mean_ms=\(times.reduce(0,+)/Double(times.count)),p50_ms=\(sorted[sorted.count/2]),p95_ms=\(sorted[Int(Double(sorted.count)*0.95)]),cpu_ms_per_frame=\(cpu * 1000 / 130),peak_rss_mb=\(Double(usage.ru_maxrss) / 1048576)")
        }
    }
}
