import Foundation

enum ConferenceDisplayMode: CaseIterable {
    case all
    case screenShares
    case audioOnly

    var title: String {
        switch self {
        case .all: "All video"
        case .screenShares: "Screen shares"
        case .audioOnly: "Audio only"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .screenShares: "rectangle.on.rectangle"
        case .audioOnly: "waveform"
        }
    }
}
