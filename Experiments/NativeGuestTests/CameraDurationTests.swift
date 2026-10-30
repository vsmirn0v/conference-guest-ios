import AVFoundation
import Foundation

@main struct CameraDurationTests {
    static func main() {
        let thirty = CMTime(value: 1, timescale: 30)
        let fifteen = CMTime(value: 1, timescale: 15)
        let advertised = GuestCameraDurationRange(shortest: CMTime(value: 1_000_000, timescale: 30_000_000),
                                                   longest: CMTime(value: 1_000_000, timescale: 15_000_000))
        checkSelection([advertised], expected: thirty)
        let oldRounded = CMTime(value: 33_333_333, timescale: 1_000_000_000)
        precondition(CMTimeCompare(oldRounded, advertised.shortest) < 0, "Regression fixture must exceed the 30 fps boundary")
        precondition(!GuestCameraTiming.validProfile(minimum: oldRounded, maximum: oldRounded, ranges: [advertised]))
        checkSelection([.init(shortest: fifteen, longest: fifteen)], expected: fifteen)
        let ntsc = CMTime(value: 1001, timescale: 30_000)
        checkSelection([.init(shortest: ntsc, longest: ntsc)], expected: ntsc)
        checkSelection([.init(shortest: ntsc, longest: fifteen)], expected: ntsc)
        checkSelection([.init(shortest: CMTime(value: 1, timescale: 60), longest: fifteen)], expected: thirty)
        checkSelection([.init(shortest: fifteen, longest: fifteen), advertised], expected: thirty)
        precondition(GuestCameraTiming.duration(in: [.init(shortest: CMTime(value: 1, timescale: 120),
                                                          longest: CMTime(value: 1, timescale: 60))]) == nil)
        precondition(GuestCameraTiming.duration(in: [.init(shortest: .invalid, longest: fifteen)]) == nil)
        precondition(GuestCameraTiming.duration(in: [.init(shortest: fifteen, longest: thirty)]) == nil)
        precondition(GuestCameraTiming.duration(in: [.init(shortest: .zero, longest: fifteen)]) == nil)
        // A valid saved variable-rate profile retains its original rationals.
        let savedMinimum = advertised.shortest, savedMaximum = advertised.longest
        precondition(GuestCameraTiming.validProfile(minimum: savedMinimum, maximum: savedMaximum, ranges: [advertised]))
        precondition(savedMinimum.value == 1_000_000 && savedMinimum.timescale == 30_000_000)
        precondition(savedMaximum.value == 1_000_000 && savedMaximum.timescale == 15_000_000)
        precondition(!GuestCameraTiming.validProfile(minimum: fifteen, maximum: thirty, ranges: [advertised]))
        precondition(!GuestCameraTiming.validProfile(minimum: .invalid, maximum: fifteen, ranges: [advertised]))
        // Background replacement cadence: an advertised 15–30 range yields exactly 1/24,
        // and a range that cannot slow to 24 keeps its slowest supported rate.
        let background = GuestCameraCadence.backgroundReplacementFPS
        precondition(background == 24 && GuestCameraCadence.standardFPS == 30)
        let twentyFour = CMTime(value: 1, timescale: 24)
        guard let reduced = GuestCameraTiming.duration(in: [advertised], preferredFPS: background) else { preconditionFailure("No 24 fps duration") }
        precondition(CMTimeCompare(reduced, twentyFour) == 0)
        precondition(GuestCameraTiming.validProfile(minimum: reduced, maximum: reduced, ranges: [advertised]))
        let fixedThirty = [GuestCameraDurationRange(shortest: thirty, longest: thirty)]
        precondition(GuestCameraTiming.duration(in: fixedThirty, maximumFPS: background) == nil)
        guard let fixed = GuestCameraTiming.duration(in: fixedThirty, preferredFPS: background) else {
            preconditionFailure("A fixed 30 fps format must remain eligible")
        }
        precondition(CMTimeCompare(fixed, thirty) == 0)
        guard let standard = GuestCameraTiming.duration(in: [advertised], preferredFPS: GuestCameraCadence.standardFPS) else {
            preconditionFailure("No standard duration")
        }
        precondition(CMTimeCompare(standard, thirty) == 0)
        print("PASS: rational 30fps boundary, 15fps, NTSC, 24fps background cadence, profile bounds and original duration preservation")
    }

    private static func checkSelection(_ ranges: [GuestCameraDurationRange], expected: CMTime) {
        guard let selected = GuestCameraTiming.duration(in: ranges) else { preconditionFailure("No supported duration selected") }
        precondition(CMTimeCompare(selected, expected) == 0)
        precondition(CMTimeCompare(selected, CMTime(value: 1, timescale: 30)) >= 0, "Selected cadence exceeds 30 fps")
        precondition(GuestCameraTiming.validProfile(minimum: selected, maximum: selected, ranges: ranges), "Selected duration is outside advertised bounds")
    }
}
