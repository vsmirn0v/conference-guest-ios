import CoreMedia
import Foundation

/// Ordinary camera output only. Sensor selection, rotation, screen sharing and
/// Presenter composition belong to their existing owners.
struct CameraQualityPolicy {
    enum Tier: Int { case constrained, balance, high }
    enum Power { case connected, battery, unknown }
    /// Adapters qualify distinct transport samples (including two poor samples)
    /// before updating this policy. Missing evidence must remain unknown.
    enum Network { case unknown, excellent, ordinary, poor }
    struct Profile: Equatable {
        let tier: Tier
        let fps: Int
        var maximum: CMVideoDimensions {
            switch tier {
            case .high: CMVideoDimensions(width: 1280, height: 720)
            case .balance: CMVideoDimensions(width: 960, height: 540)
            case .constrained: CMVideoDimensions(width: 640, height: 360)
            }
        }
    }

    private var current: Profile?
    private var lastTransition: TimeInterval?
    private var lastUpdate: TimeInterval?
    private var pendingUpgrade: (profile: Profile, since: TimeInterval)?

    /// Call on publication/route generation changes; old samples cannot qualify
    /// an upgrade for a new transport. The next update establishes a fresh tier.
    mutating func reset() {
        current = nil; lastTransition = nil; lastUpdate = nil; pendingUpgrade = nil
    }

    mutating func update(power: Power, network: Network, pressure: MediaEnergyBudget.Pressure,
                         constrainedPath: Bool, at time: TimeInterval) -> Profile {
        let restricted = pressure != .normal || constrainedPath
        let desired: Profile
        if restricted || network == .poor {
            desired = Profile(tier: .constrained, fps: pressure == .severe ? 10 : 15)
        } else if power == .connected || network == .excellent {
            desired = Profile(tier: .high, fps: 24)
        } else {
            desired = Profile(tier: .balance, fps: 20)
        }
        guard let current else { return commit(desired, at: time.isFinite ? time : nil) }
        let decreases = desired.tier.rawValue < current.tier.rawValue ||
            (desired.tier == current.tier && desired.fps < current.fps)
        guard time.isFinite else {
            pendingUpgrade = nil
            return restricted && decreases ? commit(desired, at: nil) : current
        }
        if lastUpdate.map({ time < $0 }) ?? false {
            pendingUpgrade = nil; lastTransition = time
        }
        lastUpdate = time
        if lastTransition == nil { lastTransition = time }
        guard desired != current else { pendingUpgrade = nil; return current }
        let dwellElapsed = time - (lastTransition ?? time) >= 10
        if decreases {
            pendingUpgrade = nil
            return restricted || dwellElapsed ? commit(desired, at: time) : current
        }
        if pendingUpgrade?.profile != desired { pendingUpgrade = (desired, time) }
        guard let pendingUpgrade, time - pendingUpgrade.since >= 30, dwellElapsed else { return current }
        return commit(desired, at: time)
    }

    private mutating func commit(_ profile: Profile, at time: TimeInterval?) -> Profile {
        current = profile; lastTransition = time; lastUpdate = time; pendingUpgrade = nil
        return profile
    }

    /// Preserve orientation and exact aspect where possible, without upscaling.
    /// Unusual dimensions use even-pixel rounding instead of escaping the cap.
    /// Zero dimensions signal an invalid or sub-two-pixel input/bound.
    static func bounded(_ dimensions: CMVideoDimensions, maximum: CMVideoDimensions) -> CMVideoDimensions {
        guard dimensions.width >= 2, dimensions.height >= 2, maximum.width >= 2, maximum.height >= 2 else {
            return CMVideoDimensions(width: 0, height: 0)
        }
        let width = Int64(dimensions.width), height = Int64(dimensions.height)
        let long = Int64(max(maximum.width, maximum.height)), short = Int64(min(maximum.width, maximum.height))
        let widthLimit = min(width, width >= height ? long : short) / 2 * 2
        let heightLimit = min(height, width >= height ? short : long) / 2 * 2
        var divisor = width, remainder = height
        while remainder != 0 { let next = divisor % remainder; divisor = remainder; remainder = next }
        let unitWidth = width / divisor, unitHeight = height / divisor
        var multiplier = min(divisor, min(widthLimit / unitWidth, heightLimit / unitHeight))
        if unitWidth % 2 != 0 || unitHeight % 2 != 0 { multiplier = multiplier / 2 * 2 }
        if multiplier > 0 {
            return CMVideoDimensions(width: Int32(unitWidth * multiplier), height: Int32(unitHeight * multiplier))
        }
        let scale = min(Double(widthLimit) / Double(width), Double(heightLimit) / Double(height))
        let roundedWidth = Int64((Double(width) * scale / 2).rounded()) * 2
        let roundedHeight = Int64((Double(height) * scale / 2).rounded()) * 2
        return CMVideoDimensions(width: Int32(max(2, min(widthLimit, roundedWidth))),
                                 height: Int32(max(2, min(heightLimit, roundedHeight))))
    }
}
