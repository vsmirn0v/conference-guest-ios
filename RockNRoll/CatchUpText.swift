import ConferenceCore
import Foundation

enum CatchUpText {
    static func make(timeline: CatchUpTimeline, canView: Bool?, enabled: Bool,
                     warning: String?) -> String {
        var lines = [String]()
        if let warning { lines.append(warning) }
        if canView == nil {
            lines.append("Checking meeting transcript availability.")
        } else if canView == false {
            lines.append("A transcript is not available to this guest in this meeting.")
        } else if !enabled {
            lines.append("Meeting transcription is off. The host may be able to enable it.")
        } else {
            lines.append("Showing transcript lines received by this phone. Coverage is not guaranteed.")
        }

        if timeline.intervals.isEmpty {
            lines.append("No suspected missed sections yet.")
            if !timeline.segments.isEmpty {
                lines.append("Recent transcript:")
                lines.append(contentsOf: timeline.segments.suffix(8).map(describe))
            }
        } else {
            lines.append("\(timeline.unreadCount) unreviewed missed section(s).")
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
