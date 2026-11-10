import ConferenceCore
import Foundation

enum LiveTranscriptRow: Equatable {
    case line(TranscriptSegment)
    case reaction(MeetingReactionEvent)
}

enum LiveTranscriptTimeline {
    /// Desktop parity: transcript lines and reactions share one chronological
    /// stream. Undated lines retain their original segment and display timestamp;
    /// only their internal sort date is inherited from the preceding line.
    static func rows(segments: [TranscriptSegment],
                     reactions: [MeetingReactionEvent]) -> [LiveTranscriptRow] {
        var ordered: [(date: Date, order: Int, row: LiveTranscriptRow)] = []
        var last = Date.distantPast
        var order = 0

        for segment in segments {
            let date = segment.spokenAt ?? last
            last = date
            ordered.append((date, order, .line(segment)))
            order += 1
        }

        let cutoff = segments.compactMap(\.spokenAt).first
        let visibleReactions = cutoff.map { date in
            reactions.filter { $0.timestamp >= date }
        } ?? reactions
        for event in visibleReactions {
            ordered.append((event.timestamp, order, .reaction(event)))
            order += 1
        }

        return ordered.sorted {
            $0.date == $1.date ? $0.order < $1.order : $0.date < $1.date
        }.map(\.row)
    }
}
