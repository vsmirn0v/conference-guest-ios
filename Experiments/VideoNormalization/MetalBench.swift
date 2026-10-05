// Standalone optimized Mac experiment. Includes CPU-to-GPU staging and completion.
// It measures repacking, not display latency or battery energy.
import CoreVideo
import Darwin
import Foundation
import Metal

let shader = """
#include <metal_stdlib>
using namespace metal;
struct Layout { uint width, height, yStride, cStride, uOffset, vOffset; };
kernel void repack(device const uchar *src [[buffer(0)]], constant Layout &p [[buffer(1)]],
    texture2d<float, access::write> y [[texture(0)]],
    texture2d<float, access::write> uv [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x < p.width && gid.y < p.height)
        y.write(float4(float(src[gid.y * p.yStride + gid.x]) / 255.0f), gid);
    if (gid.x < (p.width + 1) / 2 && gid.y < (p.height + 1) / 2) {
        uint i = gid.y * p.cStride + gid.x;
        uv.write(float4(float(src[p.uOffset+i])/255.0f, float(src[p.vOffset+i])/255.0f, 0, 1), gid);
    }
}
"""
struct Layout {
    var width, height, yStride, cStride, uOffset, vOffset: UInt32
}
func clockNS() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func cpuNS() -> UInt64 {
    var t = timespec(); clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t)
    return UInt64(t.tv_sec) * 1_000_000_000 + UInt64(t.tv_nsec)
}
@inline(never) func scalar(_ src: UnsafeRawPointer, _ output: CVPixelBuffer, _ p: Layout) {
    precondition(CVPixelBufferLockBaseAddress(output, []) == kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(output, []) }
    let y = CVPixelBufferGetBaseAddressOfPlane(output, 0)!
    let uv = CVPixelBufferGetBaseAddressOfPlane(output, 1)!.assumingMemoryBound(to: UInt8.self)
    let ys = CVPixelBufferGetBytesPerRowOfPlane(output, 0), cs = CVPixelBufferGetBytesPerRowOfPlane(output, 1)
    let u = src.advanced(by: Int(p.uOffset)).assumingMemoryBound(to: UInt8.self)
    let v = src.advanced(by: Int(p.vOffset)).assumingMemoryBound(to: UInt8.self)
    for row in 0..<Int(p.height) { memcpy(y.advanced(by: row * ys), src.advanced(by: row * Int(p.yStride)), Int(p.width)) }
    for row in 0..<((Int(p.height) + 1) / 2) {
        let d = uv.advanced(by: row * cs), a = u.advanced(by: row * Int(p.cStride)), b = v.advanced(by: row * Int(p.cStride))
        for col in 0..<((Int(p.width) + 1) / 2) { d[col * 2] = a[col]; d[col * 2 + 1] = b[col] }
    }
}
func buffer(_ width: Int, _ height: Int) -> CVPixelBuffer {
    var output: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
        &output) == kCVReturnSuccess)
    return output!
}
func planes(_ buffer: CVPixelBuffer) -> [[UInt8]] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    return (0..<2).map { plane in
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 1 ? 2 : 1)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        return (0..<CVPixelBufferGetHeightOfPlane(buffer, plane)).flatMap {
            Array(UnsafeBufferPointer(start: base.advanced(by: $0 * stride), count: width))
        }
    }
}
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("Metal unavailable") }
print("DEVICE,\(device.name)")
let library = try device.makeLibrary(source: shader, options: nil)
let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "repack")!)
var cache: CVMetalTextureCache?
precondition(CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess)
for (width, height) in [(1280, 720), (1920, 1080), (3840, 2160)] {
    let ys = ((width + 63) / 64) * 64, cs = (((width + 1) / 2 + 63) / 64) * 64
    let u = ys * height, v = u + cs * ((height + 1) / 2), count = v + cs * ((height + 1) / 2)
    var layout = Layout(width: UInt32(width), height: UInt32(height), yStride: UInt32(ys), cStride: UInt32(cs), uOffset: UInt32(u), vOffset: UInt32(v))
    let source = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 64)
    for i in 0..<count { source.storeBytes(of: UInt8(truncatingIfNeeded: i * 31 + i / ys), toByteOffset: i, as: UInt8.self) }
    defer { source.deallocate() }
    let staging = device.makeBuffer(length: count, options: .storageModeShared)!
    let cpuOutput = buffer(width, height), gpuOutput = buffer(width, height)
    var y: CVMetalTexture?, uv: CVMetalTexture?
    precondition(CVMetalTextureCacheCreateTextureFromImage(nil, cache!, gpuOutput, nil,
        .r8Unorm, width, height, 0, &y) == kCVReturnSuccess)
    precondition(CVMetalTextureCacheCreateTextureFromImage(nil, cache!, gpuOutput, nil,
        .rg8Unorm, (width + 1) / 2, (height + 1) / 2, 1, &uv) == kCVReturnSuccess)
    func gpu() -> Double {
        memcpy(staging.contents(), source, count)
        let commands = queue.makeCommandBuffer()!, encoder = commands.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(staging, offset: 0, index: 0)
        encoder.setBytes(&layout, length: MemoryLayout<Layout>.size, index: 1)
        encoder.setTexture(CVMetalTextureGetTexture(y!), index: 0)
        encoder.setTexture(CVMetalTextureGetTexture(uv!), index: 1)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 4, depth: 1))
        encoder.endEncoding(); commands.commit(); commands.waitUntilCompleted()
        precondition(commands.status == .completed, "\(String(describing: commands.error))")
        return (commands.gpuEndTime - commands.gpuStartTime) * 1000
    }
    scalar(source, cpuOutput, layout); _ = gpu()
    precondition(planes(cpuOutput) == planes(gpuOutput), "Pixel mismatch")
    let methods = ["scalar", "Metal-staged"]
    let order = ProcessInfo.processInfo.environment["ROCKNROLL_BENCH_REVERSE"] == "1"
        ? Array(methods.reversed()) : methods
    for name in order {
        for _ in 0..<20 { if name == "scalar" { scalar(source, cpuOutput, layout) } else { _ = gpu() } }
        var latency: [Double] = [], gpuTime: [Double] = []
        let before = cpuNS()
        for i in 0..<200 {
            source.storeBytes(of: UInt8(truncatingIfNeeded: i), toByteOffset: i % count, as: UInt8.self)
            let start = clockNS()
            if name == "scalar" { scalar(source, cpuOutput, layout) } else { gpuTime.append(gpu()) }
            latency.append(Double(clockNS() - start) / 1e6)
        }
        let cpu = Double(cpuNS() - before) / 1e6 / 200
        latency.sort(); gpuTime.sort()
        print("\(width)x\(height),\(name),p50_ms=\(latency[100]),p95_ms=\(latency[190]),cpu_ms_per_frame=\(cpu),gpu_p50_ms=\(gpuTime.isEmpty ? 0 : gpuTime[100]),staging_bytes=\(name == "scalar" ? 0 : count)")
    }
}
