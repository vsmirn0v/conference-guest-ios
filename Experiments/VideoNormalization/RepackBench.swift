import Accelerate
import Foundation
import Darwin

@inline(never) func scalar(_ u: UnsafePointer<UInt8>, _ v: UnsafePointer<UInt8>, _ dst: UnsafeMutablePointer<UInt8>, _ width: Int, _ height: Int, _ sourceStride: Int, _ destStride: Int) {
    for row in 0..<height {
        let d = dst.advanced(by: row * destStride)
        let a = u.advanced(by: row * sourceStride)
        let b = v.advanced(by: row * sourceStride)
        for column in 0..<width { d[column * 2] = a[column]; d[column * 2 + 1] = b[column] }
    }
}
@inline(never) func accelerated(_ u: UnsafePointer<UInt8>, _ v: UnsafePointer<UInt8>, _ dst: UnsafeMutablePointer<UInt8>, _ width: Int, _ height: Int, _ sourceStride: Int, _ destStride: Int) {
    var a = vImage_Buffer(data: UnsafeMutableRawPointer(mutating:u), height: UInt(height), width: UInt(width), rowBytes: sourceStride)
    var b = vImage_Buffer(data: UnsafeMutableRawPointer(mutating:v), height: UInt(height), width: UInt(width), rowBytes: sourceStride)
    withUnsafePointer(to: &a) { ap in withUnsafePointer(to: &b) { bp in
        var sources: [UnsafePointer<vImage_Buffer>?] = [ap, bp]
        var destinations: [UnsafeMutableRawPointer?] = [UnsafeMutableRawPointer(dst), UnsafeMutableRawPointer(dst.advanced(by: 1))]
        let result = vImageConvert_PlanarToChunky8(&sources, &destinations, 2, 2, UInt(width), UInt(height), destStride, vImage_Flags(kvImageDoNotTile))
        precondition(result == kvImageNoError)
    }}
}
func clockNS() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func cpuNS() -> UInt64 { var t=timespec(); clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t); return UInt64(t.tv_sec)*1_000_000_000+UInt64(t.tv_nsec) }
for (w,h) in [(1280,720),(1920,1080),(3840,2160)] {
    let cw=(w+1)/2, ch=(h+1)/2, ss=((cw+63)/64)*64, ds=((2*cw+63)/64)*64
    let u=UnsafeMutablePointer<UInt8>.allocate(capacity:ss*ch), v=UnsafeMutablePointer<UInt8>.allocate(capacity:ss*ch)
    let a=UnsafeMutablePointer<UInt8>.allocate(capacity:ds*ch), b=UnsafeMutablePointer<UInt8>.allocate(capacity:ds*ch)
    for i in 0..<(ss*ch) { u[i]=UInt8(truncatingIfNeeded:i*37); v[i]=UInt8(truncatingIfNeeded:i*61) }
    a.initialize(repeating:0,count:ds*ch); b.initialize(repeating:0,count:ds*ch)
    scalar(u,v,a,cw,ch,ss,ds); accelerated(u,v,b,cw,ch,ss,ds)
    for row in 0..<ch { for col in 0..<cw*2 { precondition(a[row*ds+col] == b[row*ds+col]) }}
    let methods = [("scalar",scalar),("vImage",accelerated)]
    let order = ProcessInfo.processInfo.environment["ROCKNROLL_BENCH_REVERSE"] == "1"
        ? Array(methods.reversed()) : methods
    for (name, fn) in order {
        for _ in 0..<20 { fn(u,v,b,cw,ch,ss,ds) }
        var values:[Double]=[]
        let c=cpuNS()
        for i in 0..<200 { u[i % (ss*ch)] = UInt8(truncatingIfNeeded:i); let start=clockNS(); fn(u,v,b,cw,ch,ss,ds); values.append(Double(clockNS()-start)/1e6) }
        let cpu=Double(cpuNS()-c)/1e6
        values.sort()
        print("\(w)x\(h),\(name),p50_ms=\(values[100]),p95_ms=\(values[190]),cpu_ms_per_frame=\(cpu/200)")
    }
    u.deallocate();v.deallocate();a.deallocate();b.deallocate()
}
