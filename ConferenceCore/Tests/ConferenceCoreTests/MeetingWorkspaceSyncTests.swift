import Foundation
import XCTest
@testable import ConferenceCore

final class MeetingWorkspaceSyncTests: XCTestCase {
    func testNoteThreeWayMergeDisjointEditsAndConvergence() {
        let vMac = SyncVersion(counter: 2, device: "mac-1")
        let vPhone = SyncVersion(counter: 2, device: "ios-1")
        let base = """
        # Agenda
        - Intro
        - Budget review
        - Wrap up
        """
        let macEdit = """
        # Agenda
        - Intro (Alice joined)
        - Budget review
        - Wrap up
        """
        let phoneEdit = """
        # Agenda
        - Intro
        - Budget review
        - Wrap up
        - Action: send notes
        """

        let mergedAB = NoteThreeWayMerger.merge(
            base: base,
            local: macEdit,
            localVersion: vMac,
            remote: phoneEdit,
            remoteVersion: vPhone
        )
        let mergedBA = NoteThreeWayMerger.merge(
            base: base,
            local: phoneEdit,
            localVersion: vPhone,
            remote: macEdit,
            remoteVersion: vMac
        )
        XCTAssertFalse(mergedAB.hadConflict)
        XCTAssertEqual(mergedAB.markdown, mergedBA.markdown)
        XCTAssertTrue(mergedAB.markdown.contains("Alice joined"))
        XCTAssertTrue(mergedAB.markdown.contains("Action: send notes"))

        // Subsequent merge against converged remote does not duplicate lines.
        let followUp = NoteThreeWayMerger.merge(
            base: base,
            local: phoneEdit,
            localVersion: vPhone,
            remote: mergedAB.markdown,
            remoteVersion: SyncVersion(counter: 3, device: "mac-1")
        )
        XCTAssertEqual(followUp.markdown, mergedAB.markdown)
    }

    func testNoteThreeWayMergeSameLineConflictPreservesBothDeterministically() {
        let vMac = SyncVersion(counter: 4, device: "mac-a")
        let vPhone = SyncVersion(counter: 5, device: "ios-b")
        let base = "Deadline: Tuesday"
        let macEdit = "Deadline: Wednesday"
        let phoneEdit = "Deadline: Friday"

        let ab = NoteThreeWayMerger.merge(
            base: base,
            local: macEdit,
            localVersion: vMac,
            remote: phoneEdit,
            remoteVersion: vPhone
        )
        let ba = NoteThreeWayMerger.merge(
            base: base,
            local: phoneEdit,
            localVersion: vPhone,
            remote: macEdit,
            remoteVersion: vMac
        )
        XCTAssertTrue(ab.hadConflict)
        XCTAssertEqual(ab.markdown, ba.markdown)
        XCTAssertTrue(ab.markdown.contains("Friday"))
        XCTAssertTrue(ab.markdown.contains("Wednesday"))
        XCTAssertEqual(ab.archivedLoser, macEdit)
    }

    func testTranscriptMergeDeduplicatesLocalASRSuppressesOwnEchoAndHealsGaps() {
        let sessionID = UUID()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        let macChunk = SyncedTranscriptChunk(
            sessionID: sessionID,
            deviceID: "mac",
            chunkIndex: 0,
            sessionStartedAt: t0,
            sessionEndedAt: t0.addingTimeInterval(120),
            micActiveIntervals: [DateInterval(start: t0, end: t0.addingTimeInterval(30))],
            events: [
                SyncedTranscriptEvent(
                    id: "srv-1",
                    providerMessageID: "chat-42",
                    kind: "chat",
                    sourceTier: 3,
                    occurredAt: t0.addingTimeInterval(5),
                    speaker: "Elena",
                    isOwn: false,
                    text: "Link posted",
                    revisions: [.init(text: "Link posted", author: "Elena", observedAt: t0.addingTimeInterval(5))],
                    isBookmarked: false,
                    deviceID: "mac"
                ),
                SyncedTranscriptEvent(
                    id: "mac-asr-1",
                    kind: "transcript",
                    sourceTier: 2,
                    occurredAt: t0.addingTimeInterval(10),
                    speaker: "You",
                    isOwn: true,
                    text: "Let's finalize the schedule for Friday",
                    deviceID: "mac"
                ),
                SyncedTranscriptEvent(
                    id: "mac-asr-2",
                    kind: "transcript",
                    sourceTier: 2,
                    occurredAt: t0.addingTimeInterval(40),
                    speaker: "Alex",
                    isOwn: false,
                    text: "Sounds great I will send the updated budget tonight",
                    deviceID: "mac"
                )
            ]
        )

        let iosChunk = SyncedTranscriptChunk(
            sessionID: sessionID,
            deviceID: "ios",
            chunkIndex: 0,
            sessionStartedAt: t0,
            sessionEndedAt: t0.addingTimeInterval(120),
            micActiveIntervals: [],
            events: [
                SyncedTranscriptEvent(
                    id: "srv-1-ios",
                    providerMessageID: "chat-42",
                    kind: "chat",
                    sourceTier: 3,
                    occurredAt: t0.addingTimeInterval(5),
                    speaker: "Elena",
                    isOwn: false,
                    text: "Link posted",
                    revisions: [.init(text: "Link posted here", author: "Elena", observedAt: t0.addingTimeInterval(6))],
                    isBookmarked: true,
                    deviceID: "ios"
                ),
                SyncedTranscriptEvent(
                    id: "ios-echo-1",
                    kind: "transcript",
                    sourceTier: 1,
                    occurredAt: t0.addingTimeInterval(10.8),
                    speaker: "Participant",
                    isOwn: true,
                    text: "finalize schedule Friday",
                    deviceID: "ios"
                ),
                SyncedTranscriptEvent(
                    id: "ios-asr-2",
                    kind: "transcript",
                    sourceTier: 1,
                    occurredAt: t0.addingTimeInterval(41.5),
                    speaker: "Alex",
                    isOwn: false,
                    text: "Sounds great I will send the updated budget tonight",
                    deviceID: "ios"
                ),
                SyncedTranscriptEvent(
                    id: "gap-1",
                    kind: "captureGap",
                    sourceTier: 1,
                    occurredAt: t0.addingTimeInterval(35),
                    endedAt: t0.addingTimeInterval(55),
                    text: "audioPaused",
                    deviceID: "ios"
                )
            ]
        )

        let merged = TranscriptMergeEngine.merge(chunks: [macChunk, iosChunk])
        XCTAssertFalse(merged.contains { $0.kind == "captureGap" })
        XCTAssertEqual(merged.filter { $0.kind == "chat" }.count, 1)
        XCTAssertEqual(merged.first(where: { $0.kind == "chat" })?.text, "Link posted here")
        XCTAssertEqual(merged.first(where: { $0.kind == "chat" })?.isBookmarked, true)

        let speech = merged.filter { $0.kind == "transcript" }
        XCTAssertEqual(speech.count, 2)
        XCTAssertEqual(speech.map(\.id), ["mac-asr-1", "mac-asr-2"])
    }

    func testOutcomePolicyDefersToOnlineMacAndMergesOfflineDualRuns() {
        let now = Date(timeIntervalSince1970: 1_700_000_500)
        let v1 = SyncVersion(counter: 1, device: "mac")
        var session = SyncedMeetingSession(
            id: UUID(),
            occurrenceKey: "room:abc",
            title: SyncValue("Weekly Sync", version: v1),
            hasTitleOverride: SyncValue(false, version: v1),
            invitation: SyncValue(nil, version: v1),
            roomIdentity: "room:abc",
            startedAt: now.addingTimeInterval(-600),
            endedAt: SyncValue(now, version: v1),
            timeZoneID: "UTC",
            state: SyncValue("ended", version: v1),
            legs: [
                "mac": DeviceParticipationLeg(
                    deviceID: "mac",
                    deviceKind: .mac,
                    joinedAt: now.addingTimeInterval(-600),
                    leftAt: now.addingTimeInterval(-5),
                    hasOutcomeWriter: true,
                    updatedAt: now.addingTimeInterval(-5)
                ),
                "ios": DeviceParticipationLeg(
                    deviceID: "ios",
                    deviceKind: .ios,
                    joinedAt: now.addingTimeInterval(-300),
                    leftAt: now,
                    hasOutcomeWriter: true,
                    updatedAt: now
                )
            ],
            isDeleted: SyncValue(false, version: v1),
            createdAt: now,
            updatedAt: now
        )

        let deadline = OutcomeCoordinatorPolicy.deferToMacDeadline(
            session: session,
            localDeviceID: "ios",
            localIsMac: false,
            isOnline: true,
            now: now
        )
        XCTAssertNotNil(deadline)
        XCTAssertNil(
            OutcomeCoordinatorPolicy.deferToMacDeadline(
                session: session,
                localDeviceID: "ios",
                localIsMac: false,
                isOnline: false,
                now: now
            )
        )

        session.outcomeClaim = SyncValue(
            OutcomeGenerationClaim(
                ownerDeviceID: "mac",
                deviceKind: .mac,
                claimedAt: now,
                leaseExpiresAt: now.addingTimeInterval(90),
                state: "ready"
            ),
            version: SyncVersion(counter: 2, device: "mac")
        )
        XCTAssertNil(
            OutcomeCoordinatorPolicy.deferToMacDeadline(
                session: session,
                localDeviceID: "ios",
                localIsMac: false,
                isOnline: true,
                now: now
            )
        )

        // Offline dual generation: higher coverage wins, runner-up archived, human edit preserved.
        let vPhone = SyncVersion(counter: 3, device: "ios")
        let vMacEdit = SyncVersion(counter: 4, device: "mac")
        let phoneOutcome = SyncedMeetingOutcome(
            outcomeID: UUID(),
            sessionID: session.id,
            state: SyncValue("ready", version: vPhone),
            summary: SyncValue("Phone short summary", version: vPhone),
            decisions: SyncValue(["Use weekly cadence"], version: vPhone),
            openQuestions: SyncValue(["Budget approval?"], version: vPhone),
            coverageSeconds: 300,
            writerTier: 1,
            reviewCandidates: SyncValue([], version: vPhone),
            updatedAt: now,
            isDeleted: SyncValue(false, version: vPhone)
        )
        let macOutcome = SyncedMeetingOutcome(
            outcomeID: UUID(),
            sessionID: session.id,
            state: SyncValue("ready", version: vMacEdit),
            summary: SyncValue("Full Mac summary", version: vMacEdit),
            decisions: SyncValue(["Use weekly cadence", "Ship beta 117"], version: vMacEdit),
            openQuestions: SyncValue(["Who signs off?"], version: vMacEdit),
            coverageSeconds: 600,
            writerTier: 2,
            reviewCandidates: SyncValue([], version: vMacEdit),
            updatedAt: now.addingTimeInterval(2),
            isDeleted: SyncValue(false, version: vMacEdit)
        )

        let mergedA = OutcomeAndTaskMergeEngine.mergeOutcomes(local: phoneOutcome, remote: macOutcome)
        let mergedB = OutcomeAndTaskMergeEngine.mergeOutcomes(local: macOutcome, remote: phoneOutcome)
        XCTAssertEqual(mergedA, mergedB)
        XCTAssertEqual(mergedA.summary.value, "Full Mac summary")
        XCTAssertEqual(mergedA.versions.first?.summary, "Phone short summary")
        XCTAssertEqual(Set(mergedA.decisions.value), ["Use weekly cadence", "Ship beta 117"])
        XCTAssertEqual(Set(mergedA.openQuestions.value), ["Budget approval?", "Who signs off?"])

        let macTask = SyncedMeetingTask(
            id: UUID(),
            sessionID: session.id,
            outcomeID: macOutcome.outcomeID,
            ordinal: SyncValue(0, version: vMacEdit),
            text: SyncValue("Send budget spreadsheet to Anna", version: vMacEdit),
            owner: SyncValue("Alex", version: vMacEdit),
            assigneeID: SyncValue(nil, version: vMacEdit),
            dueDay: SyncValue(nil, version: vMacEdit),
            dueAt: SyncValue(nil, version: vMacEdit),
            reminderAt: SyncValue(nil, version: vMacEdit),
            done: SyncValue(false, version: vMacEdit),
            completedAt: SyncValue(nil, version: vMacEdit),
            isDeleted: SyncValue(false, version: vMacEdit)
        )
        let phoneMatchingTask = SyncedMeetingTask(
            id: UUID(),
            sessionID: session.id,
            outcomeID: phoneOutcome.outcomeID,
            ordinal: SyncValue(0, version: vPhone),
            text: SyncValue("Send budget spreadsheet to Anna", version: SyncVersion(counter: 1, device: "ios")),
            owner: SyncValue("Alex", version: vPhone),
            assigneeID: SyncValue(nil, version: vPhone),
            dueDay: SyncValue(nil, version: vPhone),
            dueAt: SyncValue(nil, version: vPhone),
            reminderAt: SyncValue(nil, version: vPhone),
            done: SyncValue(true, version: SyncVersion(counter: 10, device: "ios")),
            completedAt: SyncValue(now, version: SyncVersion(counter: 10, device: "ios")),
            isDeleted: SyncValue(false, version: vPhone)
        )
        let phoneExtraTask = SyncedMeetingTask(
            id: UUID(),
            sessionID: session.id,
            outcomeID: phoneOutcome.outcomeID,
            ordinal: SyncValue(1, version: vPhone),
            text: SyncValue("Book rehearsal room B", version: vPhone),
            owner: SyncValue("Vlad", version: vPhone),
            assigneeID: SyncValue(nil, version: vPhone),
            dueDay: SyncValue(nil, version: vPhone),
            dueAt: SyncValue(nil, version: vPhone),
            reminderAt: SyncValue(nil, version: vPhone),
            done: SyncValue(false, version: vPhone),
            completedAt: SyncValue(nil, version: vPhone),
            isDeleted: SyncValue(false, version: vPhone)
        )
        let reconciled = OutcomeAndTaskMergeEngine.reconcileDualGeneratedTasks(
            primary: [macTask],
            secondary: [phoneMatchingTask, phoneExtraTask],
            sessionID: session.id,
            version: vMacEdit
        )
        XCTAssertEqual(reconciled.merged.count, 1)
        XCTAssertEqual(reconciled.merged.first?.done.value, true)
        XCTAssertEqual(reconciled.links.count, 1)
        XCTAssertEqual(reconciled.links.first?.canonicalTaskID, macTask.id)
        XCTAssertEqual(reconciled.reviewCandidates.map(\.text), ["Book rehearsal room B"])
    }

    func testSessionCoalescingAndTieredTranscriptRetention() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var doc = MeetingWorkspaceSyncDocument(device: "mac")
        let s1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let s2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let v1 = doc.nextVersion()
        doc.upsertSession(SyncedMeetingSession(
            id: s1,
            occurrenceKey: "cal:series1:100",
            title: SyncValue("Design Review", version: v1),
            hasTitleOverride: SyncValue(false, version: v1),
            invitation: SyncValue(nil, version: v1),
            roomIdentity: "rock.glowsoft.ru · design",
            startedAt: now,
            endedAt: SyncValue(nil, version: v1),
            timeZoneID: "UTC",
            state: SyncValue("active", version: v1),
            legs: ["mac": .init(deviceID: "mac", deviceKind: .mac, joinedAt: now)],
            isDeleted: SyncValue(false, version: v1),
            createdAt: now,
            updatedAt: now
        ))
        let v2 = SyncVersion(counter: 1, device: "ios")
        doc.upsertSession(SyncedMeetingSession(
            id: s2,
            occurrenceKey: "cal:series1:100",
            title: SyncValue("Design Review", version: v2),
            hasTitleOverride: SyncValue(false, version: v2),
            invitation: SyncValue(nil, version: v2),
            roomIdentity: "rock.glowsoft.ru · design",
            startedAt: now.addingTimeInterval(60),
            endedAt: SyncValue(nil, version: v2),
            timeZoneID: "UTC",
            state: SyncValue("active", version: v2),
            legs: ["ios": .init(deviceID: "ios", deviceKind: .ios, joinedAt: now.addingTimeInterval(60))],
            isDeleted: SyncValue(false, version: v2),
            createdAt: now,
            updatedAt: now
        ))
        doc.saveNote(sessionID: s2, markdown: "iPhone note line", now: now)
        let redirects = doc.coalesceOverlappingSessions()
        XCTAssertEqual(redirects.count, 1)
        XCTAssertEqual(doc.resolveCanonicalSessionID(for: s2), s1)
        XCTAssertEqual(doc.notes[s1]?.markdown, "iPhone note line")
        XCTAssertEqual(doc.sessions[s1]?.legs.keys.sorted(), ["ios", "mac"])

        // Transcript retention pruning: 10-day-old chunk expires under 7-day policy, stays under 30-day.
        let oldDate = now.addingTimeInterval(-10 * 86_400)
        let chunk = SyncedTranscriptChunk(
            sessionID: s1,
            deviceID: "mac",
            chunkIndex: 0,
            sessionStartedAt: oldDate,
            events: [.init(id: "e1", kind: "transcript", occurredAt: oldDate, text: "hello", deviceID: "mac")]
        )
        _ = doc.mergeTranscriptRecords([.chunk(chunk)])
        XCTAssertEqual(doc.expiredCloudTranscriptRecordIDs(retention: .days30, now: now), [])
        XCTAssertEqual(doc.expiredCloudTranscriptRecordIDs(retention: .days7, now: now), ["transcript:" + chunk.id])
        XCTAssertEqual(doc.transcriptRecordsForCloud(retention: .days7, now: now), [])
        XCTAssertEqual(doc.mergedTranscript(for: s1).count, 1)
    }

    func testCalendarScheduleDocumentMergesAndPrunes() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var macDoc = CalendarScheduleSyncDocument(device: "mac")
        var phoneDoc = CalendarScheduleSyncDocument(device: "ios")
        let link = URL(string: "https://rock.glowsoft.ru/jams/daily")!
        var meeting = CalendarMeeting(
            id: "ev-1",
            seriesID: "ser-1",
            calendarID: "cal-1",
            calendarTitle: "Work",
            title: "Daily Standup",
            start: now.addingTimeInterval(3600),
            end: now.addingTimeInterval(5400),
            links: [link],
            externalSeriesID: "ext-ser-1"
        )
        meeting.invitation = link
        meeting.engine = .community

        macDoc.updateLocalMeetings([meeting], bindings: [:], suppressed: [:], reminderStates: [:], now: now)
        _ = phoneDoc.merge(macDoc.records)
        XCTAssertEqual(phoneDoc.projectedOccurrences(now: now).map(\.title), ["Daily Standup"])

        phoneDoc.setOccurrenceState(occurrenceKey: meeting.occurrenceSyncKey, skipped: true, now: now.addingTimeInterval(5))
        _ = macDoc.merge(phoneDoc.records)
        XCTAssertEqual(macDoc.occurrences[meeting.occurrenceSyncKey]?.skipped?.value, true)

        let expiredIDs = macDoc.pruneExpired(now: now.addingTimeInterval(60 * 3600))
        XCTAssertEqual(expiredIDs, ["cal:" + meeting.occurrenceSyncKey])
        XCTAssertTrue(macDoc.occurrences.isEmpty)
    }

    func testPayloadCompressionRoundtripAndArchiveStore() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionID = UUID()
        let events = (0..<60).map { idx in
            SyncedTranscriptEvent(
                id: "ev-\(idx)",
                kind: "transcript",
                occurredAt: now.addingTimeInterval(Double(idx * 5)),
                speaker: "Speaker \(idx % 3)",
                text: "Testing LZFSE compression across repeated meeting transcript segments number \(idx).",
                deviceID: "mac"
            )
        }
        let chunk = SyncedTranscriptChunk(
            sessionID: sessionID,
            deviceID: "mac",
            chunkIndex: 0,
            sessionStartedAt: now,
            events: events
        )
        let encoded = try CloudPayloadCodec.encode(chunk)
        let decoded = try CloudPayloadCodec.decode(encoded, as: SyncedTranscriptChunk.self)
        XCTAssertEqual(decoded, chunk)

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let archive = TranscriptArchiveStore(root: tempRoot)
        let v = SyncVersion(counter: 1, device: "mac")
        let session = SyncedMeetingSession(
            id: sessionID,
            occurrenceKey: "room:1",
            title: SyncValue("Archive Test", version: v),
            hasTitleOverride: SyncValue(false, version: v),
            invitation: SyncValue(nil, version: v),
            roomIdentity: "rock.glowsoft.ru · test",
            startedAt: now,
            endedAt: SyncValue(now.addingTimeInterval(300), version: v),
            timeZoneID: "UTC",
            state: SyncValue("ended", version: v),
            isDeleted: SyncValue(false, version: v),
            createdAt: now,
            updatedAt: now
        )
        try await archive.archive(session: session, events: events)
        let loaded = await archive.loadTranscript(sessionID: sessionID)
        XCTAssertEqual(loaded?.count, events.count)
        let stats = await archive.stats()
        XCTAssertEqual(stats.archivedCount, 1)
        XCTAssertGreaterThan(stats.totalBytes, 0)
    }
}
