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

    static func make(timeline: CatchUpTimeline, canView: Bool?, enabled: Bool,
                     warning: String?) -> String {
        var lines = [String]()
        if let warning { lines.append(warning) }
        if canView == nil {
            lines.append("Checking jam transcript availability.")
        } else if canView == false {
            lines.append("Transcripts aren’t available in this room.")
        } else if !enabled {
            lines.append("Jam transcription is off. The host may be able to enable it.")
        } else {
            lines.append("Showing transcript lines received by this phone. Coverage is not guaranteed.")
        }

        if timeline.intervals.isEmpty {
            lines.append("No interruptions recorded.")
            if !timeline.segments.isEmpty {
                lines.append("Recent transcript:")
                lines.append(contentsOf: timeline.segments.suffix(8).map(describe))
            }
        } else {
            let count = timeline.unreadCount
            lines.append("\(count) unreviewed missed \(count == 1 ? "section" : "sections").")
            for interval in timeline.intervals.reversed() {
                let start = clock(interval.start)
                let end = interval.end.map(clock) ?? "now"
                lines.append("\nPossibly missed: \(start)–\(end)\(interval.isOngoing ? " (ongoing)" : "")")
                let matching = timeline.transcript(during: interval)
                if matching.isEmpty {
                    lines.append("No timestamped transcript recovered for this section.")
                } else {
                    lines.append(contentsOf: matching.map(describe))
                    lines.append("Other speech may still be missing.")
                }
            }
            let unaligned = timeline.segments.filter { $0.spokenAt == nil }
            if !unaligned.isEmpty {
                lines.append("\nTranscript lines with unknown timing (not assigned to a missed section):")
                lines.append(contentsOf: unaligned.map(describe))
            }
        }
        if timeline.isTruncated {
            lines.append("\nOlder catch-up history was removed from this phone's memory.")
        }
        return lines.joined(separator: "\n")
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
