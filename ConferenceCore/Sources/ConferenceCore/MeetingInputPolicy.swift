import Foundation

public struct MeetingInputPolicy: Sendable {
    public let maximumNameScalars: Int
    public init(maximumNameScalars: Int) { self.maximumNameScalars = maximumNameScalars }
    public func accepts(name: String) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !clean.isEmpty && clean.unicodeScalars.count <= maximumNameScalars &&
            !clean.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

public extension JoinDestination {
    var inputPolicy: MeetingInputPolicy {
        switch self {
        case .jam: MeetingInputPolicy(maximumNameScalars: 60)
        case .guest: MeetingInputPolicy(maximumNameScalars: 80)
        }
    }
}
