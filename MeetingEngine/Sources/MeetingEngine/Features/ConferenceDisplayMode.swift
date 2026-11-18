import Foundation

public enum ConferenceDisplayMode: CaseIterable {
    case all
    case screenShares
    case audioOnly

    public var title: String {
        switch self {
        case .all: L("All video")
        case .screenShares: L("Screen shares")
        case .audioOnly: L("Audio only")
        }
    }

    public var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .screenShares: "rectangle.on.rectangle"
        case .audioOnly: "waveform"
        }
    }
}
