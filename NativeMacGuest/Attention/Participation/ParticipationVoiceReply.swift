import Foundation

enum ParticipationOutput: String, CaseIterable, Codable, Identifiable, Sendable {
    case chat, voice

    var id: Self { self }
    var title: String { self == .chat ? L("Chat") : L("Voice") }
}

struct ParticipationVoiceReply: Identifiable, Equatable {
    enum Status: Equatable {
        case textOnly, preparing, speaking, completed, interrupted, unknown, synthesisFailed

        var title: String {
            switch self {
            case .textOnly: L("Text only · Only you")
            case .preparing: L("Preparing speech")
            case .speaking: L("Assistant speaking")
            case .completed: L("Played into meeting audio")
            case .interrupted: L("Speech interrupted")
            case .unknown: L("Voice playback unknown")
            case .synthesisFailed: L("Selected voice unavailable · Only you")
            }
        }
    }

    let id: String
    let text: String
    let createdAt: Date
    var status: Status
}
