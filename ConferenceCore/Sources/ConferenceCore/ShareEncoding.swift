import Foundation

/// A device-local preference for content sharing, independent of camera/audio.
/// A running share captures this value at explicit Start; reconnect and source
/// replacement must reuse that captured value rather than reread defaults.
public enum ShareEncodingPreference: String, CaseIterable, Identifiable, Sendable {
    case efficient, textDetail
    public var id: String { rawValue }
    public var codec: String { self == .textDetail ? "vp9" : "h264" }
    public static let defaultsKey = "sharing.encodingPreference"
    public static func saved(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .efficient
    }
    public func save(in defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.defaultsKey) }
}

/// Report negotiated evidence separately from the user's requested preference.
/// Unknown implementation is intentional until encoder statistics confirm it.
public struct ShareEncodingReport: Equatable, Sendable {
    public enum Implementation: String, Sendable { case unknown, hardware, software }
    public let codec: String
    public let implementation: Implementation
    public init(codec: String, implementation: Implementation = .unknown) {
        self.codec = codec.lowercased(); self.implementation = implementation
    }
    public var summary: String {
        let name = codec.uppercased()
        let detail: String
        switch implementation {
        case .unknown: detail = ""
        case .hardware: detail = " · " + CoreL("Hardware")
        case .software: detail = " · " + CoreL("Software")
        }
        return String(format: CoreL("Sending %@"), name) + detail
    }
    public static func measured(codec: String, powerEfficient: Bool?, encoder: String? = nil) -> Self {
        // A false power-efficiency flag alone does not prove software encoding.
        let implementation: Implementation
        if powerEfficient == true || encoder == "VideoToolbox" { implementation = .hardware }
        else if encoder == "libvpx" || encoder == "libvpx-vp9" || encoder == "libvpx-vp8" { implementation = .software }
        else { implementation = .unknown }
        return .init(codec: codec, implementation: implementation)
    }
}
