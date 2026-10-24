import Foundation

/// Bounded arrival history for diagnostics. Contains timestamps only, never pixels.
/// The caller synchronizes access. Intervals include stalls crossing either edge.
struct GuestFrameTimeline {
    private var values: [Double]
    private var next = 0
    private var count = 0
    private var total = 0
    init(capacity: Int = 4096) {
        precondition(capacity > 1)
        values = Array(repeating: 0, count: capacity)
    }
    mutating func record(_ time: Double) {
        guard time.isFinite else { return }
        if count > 0, time <= values[(next + values.count - 1) % values.count] { return }
        values[next] = time; next = (next + 1) % values.count
        count = min(count + 1, values.count); total += 1
    }
    func measure(from start: Double, to end: Double) -> GuestFrameWindow {
        guard start.isFinite, end.isFinite, end > start else { return .invalid }
        let oldest = count == values.count ? next : 0
        let history = (0..<count).map { values[(oldest + $0) % values.count] }
        // Lost history inside a requested window cannot qualify smoothness.
        guard total <= values.count || (history.first.map { $0 <= start } ?? false) else { return .invalid }
        var previous = history.last(where: { $0 <= start }) ?? start, maximum = 0.0, frames = 0
        var maximumStart: Double?, maximumEnd: Double?
        for time in history where time > start && time <= end {
            if time - previous > maximum { maximum = time - previous; maximumStart = previous; maximumEnd = time }
            previous = time; frames += 1
        }
        if end - previous > maximum { maximum = end - previous; maximumStart = previous; maximumEnd = end }
        let age = history.last(where: { $0 <= end }).map { end - $0 }
        return .init(complete: true, seconds: end - start, frames: frames,
            maximumGap: maximum, endFrameAge: age, maximumGapStart: maximumStart, maximumGapEnd: maximumEnd)
    }
}

struct GuestFrameWindow {
    let complete: Bool
    let seconds: Double
    let frames: Int
    let maximumGap: Double
    let endFrameAge: Double?
    let maximumGapStart: Double?
    let maximumGapEnd: Double?
    init(complete: Bool, seconds: Double, frames: Int, maximumGap: Double, endFrameAge: Double?,
         maximumGapStart: Double? = nil, maximumGapEnd: Double? = nil) {
        self.complete = complete; self.seconds = seconds; self.frames = frames
        self.maximumGap = maximumGap; self.endFrameAge = endFrameAge
        self.maximumGapStart = maximumGapStart; self.maximumGapEnd = maximumGapEnd
    }
    static let invalid = Self(complete: false, seconds: 0, frames: 0, maximumGap: 0, endFrameAge: nil)
    var fps: Double { seconds > 0 ? Double(frames) / seconds : 0 }
    var smooth: Bool {
        complete && fps >= 12 && maximumGap < 1 && endFrameAge.map { $0 < 0.5 } == true
    }
    var evidence: [String: Any] {
        ["complete": complete, "seconds": seconds, "frames": frames, "fps": fps,
         "maximumGap": maximumGap, "endFrameAge": endFrameAge as Any? ?? NSNull(), "smooth": smooth,
         "maximumGapStart": maximumGapStart as Any? ?? NSNull(),
         "maximumGapEnd": maximumGapEnd as Any? ?? NSNull()]
    }
}
