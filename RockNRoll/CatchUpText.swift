import ConferenceCore
import Foundation

enum CatchUpText {
    static func live(timeline: CatchUpTimeline, canView: Bool?, enabled: Bool) -> String {
        if canView == false { return "Transcripts aren’t available in this room." }
        if canView == nil { return "Checking transcript availability…" }
        if !enabled { return "Transcription is off in this room." }
        guard !timeline.segments.isEmpty else { return "Waiting for spoken words…" }
        let lines = timeline.segments.sorted {
            ($0.spokenAt ?? .distantFuture) < ($1.spokenAt ?? .distantFuture)
        }.map(describe)
        return lines.joined(separator: "\n\n") +
            (timeline.isTruncated ? "\n\nOlder lines have left this phone’s memory." : "")
    }

    private static func describe(_ segment: TranscriptSegment) -> String {
        let speaker = segment.speaker?.isEmpty == false ? segment.speaker! : "Participant"
        let time = segment.spokenAt.map { "[\(clock($0))] " } ?? ""
        return "\(time)\(speaker): \(segment.text)"
    }

    private static func clock(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }
}
