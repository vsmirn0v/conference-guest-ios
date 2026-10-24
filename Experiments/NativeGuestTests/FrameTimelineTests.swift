import Foundation

@main struct FrameTimelineTests {
    static func main() {
        var steady = GuestFrameTimeline()
        for n in 0...150 { steady.record(Double(n) / 15) }
        let full = steady.measure(from: 0, to: 10)
        precondition(full.complete && full.frames == 150 && full.smooth)
        precondition(abs(full.fps - 15) < 1e-9 && full.maximumGap < 0.067)
        // Historical reconnect gap cannot pollute a subsequent steady interval.
        var reconnect = GuestFrameTimeline()
        reconnect.record(0); reconnect.record(5)
        for n in 1...150 { reconnect.record(5 + Double(n) / 15) }
        precondition(reconnect.measure(from: 5, to: 15).smooth)
        precondition(!reconnect.measure(from: 0, to: 10).smooth)
        // Pending and crossing gaps count even when no new frame completes them.
        let pending = steady.measure(from: 9, to: 12)
        precondition(pending.maximumGap == 2 && pending.endFrameAge == 2 && !pending.smooth)
        precondition(pending.maximumGapStart == 10 && pending.maximumGapEnd == 12)
        let empty = steady.measure(from: 12, to: 14)
        precondition(empty.frames == 0 && empty.maximumGap == 4 && empty.endFrameAge == 4 && !empty.smooth)
        var boundary = GuestFrameTimeline()
        boundary.record(0); boundary.record(3)
        precondition(boundary.measure(from: 1, to: 2).maximumGap == 2)
        precondition(boundary.measure(from: 1, to: 4).maximumGap == 3)
        precondition(boundary.measure(from: 1, to: 4).maximumGapStart == 0 &&
                     boundary.measure(from: 1, to: 4).maximumGapEnd == 3)
        // A pause spanning two measurement windows must not be clipped into two passing gaps.
        var split = GuestFrameTimeline()
        for n in 0...63 { split.record(Double(n) / 15) }
        for n in 87...150 { split.record(Double(n) / 15) }
        precondition(abs(split.measure(from: 5, to: 10).maximumGap - 1.6) < 1e-9)
        precondition(!split.measure(from: 5, to: 10).smooth)
        // Overflow may not silently qualify a window whose arrivals were evicted.
        var small = GuestFrameTimeline(capacity: 4)
        for n in 0...5 { small.record(Double(n)) }
        precondition(!small.measure(from: 0, to: 5).complete)
        precondition(small.measure(from: 2, to: 5).complete)
        small.record(.nan); small.record(.infinity); small.record(4); small.record(5)
        precondition(small.measure(from: 2, to: 5).frames == 3)
        precondition(!small.measure(from: 5, to: 5).complete)
        precondition(!small.measure(from: .nan, to: 5).complete)
        precondition(!GuestFrameWindow(complete: true, seconds: 10, frames: 119, maximumGap: 0.2, endFrameAge: 0).smooth)
        precondition(!GuestFrameWindow(complete: true, seconds: 10, frames: 150, maximumGap: 1, endFrameAge: 0).smooth)
        precondition(!GuestFrameWindow(complete: true, seconds: 10, frames: 150, maximumGap: 0.2, endFrameAge: 0.5).smooth)
        print("PASS: window-local frame cadence, boundary/pending stalls, ring overflow and strict quality thresholds")
    }
}
