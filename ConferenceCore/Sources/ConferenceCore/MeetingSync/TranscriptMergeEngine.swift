import Foundation

public enum TranscriptMergeEngine {
    public static func merge(chunks: [SyncedTranscriptChunk]) -> [SyncedTranscriptEvent] {
        let activeChunks = chunks.filter { !$0.isDeleted }
        guard !activeChunks.isEmpty else { return [] }

        var micIntervalsByDevice: [String: [DateInterval]] = [:]
        var legIntervalsByDevice: [String: DateInterval] = [:]
        var devicesWithGaplessCoverage: Set<String> = []
        var gapIntervalsByDevice: [String: [DateInterval]] = [:]

        for chunk in activeChunks {
            if !chunk.micActiveIntervals.isEmpty {
                micIntervalsByDevice[chunk.deviceID, default: []].append(contentsOf: chunk.micActiveIntervals)
            }
            let chunkEnd = max(
                chunk.sessionStartedAt,
                chunk.sessionEndedAt ?? chunk.events.map { $0.endedAt ?? $0.occurredAt }.max() ?? chunk.sessionStartedAt
            )
            let span = DateInterval(start: chunk.sessionStartedAt, end: chunkEnd)
            if let existing = legIntervalsByDevice[chunk.deviceID] {
                legIntervalsByDevice[chunk.deviceID] = DateInterval(
                    start: min(existing.start, span.start),
                    end: max(existing.end, span.end)
                )
            } else {
                legIntervalsByDevice[chunk.deviceID] = span
            }
            let gaps = chunk.events.filter { $0.kind == "captureGap" }.map { event in
                DateInterval(start: event.occurredAt, end: max(event.occurredAt, event.endedAt ?? event.occurredAt))
            }
            gapIntervalsByDevice[chunk.deviceID, default: []].append(contentsOf: gaps)
        }
        for (deviceID, _) in legIntervalsByDevice {
            if (gapIntervalsByDevice[deviceID] ?? []).isEmpty {
                devicesWithGaplessCoverage.insert(deviceID)
            }
        }

        // 1. Exact provider ID deduplication for server captions and chat messages.
        struct ProviderKey: Hashable {
            let kind: String
            let providerMessageID: String
        }
        var byProviderKey: [ProviderKey: SyncedTranscriptEvent] = [:]
        var passthrough: [SyncedTranscriptEvent] = []

        for chunk in activeChunks {
            for event in chunk.events {
                if let msgID = event.providerMessageID, !msgID.isEmpty {
                    let key = ProviderKey(kind: event.kind, providerMessageID: msgID)
                    if let existing = byProviderKey[key] {
                        byProviderKey[key] = mergeSameProviderEvent(existing, event)
                    } else {
                        byProviderKey[key] = event
                    }
                } else {
                    passthrough.append(event)
                }
            }
        }

        let combined = Array(byProviderKey.values) + passthrough

        // 2. Suppress own-speech echoes captured on a muted/non-mic secondary device when
        // another device held the active microphone at that timestamp.
        let nonMicOwnSuppressed = combined.filter { event in
            guard event.kind == "transcript", event.isOwn, event.providerMessageID == nil else {
                return true
            }
            let localHadMic = hasMicCoverage(deviceID: event.deviceID, at: event.occurredAt, map: micIntervalsByDevice)
            if localHadMic { return true }
            let otherHadMic = micIntervalsByDevice.contains { deviceID, intervals in
                deviceID != event.deviceID &&
                    intervals.contains { $0.start.addingTimeInterval(-1.5) <= event.occurredAt &&
                        event.occurredAt <= $0.end.addingTimeInterval(1.5) }
            }
            return !otherHadMic
        }

        // 3. Fuzzy local-ASR deduplication across distinct devices.
        let ordered = nonMicOwnSuppressed.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            if $0.sourceTier != $1.sourceTier { return $0.sourceTier > $1.sourceTier }
            return $0.id < $1.id
        }

        var transcriptKept: [SyncedTranscriptEvent] = []
        var nonTranscriptKept: [SyncedTranscriptEvent] = []

        for event in ordered {
            if event.kind != "transcript" {
                if let duplicateIndex = nonTranscriptKept.firstIndex(where: {
                    $0.kind == event.kind && $0.id == event.id
                }) {
                    nonTranscriptKept[duplicateIndex] = mergeSameProviderEvent(nonTranscriptKept[duplicateIndex], event)
                } else {
                    nonTranscriptKept.append(event)
                }
                continue
            }

            if let matchIndex = transcriptKept.lastIndex(where: { existing in
                abs(existing.occurredAt.timeIntervalSince(event.occurredAt)) <= 4.0 &&
                    (existing.deviceID != event.deviceID || existing.id == event.id) &&
                    isFuzzyTranscriptMatch(existing, event)
            }) {
                let winner = pickBetterTranscript(transcriptKept[matchIndex], event)
                transcriptKept[matchIndex] = winner
            } else {
                transcriptKept.append(event)
            }
        }

        // 4. Heal captureGap events if another device leg captured speech over that interval.
        let healedNonTranscript = nonTranscriptKept.filter { event in
            guard event.kind == "captureGap" else { return true }
            let gapStart = event.occurredAt
            let gapEnd = max(event.occurredAt, event.endedAt ?? event.occurredAt)
            let coveredByOtherSpeech = transcriptKept.contains { speech in
                speech.deviceID != event.deviceID &&
                    speech.occurredAt >= gapStart.addingTimeInterval(-3.0) &&
                    speech.occurredAt <= gapEnd.addingTimeInterval(3.0)
            }
            if coveredByOtherSpeech { return false }
            let coveredByOtherLeg = legIntervalsByDevice.contains { deviceID, span in
                deviceID != event.deviceID &&
                    span.start <= gapStart.addingTimeInterval(2.0) &&
                    span.end >= gapEnd.addingTimeInterval(-2.0) &&
                    (devicesWithGaplessCoverage.contains(deviceID) ||
                     !(gapIntervalsByDevice[deviceID] ?? []).contains { $0.intersects(DateInterval(start: gapStart, end: gapEnd)) })
            }
            return !coveredByOtherLeg
        }

        return (transcriptKept + healedNonTranscript).sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            return $0.id < $1.id
        }
    }

    private static func hasMicCoverage(
        deviceID: String,
        at date: Date,
        map: [String: [DateInterval]]
    ) -> Bool {
        guard let intervals = map[deviceID] else { return false }
        return intervals.contains {
            $0.start.addingTimeInterval(-1.5) <= date && date <= $0.end.addingTimeInterval(1.5)
        }
    }

    private static func mergeSameProviderEvent(
        _ lhs: SyncedTranscriptEvent,
        _ rhs: SyncedTranscriptEvent
    ) -> SyncedTranscriptEvent {
        let preferRHS = (rhs.sourceTier, rhs.revisions.count, rhs.text.count, rhs.deviceID) >
            (lhs.sourceTier, lhs.revisions.count, lhs.text.count, lhs.deviceID)
        var winner = preferRHS ? rhs : lhs
        winner.isBookmarked = lhs.isBookmarked || rhs.isBookmarked
        var seenRevisions = Set(winner.revisions.map { "\($0.observedAt.syncMilliseconds)|\($0.text)" })
        for revision in (lhs.revisions + rhs.revisions) {
            let key = "\(revision.observedAt.syncMilliseconds)|\(revision.text)"
            if seenRevisions.insert(key).inserted {
                winner.revisions.append(revision)
            }
        }
        winner.revisions.sort { $0.observedAt < $1.observedAt }
        if let latest = winner.revisions.last, winner.revisions.count > 1 {
            winner.text = latest.text
            winner.speaker = latest.author ?? winner.speaker
        }
        return winner
    }

    private static func pickBetterTranscript(
        _ lhs: SyncedTranscriptEvent,
        _ rhs: SyncedTranscriptEvent
    ) -> SyncedTranscriptEvent {
        let preferRHS = (rhs.sourceTier, rhs.text.count, rhs.deviceID) >
            (lhs.sourceTier, lhs.text.count, lhs.deviceID)
        var winner = preferRHS ? rhs : lhs
        winner.isBookmarked = lhs.isBookmarked || rhs.isBookmarked
        winner.occurredAt = min(lhs.occurredAt, rhs.occurredAt)
        return winner
    }

    private static func isFuzzyTranscriptMatch(
        _ lhs: SyncedTranscriptEvent,
        _ rhs: SyncedTranscriptEvent
    ) -> Bool {
        if lhs.id == rhs.id { return true }
        let speakerA = normalizedSpeaker(lhs.speaker)
        let speakerB = normalizedSpeaker(rhs.speaker)
        if !speakerA.isEmpty && !speakerB.isEmpty && speakerA != speakerB {
            return false
        }
        let tokensA = tokens(lhs.text)
        let tokensB = tokens(rhs.text)
        guard !tokensA.isEmpty && !tokensB.isEmpty else { return false }
        let setA = Set(tokensA)
        let setB = Set(tokensB)
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        let jaccard = union > 0 ? Double(intersection) / Double(union) : 0
        if jaccard >= 0.65 { return true }
        let minCount = min(setA.count, setB.count)
        let containment = minCount > 0 ? Double(intersection) / Double(minCount) : 0
        return minCount >= 3 && containment >= 0.80
    }

    private static func normalizedSpeaker(_ speaker: String?) -> String {
        guard let speaker else { return "" }
        let clean = speaker.workspaceFolded.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["participant", "speaker", "unknown", "участник", "неизвестный"].contains(clean) {
            return ""
        }
        return clean
    }

    private static func tokens(_ text: String) -> [String] {
        text.workspaceFolded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
