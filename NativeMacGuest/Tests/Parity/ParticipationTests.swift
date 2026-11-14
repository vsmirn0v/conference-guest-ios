import Foundation
import Combine
import ConferenceCore
import XCTest
@testable import RockNativeDesktop

final class ParticipationTests: XCTestCase {
    @MainActor
    func testVoiceSynthesisDeadlineFiresOnlyWhileTimerIsActive() async throws {
        var expired = false
        let active = GuestVoiceSynthesisDeadline.schedule(Date().addingTimeInterval(0.03)) { expired = true }
        await active.value
        XCTAssertTrue(expired)

        var afterCompletion = false
        let completed = GuestVoiceSynthesisDeadline.schedule(Date().addingTimeInterval(0.03)) { afterCompletion = true }
        completed.cancel()
        await completed.value
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(afterCompletion, "a completed synthesis must not cancel later playback")
    }

    func testDispatchPermitCannotStartAfterCancellationOrExpiry() async {
        let stopped = GuestChatDispatchPermit(deadline: .distantFuture)
        let ready = await stopped.preflight()
        XCTAssertTrue(ready)
        stopped.cancel()
        XCTAssertFalse(stopped.dispatch { XCTFail("Cancelled dispatch started") })
        XCTAssertFalse(stopped.didDispatch)

        let expired = GuestChatDispatchPermit(deadline: .distantPast)
        let readyAfterExpiry = await expired.preflight()
        XCTAssertFalse(readyAfterExpiry)
        XCTAssertFalse(expired.dispatch { XCTFail("Expired dispatch started") })

        let inFlight = GuestChatDispatchPermit(deadline: .distantFuture)
        XCTAssertTrue(inFlight.dispatch {})
        inFlight.cancel()
        XCTAssertTrue(inFlight.didDispatch)
        XCTAssertFalse(inFlight.dispatch { XCTFail("Replayed dispatch started") })
    }

    func testDispatchPermitRejectsStalledSourceValidation() async {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let permit = GuestChatDispatchPermit(deadline: .distantFuture) {
            release.wait()
            return true
        }
        let ready = await permit.preflight()
        XCTAssertFalse(ready)
        XCTAssertTrue(permit.validationFailed)
        XCTAssertFalse(permit.dispatch { XCTFail("Stalled validation authorized dispatch") })
    }

    func testDispatchPermitCannotStartAfterRevocationWhileCheckingSource() async {
        let entered = expectation(description: "Started reading approved source")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let permit = GuestChatDispatchPermit(deadline: .distantFuture) {
            entered.fulfill()
            release.wait()
            return true
        }
        let check = Task { await permit.preflight() }
        await fulfillment(of: [entered], timeout: 2)
        permit.cancel()
        release.signal()
        _ = await check.value
        XCTAssertFalse(permit.dispatch { XCTFail("Revoked source authorized dispatch") })
    }

    func testReceiptReservesOnceAndDistinguishesServerAcceptance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ParticipationReceiptStore(root: root)
        let now = Date()
        var receipt = ParticipationReceipt(id: ParticipationReceipt.hash("chat:event"), sessionID: UUID(),
            grantID: UUID(), payloadHash: ParticipationReceipt.hash("test draft"), evidenceRevisions: [],
            createdAt: now, updatedAt: now, state: .reserved, providerMessageID: UUID().uuidString)
        try store.reserve(receipt)
        XCTAssertThrowsError(try store.reserve(receipt))
        XCTAssertEqual(try store.receipts(for: receipt.sessionID).map(\.state), [.reserved])
        receipt.state = .serverAccepted
        try store.update(receipt)
        XCTAssertEqual(try store.receipts(for: receipt.sessionID).map(\.state), [.serverAccepted])
        receipt.state = .confirmed
        try store.update(receipt)
        XCTAssertEqual(try store.receipts(for: receipt.sessionID).map(\.state), [.confirmed])
        XCTAssertTrue(try store.receipts(for: UUID()).isEmpty)
    }

    func testVoiceSourcePreflightReleasesCallerWhenFileReadStalls() async {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let result: Int? = await ParticipationSourceBinding.withReadDeadline {
            release.wait()
            return 1
        }
        XCTAssertNil(result)
    }

    func testVoiceSourcePreflightDiscardsResultAfterCancellation() async {
        let reading = expectation(description: "Started source read")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let task = Task {
            await ParticipationSourceBinding.withReadDeadline {
                reading.fulfill()
                release.wait()
                return 1
            }
        }
        await fulfillment(of: [reading], timeout: 2)
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
    }

    @MainActor
    func testStoppingSystemVoiceSynthesisInvokesCancellationHandler() async {
        let began = expectation(description: "Started synthesis")
        let stopped = expectation(description: "Stopped synthesis")
        let task = Task {
            await VoiceReplySample.bounded(timeout: 3, cancel: { stopped.fulfill() }) { _ in began.fulfill() }
        }
        await fulfillment(of: [began], timeout: 2)
        task.cancel()
        await fulfillment(of: [stopped], timeout: 2)
        let result = await task.value
        XCTAssertNil(result)
    }

    @MainActor
    func testReplacedConnectionMustBeConnectedBeforeARecoveryGateCanReopen() {
        let previousEngine = NSObject(), replacementEngine = NSObject()
        let previous = ObjectIdentifier(previousEngine), replacement = ObjectIdentifier(replacementEngine)
        XCTAssertFalse(NativeDesktopMeetingModel.canReleaseVoiceGate(heldFor: previous, current: nil, connected: false))
        XCTAssertFalse(NativeDesktopMeetingModel.canReleaseVoiceGate(heldFor: previous, current: previous, connected: true))
        XCTAssertFalse(NativeDesktopMeetingModel.canReleaseVoiceGate(heldFor: previous, current: replacement, connected: false))
        XCTAssertTrue(NativeDesktopMeetingModel.canReleaseVoiceGate(heldFor: previous, current: replacement, connected: true))
    }

    func testDecisionRequiresLiteralQuotesAndCurrentHumanTrigger() {
        let input = ParticipationInput(objective: "", trigger: "chat:turn", turns: [
            .init(id: "chat:turn", channel: "chat", speaker: "Mira", text: "Can the assistant recall the deadline?", own: false)
        ], sources: [
            .init(id: "source:deadline", title: "Release schedule", text: "The deadline is Friday.", revision: "current")
        ])
        let trigger = ParticipationDecision.Citation(id: "chat:turn", quote: "recall the deadline?")
        let evidence = ParticipationDecision.Citation(id: "source:deadline", quote: "deadline is Friday")
        let decision = ParticipationDecision(kind: .answer, text: "Friday (Release schedule).",
            directlyAddressed: true, citations: [trigger, evidence])
        XCTAssertEqual(decision.validated(in: input), "Friday (Release schedule).")
        let fabricated = ParticipationDecision(kind: .answer, text: "Monday (Release schedule).", directlyAddressed: true,
            citations: [trigger, .init(id: "source:deadline", quote: "deadline is Monday")])
        XCTAssertNil(fabricated.validated(in: input))
        let missingSource = ParticipationDecision(kind: .answer, text: "Friday.", directlyAddressed: true,
            citations: [trigger, evidence])
        XCTAssertEqual(missingSource.validated(in: input), "Friday.")
        let requestedOpening = ParticipationDecision(kind: .answer, text: "Friday.", directlyAddressed: true,
            citations: [evidence], authorizedOpening: "Ops desk.")
        XCTAssertEqual(requestedOpening.grounded(in: input)?.validated(in: input), "Ops desk. Friday.")
        XCTAssertTrue(ParticipationPlanner.hasOpeningLabel("Ops desk.", in: "“Ops desk” can hear you."))
        XCTAssertFalse(ParticipationPlanner.hasOpeningLabel("Ops desk.", in: "I can hear Ops desk."))
        XCTAssertFalse(ParticipationPlanner.hasOpeningLabel("Ops.", in: "OpsDesk is offline."))
        let inlineEvidence = ParticipationDecision(kind: .answer, text: "Friday. [source:deadline]", directlyAddressed: true,
            citations: [trigger, evidence])
        XCTAssertNil(inlineEvidence.validated(in: input))
        let own = ParticipationInput(objective: "", trigger: "chat:turn", turns: [
            .init(id: "chat:turn", channel: "chat", speaker: "Mira", text: "Can the assistant recall the deadline?", own: true)
        ], sources: input.sources)
        XCTAssertNil(decision.validated(in: own))
    }

    func testConversationalRepliesKeepGeneratedWordsAndRejectUnverifiedAudio() throws {
        let text = "Can you hear me?"
        func input(_ source: ParticipationObservation.Source, verified: Bool = true) -> ParticipationInput {
            .init(objective: "", trigger: "turn", turns: [
                .init(id: "turn", channel: source.channel, speaker: "A guest", text: text, own: false, speakerVerified: verified)
            ], sources: [], localAttendeeName: "Me", triggerSource: source)
        }
        let audio = ParticipationDecision(kind: .acknowledgeAudio, text: "Yes, I hear you.", directlyAddressed: true, citations: [])
        let approved = try XCTUnwrap(audio.grounded(in: input(.localTranscript)))
        XCTAssertEqual(approved.validated(in: input(.localTranscript)), "Yes, I hear you.")
        XCTAssertEqual(approved.citations.map(\.quote), [text])
        XCTAssertNil(approved.validated(in: input(.localTranscript, verified: false)))
        XCTAssertNil(approved.validated(in: input(.serviceTranscript)))
        XCTAssertNil(audio.grounded(in: input(.chat)))
        XCTAssertTrue(Self.approvedAssessment().approves(approved))
        XCTAssertFalse(Self.approvedAssessment(unauthorizedCommitment: true).approves(approved))
    }

    func testOnlyCurrentMeetingQuestionsCanCiteCalendarMetadataForPublicReplies() {
        let metadata = ParticipationSource(id: ParticipationSource.meetingMetadataID, title: "Current meeting details",
            text: "Scheduled start: 02:00 UTC", revision: "m1")
        var input = ParticipationInput(objective: "", trigger: "turn", turns: [
            .init(id: "turn", channel: "chat", speaker: "Guest", text: "When does Lumen deploy?", own: false)
        ], sources: [metadata])
        let claim = ParticipationDecision(kind: .answer, text: "Lumen deploys at 02:00 UTC.", directlyAddressed: true,
            citations: [.init(id: metadata.id, quote: "02:00 UTC")])
        XCTAssertNil(claim.grounded(in: input)?.validated(in: input))
        input = .init(objective: "", trigger: "turn", turns: [
            .init(id: "turn", channel: "chat", speaker: "Guest", text: "When does this meeting start?", own: false)
        ], sources: [metadata])
        let scoped = ParticipationDecision(kind: .answer, text: "This meeting starts at 02:00 UTC.", directlyAddressed: true,
            citations: [.init(id: metadata.id, quote: "02:00 UTC")], asksAboutCurrentMeeting: true)
        XCTAssertEqual(scoped.grounded(in: input)?.validated(in: input), "This meeting starts at 02:00 UTC.")
    }

    func testRetrievalCanFindRelevantExcerptBeyondOpeningSection() {
        let note = String(repeating: "Opening discussion and room logistics.\n", count: 80)
            + "\n## Rollout\nThe rollback window is Friday at noon."
        let excerpt = ParticipationSourceBinding.relevantExcerpt(in: note, matching: "Rollback window")
        XCTAssertTrue(excerpt?.contains("The rollback window is Friday at noon.") == true)
        XCTAssertLessThanOrEqual(excerpt?.count ?? .max, 1_200)
        XCTAssertNil(ParticipationSourceBinding.relevantExcerpt(in: note, matching: "telemetry"))
    }

    func testRetrievalKeepsEvidenceAcrossWindowBoundary() {
        let evidence = "The rollback window is Friday, only if validation passes."
        let note = String(repeating: "room agenda ", count: 99) + "abcde " + evidence
        let excerpt = ParticipationSourceBinding.relevantExcerpt(in: note, matching: "rollback validation")
        XCTAssertTrue(excerpt?.contains(evidence) == true)
        XCTAssertLessThanOrEqual(excerpt?.count ?? .max, 1_200)
    }

    @MainActor
    func testLocalRoomTranscriptTriggersParticipationWithoutServiceCaptions() throws {
        let (model, audience) = try localParticipationFixture()
        let before = Date().addingTimeInterval(-20)
        var triggers: [ParticipationLine] = []
        model.participation.observeForTesting(audience: audience, enteredAt: before) { triggers.append($0) }
        let generation = model.setParticipationLocalReceiverForTesting([
            "peer-track": .init(participantID: "peer", since: before),
            "anonymous-track": .init(participantID: nil, since: before),
        ])
        XCTAssertEqual(model.participationTranscriptSource, .localRoomAudio)
        XCTAssertTrue(model.participationVoiceHasTranscript)
        func emit(_ id: String, _ track: String, _ text: String, _ offset: TimeInterval, _ generation: UUID) {
            model.receiveParticipationLocalLineForTesting(.init(id: id, trackID: track, text: text,
                start: before.addingTimeInterval(offset), end: before.addingTimeInterval(offset + 1)), generation: generation)
        }
        emit("first", "peer-track", "Could the assistant summarize the launch window?", 3, generation)
        emit("first", "peer-track", "Could the assistant summarize the launch window?", 3, generation)
        emit("unknown", "anonymous-track", "What is still open for the review?", 5, generation)
        let beforeLateContext = model.participation.candidateRevisionForTesting
        emit("late", "peer-track", "Older audio decoded after the next turn", 4, generation)
        XCTAssertGreaterThan(model.participation.candidateRevisionForTesting, beforeLateContext)
        emit("private", MeetingTranscriber.localTrackID, "Private microphone text", 7, generation)
        emit("detached", "detached-track", "Stale receiver text", 8, generation)
        let replacement = model.setParticipationLocalReceiverForTesting([
            "peer-track": .init(participantID: "peer", since: before.addingTimeInterval(9)),
            "wrong-room": .init(participantID: "outsider", since: before),
        ])
        emit("stale", "peer-track", "Stale decode", 11, generation)
        emit("before-binding", "peer-track", "Speech before the receiver binding", 8, replacement)
        emit("outside", "wrong-room", "Unknown roster member", 11, replacement)
        XCTAssertEqual(triggers.map(\.id), ["local-transcript:first", "local-transcript:unknown"])
        XCTAssertEqual(triggers.first?.speaker, "Remote attendee")
        XCTAssertTrue(triggers.first?.speakerVerified == true)
        XCTAssertEqual(triggers.last?.speaker, L("Unidentified room speaker"))
        XCTAssertTrue(triggers.last?.speakerVerified == false)
        XCTAssertFalse(model.localTranscript.contains { $0.id == "stale" })
    }

    @MainActor
    func testSuccessiveDirectQuestionsCanReceiveTheSameAnswerWithoutAnUnsolicitedCooldown() async throws {
        let (model, audience) = try localParticipationFixture()
        let (store, cleanup) = try participationStore()
        defer { model.participation.stop(); cleanup() }
        model.participationAudienceForTesting = audience
        model.participation.decisionDelayForTesting = .milliseconds(10)
        let setup = try XCTUnwrap(model.participation.setup(for: model, store: store))
        XCTAssertTrue(model.participation.start(setup, objective: "", model: model, store: store))
        model.participation.planForTesting = { _ in
            .init(kind: .answer, text: "Yes.", directlyAddressed: true, citations: [])
        }
        model.participation.assessForTesting = { _, _, _ in true }

        var features = GuestMeetingSnapshot()
        for (index, question) in ["Can you confirm the date?", "And can you confirm the location?"].enumerated() {
            let settled = expectation(description: "Direct reply reaches the dispatch boundary")
            let observation = model.participation.$receipts.dropFirst().sink { receipts in
                if receipts.count == index + 1 && receipts.first?.state == .cancelled { settled.fulfill() }
            }
            let received = Date()
            features.messages.append(.init(id: "question-\(index)", participantID: "peer", participantName: "Remote attendee",
                text: question, sentAt: received, isOwn: false, receivedAt: received))
            model.receiveFeaturesForTesting(features)
            await fulfillment(of: [settled], timeout: 2)
            observation.cancel()
        }
        // The fixture lacks a live server. Reservation proves both turns
        // independently passed admission and hit the normal send boundary.
        XCTAssertEqual(model.participation.receipts.count, 2)
        XCTAssertEqual(Set(model.participation.receipts.map(\.payloadHash)).count, 1)
    }

    @MainActor
    func testUnprefixedAutomaticChatEchoConfirmsWithoutYieldingToAnOwnHumanTurn() throws {
        let (model, audience) = try localParticipationFixture()
        let (store, cleanup) = try participationStore()
        defer { model.participation.stop(); cleanup() }
        model.participationAudienceForTesting = audience
        let setup = try XCTUnwrap(model.participation.setup(for: model, store: store))
        XCTAssertTrue(model.participation.start(setup, objective: "", model: model, store: store))

        let reply = "Да, на связи. Какой вопрос?"
        try model.participation.seedDispatchedChatForTesting(id: "automatic-chat", text: reply)
        let revision = model.participation.candidateRevisionForTesting
        let echoed = Date()
        var features = GuestMeetingSnapshot()
        features.messages = [.init(id: "automatic-chat", participantID: "me", participantName: "Me", text: reply,
                                    sentAt: echoed, isOwn: true, receivedAt: echoed)]
        model.receiveFeaturesForTesting(features)
        XCTAssertEqual(model.participation.receipts.first?.state, .confirmed)
        XCTAssertEqual(model.participation.candidateRevisionForTesting, revision)

        let typed = Date()
        features.messages.append(.init(id: "typed-chat", participantID: "me", participantName: "Me", text: reply,
                                       sentAt: typed, isOwn: true, receivedAt: typed))
        model.receiveFeaturesForTesting(features)
        XCTAssertGreaterThan(model.participation.candidateRevisionForTesting, revision)
    }

    @MainActor
    func testServiceCaptionHandoverAndAssistantEchoDoNotRetriggerLocalSpeech() throws {
        let (model, audience) = try localParticipationFixture()
        let before = Date().addingTimeInterval(-20)
        var triggers: [ParticipationLine] = []
        model.participation.observeForTesting(audience: audience, enteredAt: before) { triggers.append($0) }
        let generation = model.setParticipationLocalReceiverForTesting([
            "peer-track": .init(participantID: "peer", since: before),
        ])
        let spokenAt = before.addingTimeInterval(6)
        let text = "Can the assistant clarify the release date?"
        model.receiveParticipationLocalLineForTesting(.init(id: "local", trackID: "peer-track", text: text,
            start: spokenAt, end: spokenAt.addingTimeInterval(1)), generation: generation)
        var features = GuestMeetingSnapshot()
        features.transcriptionStatus = .active
        features.permissions.canViewTranscript = true
        features.transcript = [.init(id: "provider", participantID: "peer", participantName: "Peer", text: text,
                                     sentAt: spokenAt, isOwn: false, receivedAt: Date())]
        model.receiveFeaturesForTesting(features)
        XCTAssertEqual(model.participationTranscriptSource, .service)
        features.transcriptionStatus = .stopped
        model.receiveFeaturesForTesting(features)
        model.participation.beginVoiceEchoWindow()
        let echoEnd = Date()
        model.participation.endVoiceEchoWindow()
        model.receiveParticipationLocalLineForTesting(.init(id: "echo", trackID: "peer-track", text: "Rock and Roll assistant echo",
            start: echoEnd.addingTimeInterval(-3), end: echoEnd), generation: generation)
        XCTAssertEqual(triggers.map(\.id), ["local-transcript:local"])
    }

    @MainActor
    func testVoiceSetupCapturesTheSelectedCloneAndRejectsAChangedVoice() throws {
        let (model, audience) = try localParticipationFixture()
        let (store, cleanup) = try participationStore()
        defer { model.participation.stop(); cleanup() }
        model.participationAudienceForTesting = audience
        store.voiceEngine = .cloned
        let setup = try XCTUnwrap(model.participation.setup(for: model, store: store))
        XCTAssertEqual(setup.voice.engine, .cloned)

        store.voiceEngine = .system
        XCTAssertFalse(model.participation.start(setup, objective: "", model: model, store: store, output: .voice))
        XCTAssertEqual(model.participation.startFailure, .voiceChanged)
        XCTAssertTrue(model.participation.start(setup, objective: "", model: model, store: store, output: .chat))
    }

    @MainActor
    func testStartedLiveGrantFollowsNewParticipantAndPlansOnlyFreshLocalSpeechWhileHidden() async throws {
        let (model, withPeer) = try localParticipationFixture()
        let (store, cleanup) = try participationStore()
        defer { model.participation.stop(); cleanup() }
        let alone = audience(withPeer, members: ["me": "Me"])
        model.participationAudienceForTesting = alone
        model.receiveFeaturesForTesting(.init())
        let setup = try XCTUnwrap(model.participation.setup(for: model, store: store))
        XCTAssertTrue(model.participation.start(setup, objective: "", model: model, store: store))
        let planned = expectation(description: "The current roster's fresh local speech reaches the planner")
        model.participation.planForTesting = { input in
            XCTAssertEqual(input.trigger, "local-transcript:fresh")
            XCTAssertEqual(input.turns.map(\.id), ["local-transcript:fresh"])
            XCTAssertEqual(input.turns.first?.speaker, "Remote attendee")
            XCTAssertEqual(input.sources.map(\.id), ["meeting-metadata"])
            XCTAssertFalse(input.vaultAvailable)
            planned.fulfill()
            return .init(kind: .quiet, text: "", directlyAddressed: false, citations: [])
        }
        for presentation in [NativeDesktopMeetingModel.MediaPresentation.meeting, .floating, .infoCard, .hidden] {
            model.setMediaPresentation(presentation)
            XCTAssertEqual(model.participation.status, .observing)
            XCTAssertEqual(model.participation.rosterEpoch, setup.rosterEpoch)
        }
        let captureStarted = Date()
        model.participationAudienceForTesting = withPeer
        var features = GuestMeetingSnapshot()
        model.receiveFeaturesForTesting(features)
        XCTAssertEqual(model.participation.status, .observing)
        XCTAssertEqual(model.participation.rosterEpoch, setup.rosterEpoch + 1)
        XCTAssertNil(model.participation.reason)
        let diagnosticLine = try XCTUnwrap(probeLogHistory().last { $0.contains("\"action\":\"liveAudienceUpdated\"") })
        let diagnostic = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(diagnosticLine.utf8)) as? [String: Any])
        XCTAssertEqual(diagnostic["event"] as? String, "participation-lifecycle")
        XCTAssertEqual(diagnostic["audienceCount"] as? Int, 2)
        XCTAssertEqual(Set(diagnostic.keys), ["event", "uptime", "action", "state", "audienceCount", "audiencePolicy", "noteCount", "output"])
        let generation = model.setParticipationLocalReceiverForTesting([
            "peer-track": .init(participantID: "peer", since: captureStarted.addingTimeInterval(-1)),
        ])
        let revision = model.participation.candidateRevisionForTesting
        try await Task.sleep(for: .milliseconds(25))
        model.receiveParticipationLocalLineForTesting(.init(id: "old", trackID: "peer-track", text: "Old local turn",
            start: captureStarted.addingTimeInterval(-0.5), end: Date()), generation: generation)
        features.messages = [.init(id: "delayed", participantID: "peer", participantName: "Remote attendee",
            text: "Old chat turn", sentAt: captureStarted.addingTimeInterval(-0.5), isOwn: false, receivedAt: Date())]
        model.receiveFeaturesForTesting(features)
        XCTAssertEqual(model.participation.candidateRevisionForTesting, revision)
        let freshStarted = Date()
        try await Task.sleep(for: .milliseconds(25))
        model.receiveParticipationLocalLineForTesting(.init(id: "fresh", trackID: "peer-track",
            text: "What do we need for the launch?", start: freshStarted, end: Date()), generation: generation)
        await fulfillment(of: [planned], timeout: 8)
        XCTAssertEqual(model.participation.status, .observing)
    }

    @MainActor
    func testStartedNoteGrantRevokesNotesAndRequiresFreshConsentAfterRosterChange() throws {
        let (model, withPeer) = try localParticipationFixture()
        let (store, cleanup) = try participationStore()
        defer { model.participation.stop(); cleanup() }
        store.provider = try XCTUnwrap(AttentionProvider.defaults[.apple])
        model.participation.allowsUnavailableAppleForTesting = true
        let alone = audience(withPeer, members: ["me": "Me"])
        model.participationAudienceForTesting = alone
        model.receiveFeaturesForTesting(.init())
        let setup = try XCTUnwrap(model.participation.setup(for: model, store: store))
        let context = try XCTUnwrap(setup.knowledgeContext(title: model.title, expiresAt: Date().addingTimeInterval(300)))
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try "Approved for the original audience.".write(to: store.root.appendingPathComponent("Notes.md"),
            atomically: true, encoding: .utf8)
        let folder = try ParticipationKnowledgeFolder(selectedURL: store.root)
        let note = try folder.approve(reviewed: folder.inspect(relativePath: "Notes.md"), context: context)
        XCTAssertTrue(model.participation.start(setup, objective: "", model: model, store: store, context: context, notes: [note]))
        XCTAssertEqual(model.participation.status, .observing)

        model.participationAudienceForTesting = withPeer
        model.receiveFeaturesForTesting(.init())
        XCTAssertEqual(model.participation.status, .review)
        XCTAssertEqual(model.participation.reason, .audienceChanged)
        XCTAssertTrue(model.participation.approvedNotes.isEmpty)
        XCTAssertTrue(model.participation.revokedNoteIDs.contains(note.id))

        model.participationAudienceForTesting = alone
        model.receiveFeaturesForTesting(.init())
        model.participation.resume()
        XCTAssertEqual(model.participation.status, .review)
        XCTAssertFalse(model.participation.start(setup, objective: "", model: model, store: store, context: context, notes: [note]))
    }

    @MainActor
    func testVolumeZeroInvalidatesSuspendedPlanningEvenAfterSoundReturns() async throws {
        let (model, audience) = try localParticipationFixture()
        let (store, cleanup) = try participationStore()
        defer { model.participation.stop(); cleanup() }
        model.setMeetingVolume(1, persist: false)
        model.participationAudienceForTesting = audience
        model.participation.decisionDelayForTesting = .milliseconds(10)
        let setup = try XCTUnwrap(model.participation.setup(for: model, store: store))
        XCTAssertTrue(model.participation.start(setup, objective: "", model: model, store: store))
        let began = expectation(description: "Planner suspended")
        let finished = expectation(description: "Planner returned after sound changes")
        let assessed = expectation(description: "A stale decision reached assessment")
        assessed.isInverted = true
        var release: CheckedContinuation<Void, Never>?
        model.participation.planForTesting = { _ in
            await withCheckedContinuation { release = $0; began.fulfill() }
            finished.fulfill()
            return .init(kind: .answer, text: "Yes.", directlyAddressed: true, citations: [])
        }
        model.participation.assessForTesting = { _, _, _ in assessed.fulfill(); return true }
        let timestamp = Date()
        model.receiveFeaturesForTesting(.init(messages: [.init(id: "sound-change", participantID: "peer",
            participantName: "Remote attendee", text: "Can you confirm?", sentAt: timestamp,
            isOwn: false, receivedAt: timestamp)]))
        await fulfillment(of: [began], timeout: 2)
        let pendingTransport = try model.participation.seedPendingChatForTesting()
        let transportReady = await pendingTransport.preflight()
        XCTAssertTrue(transportReady)
        model.setMeetingVolume(0, persist: false)
        model.setMeetingVolume(1, persist: false)
        XCTAssertFalse(pendingTransport.dispatch { XCTFail("Stale transport sent after sound returned") })
        release?.resume()
        await fulfillment(of: [finished, assessed], timeout: 0.25)
        XCTAssertTrue(model.participation.receipts.isEmpty)
        XCTAssertNil(model.participation.queuedText)
    }

    @MainActor
    func testLiveRosterChangeDiscardsAPlannerResponseEvenIfThePlannerIgnoresCancellation() async throws {
        let (model, withPeer) = try localParticipationFixture()
        let (store, cleanup) = try participationStore()
        defer { model.participation.stop(); cleanup() }
        model.participationAudienceForTesting = withPeer
        var features = GuestMeetingSnapshot()
        model.receiveFeaturesForTesting(features)
        let setup = try XCTUnwrap(model.participation.setup(for: model, store: store))
        XCTAssertTrue(model.participation.start(setup, objective: "", model: model, store: store))
        let began = expectation(description: "Old roster planner started")
        let returned = expectation(description: "Old planner returned after cancellation")
        let assessed = expectation(description: "Old roster decision reached assessment")
        assessed.isInverted = true
        var release: CheckedContinuation<Void, Never>?
        let previousTurn = "Could you explain the old agenda?"
        model.participation.planForTesting = { input in
            await withCheckedContinuation { continuation in
                release = continuation
                began.fulfill()
            }
            XCTAssertTrue(Task.isCancelled)
            returned.fulfill()
            return .init(kind: .privateInsight, text: "Old agenda", directlyAddressed: false,
                citations: [.init(id: input.trigger, quote: previousTurn)])
        }
        model.participation.assessForTesting = { _, _, _ in
            assessed.fulfill()
            return true
        }
        let spoken = Date()
        features.messages = [.init(id: "old", participantID: "peer", participantName: "Remote attendee",
            text: previousTurn, sentAt: spoken, isOwn: false, receivedAt: spoken)]
        model.receiveFeaturesForTesting(features)
        await fulfillment(of: [began], timeout: 8)
        model.participationAudienceForTesting = audience(withPeer,
            members: withPeer.members.merging(["new": "New attendee"], uniquingKeysWith: { _, name in name }))
        model.receiveFeaturesForTesting(features)
        release?.resume()
        await fulfillment(of: [returned, assessed], timeout: 0.25)
        XCTAssertEqual(model.participation.status, .observing)
        XCTAssertNil(model.participation.privateInsight)
        XCTAssertNil(model.participation.queuedText)
    }

    @MainActor
    func testStartedLiveGrantNeverFollowsConnectionChangeOrAutomaticallyResumesAfterPause() throws {
        let (model, withPeer) = try localParticipationFixture()
        let (store, cleanup) = try participationStore()
        defer { model.participation.stop(); cleanup() }
        let alone = audience(withPeer, members: ["me": "Me"])
        model.participationAudienceForTesting = alone
        model.receiveFeaturesForTesting(.init())
        let setup = try XCTUnwrap(model.participation.setup(for: model, store: store))
        XCTAssertTrue(model.participation.start(setup, objective: "", model: model, store: store))
        model.participation.pause()
        XCTAssertEqual(model.participation.reason, .userPaused)
        model.participationAudienceForTesting = withPeer
        model.receiveFeaturesForTesting(.init())
        model.participation.resume()
        XCTAssertEqual(model.participation.status, .review)
        XCTAssertEqual(model.participation.reason, .audienceChanged)

        let currentSetup = try XCTUnwrap(model.participation.setup(for: model, store: store))
        XCTAssertTrue(model.participation.start(currentSetup, objective: "", model: model, store: store))
        model.participationAudienceForTesting = audience(withPeer, members: withPeer.members, connection: ObjectIdentifier(store))
        model.receiveFeaturesForTesting(.init())
        XCTAssertEqual(model.participation.status, .review)
        XCTAssertEqual(model.participation.reason, .connectionChanged)
    }

    @MainActor
    func testNamedDiscussionOpenerAndAudioCheckReachVoiceAdmissionWithNaturalRussianReplies() async throws {
        let (model, original) = try localParticipationFixture()
        let (store, cleanup) = try participationStore()
        defer { model.participation.stop(); cleanup() }
        let local = audience(original, members: ["me": "Виталий", "peer": "Виталий"])
        model.participationAudienceForTesting = local
        model.participationVoiceAvailableForTesting = true
        model.receiveFeaturesForTesting(.init())
        model.participation.decisionDelayForTesting = .milliseconds(15)
        let setup = try XCTUnwrap(model.participation.setup(for: model, store: store))
        XCTAssertEqual(store.lastParticipationOutput, .chat)
        XCTAssertTrue(model.participation.start(setup, objective: "", model: model, store: store, output: .voice))
        XCTAssertEqual(store.lastParticipationOutput, .voice)
        let generation = model.setParticipationLocalReceiverForTesting([
            "peer-track": .init(participantID: "peer", since: .distantPast),
        ])

        for (kind, trigger, phrase) in [
            (ParticipationDecision.Kind.offerToTakeQuestion, "Виталий, можешь сейчас обсудить инфраструктуру?",
                "Да, на связи. Какой вопрос по инфраструктуре?"),
            (.acknowledgeAudio, "Виталий, а ты слышишь меня?", "Да, слышу."),
        ] {
            let routed = expectation(description: "Voice dispatcher keeps the approved reply in private text when audio is unavailable")
            let observation = model.participation.$latestDecision.dropFirst().sink { state in
                if state?.reason == .voiceUnavailable { routed.fulfill() }
            }
            defer { observation.cancel() }
            model.participation.planForTesting = { input in
                XCTAssertEqual(input.localAttendeeName, "Виталий")
                XCTAssertEqual(input.triggerSource, .localTranscript)
                XCTAssertEqual(input.output, .voice)
                XCTAssertEqual(input.attendeeCount, 2)
                XCTAssertEqual(input.turns.first { $0.id == input.trigger }?.own, false)
                return .init(kind: kind, text: phrase, directlyAddressed: true, citations: [])
            }
            model.participation.assessForTesting = { decision, draft, input in
                XCTAssertEqual(decision.kind, kind)
                XCTAssertEqual(draft, phrase)
                XCTAssertEqual(decision.text, phrase)
                XCTAssertTrue(decision.directlyAddressed)
                XCTAssertEqual(decision.citations.map(\.id), [input.trigger])
                XCTAssertEqual(decision.citations.map(\.quote), [trigger])
                return true
            }
            let spoken = Date()
            model.receiveParticipationLocalLineForTesting(.init(id: kind.rawValue, trackID: "peer-track",
                text: trigger, start: spoken, end: Date()), generation: generation)
            await fulfillment(of: [routed], timeout: 2)
            XCTAssertEqual(model.participation.voiceReplies.last?.text, phrase)
            XCTAssertEqual(model.participation.voiceReplies.last?.status, .textOnly)
            XCTAssertTrue(model.participation.receipts.isEmpty)
        }
        let diagnostic = try XCTUnwrap(probeLogHistory().last { $0.contains("\"reason\":\"voiceUnavailable\"") })
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(diagnostic.utf8)) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["event", "uptime", "stage", "reason", "output", "source"])
    }

    @MainActor
    func testIndependentAssessmentStopsUnauthorizedCommitmentsAndAnsweredAudioCheck() async throws {
        let (model, audience) = try localParticipationFixture()
        let (store, cleanup) = try participationStore()
        defer { model.participation.stop(); cleanup() }
        model.participationAudienceForTesting = audience
        model.participationVoiceAvailableForTesting = true
        model.receiveFeaturesForTesting(.init())
        model.participation.decisionDelayForTesting = .milliseconds(15)
        let setup = try XCTUnwrap(model.participation.setup(for: model, store: store))
        XCTAssertTrue(model.participation.start(setup, objective: "", model: model, store: store, output: .voice))
        let generation = model.setParticipationLocalReceiverForTesting([
            "peer-track": .init(participantID: "peer", since: .distantPast),
        ])
        for (kind, trigger, claimedSpeech) in [
            (ParticipationDecision.Kind.answer, "Can you promise to ship today?", "I promise to ship today."),
            (.acknowledgeAudio, "Can you hear me now?", "Yes, I hear you."),
        ] {
            let denied = expectation(description: "Assessment refuses public participation")
            let observation = model.participation.$latestDecision.dropFirst().sink { state in
                if state?.reason == .assessmentDeclined { denied.fulfill() }
            }
            defer { observation.cancel() }
            model.participation.planForTesting = { input in
                .init(kind: kind, text: claimedSpeech, directlyAddressed: false,
                    citations: [.init(id: input.trigger, quote: trigger)])
            }
            model.participation.assessForTesting = { decision, _, _ in
                Self.approvedAssessment(unauthorizedCommitment: kind == .answer, superseded: kind == .acknowledgeAudio).approves(decision)
            }
            let spoken = Date()
            model.receiveParticipationLocalLineForTesting(.init(id: kind.rawValue, trackID: "peer-track",
                text: trigger, start: spoken, end: Date()), generation: generation)
            await fulfillment(of: [denied], timeout: 2)
            XCTAssertTrue(model.participation.voiceReplies.isEmpty)
            XCTAssertNil(model.participation.queuedText)
            XCTAssertTrue(model.participation.receipts.isEmpty)
        }
    }

    func testHandoffRecipientRequiresAVerbatimWholeNameAndAuthorizedRosterPrefix() {
        XCTAssertTrue(ParticipationPlanner.matchesHandoffName("Ann", in: "Can Ann answer?", allowedNames: ["Ann"]))
        XCTAssertTrue(ParticipationPlanner.matchesHandoffName("Ann", in: "Anna asked Ann.", allowedNames: ["Ann"]))
        XCTAssertFalse(ParticipationPlanner.matchesHandoffName("Ann", in: "Can Anna answer?", allowedNames: ["Ann"]))
        XCTAssertFalse(ParticipationPlanner.matchesHandoffName("Ann", in: "Can Ann-Marie answer?", allowedNames: ["Ann"]))
        XCTAssertFalse(ParticipationPlanner.matchesHandoffName("Ann", in: "Can D’Ann answer?", allowedNames: ["Ann"]))
        XCTAssertFalse(ParticipationPlanner.matchesHandoffName("Ann", in: "Can Ann\u{0301} answer?", allowedNames: ["Ann"]))
        XCTAssertFalse(ParticipationPlanner.matchesHandoffName("Ann", in: "Can Ann\u{200D}Marie answer?", allowedNames: ["Ann"]))
        XCTAssertFalse(ParticipationPlanner.matchesHandoffName("Ann", in: "Can Ann answer?", allowedNames: ["Ann Clark"]))
        XCTAssertTrue(ParticipationPlanner.matchesHandoffName("Виталий", in: "Виталий, вы на связи?",
                                                             allowedNames: ["виталий", "виталий смирнов"]))
        XCTAssertFalse(ParticipationPlanner.matchesHandoffName("ВИТАЛИЙ", in: "Виталий, вы на связи?",
                                                              allowedNames: ["виталий", "виталий смирнов"]))
    }

    @MainActor
    func testFragmentedHandoffUsesOnlyAdjacentLocalSpeechFromTheSameVerifiedParticipant() async throws {
        let name = "Виталий Смирнов"
        let speakerName = "Алексей Крылов"
        let opening = "Скажите, Виталий Смирнов на связи?"
        let followUp = "Может ответить?"
        let cases: [(sameSpeaker: Bool, interveningAnswer: Bool, ambiguousPrefix: Bool)] = [
            (true, false, false), (false, false, false), (true, true, false), (true, false, true),
        ]
        for fixture in cases {
            let (model, original) = try localParticipationFixture()
            let (store, cleanup) = try participationStore()
            defer { model.participation.stop(); cleanup() }
            var members = ["me": name, "peer": speakerName, "other": speakerName]
            if fixture.ambiguousPrefix { members["another"] = "Виталий Петров" }
            let roster = audience(original, members: members)
            model.participationAudienceForTesting = roster
            model.participationVoiceAvailableForTesting = true
            model.receiveFeaturesForTesting(.init())
            model.participation.decisionDelayForTesting = .milliseconds(25)
            let setup = try XCTUnwrap(model.participation.setup(for: model, store: store))
            XCTAssertTrue(model.participation.start(setup, objective: "", model: model, store: store, output: .voice))
            let generation = model.setParticipationLocalReceiverForTesting([
                "original-track": .init(participantID: "peer", since: .distantPast),
                "other-track": .init(participantID: "other", since: .distantPast),
            ])
            let hasAntecedent = fixture.sameSpeaker && !fixture.interveningAnswer
            let finished = expectation(description: "The latest fragment was checked")
            let observation = model.participation.$latestDecision.dropFirst().sink { progress in
                if progress?.reason == (hasAntecedent ? .voiceUnavailable : .quiet) { finished.fulfill() }
            }
            defer { observation.cancel() }
            model.participation.planForTesting = { input in
                XCTAssertEqual(input.currentTurn?.text, followUp)
                XCTAssertEqual(input.currentTurn?.speaker, speakerName)
                XCTAssertEqual(input.currentTurn?.own, false)
                XCTAssertEqual(input.handoffAntecedent?.text, hasAntecedent ? opening : nil)
                XCTAssertEqual(input.handoffLocalNames.count, fixture.ambiguousPrefix ? 1 : 2)
                return .init(kind: hasAntecedent ? .offerToTakeQuestion : .quiet, text: hasAntecedent ? "Да, на связи. Какой вопрос?" : "",
                    directlyAddressed: false, citations: [])
            }
            model.participation.assessForTesting = { decision, _, input in
                XCTAssertEqual(decision.citations.map(\.quote), [followUp])
                XCTAssertEqual(input.handoffAntecedent?.id, "local-transcript:opening")
                return hasAntecedent
            }
            let started = Date()
            model.receiveParticipationLocalLineForTesting(.init(id: "opening", trackID: "original-track",
                text: opening, start: started, end: Date()), generation: generation)
            if fixture.interveningAnswer {
                var features = GuestMeetingSnapshot()
                let answered = Date()
                features.messages = [.init(id: "answered", participantID: "me", participantName: name,
                    text: "Да, я на связи.", sentAt: answered, isOwn: true, receivedAt: answered)]
                model.receiveFeaturesForTesting(features)
            }
            let resumed = Date()
            model.receiveParticipationLocalLineForTesting(.init(id: "follow-up",
                trackID: fixture.sameSpeaker ? "original-track" : "other-track",
                text: followUp, start: resumed, end: Date()), generation: generation)
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertEqual(model.participation.voiceReplies.count, hasAntecedent ? 1 : 0)
            if hasAntecedent {
                XCTAssertEqual(model.participation.voiceReplies.last?.text,
                    "Да, на связи. Какой вопрос?")
            }
        }
    }

    private static func approvedAssessment(unauthorizedCommitment: Bool = false, superseded: Bool = false) -> ParticipationAssessment {
        .init(supported: true, relevantNow: true, directlyRequested: true, superseded: superseded, safeForRoom: true,
            unauthorizedCommitment: unauthorizedCommitment)
    }

    private func audience(_ template: ParticipationAudience, members: [String: String],
                          connection: ObjectIdentifier? = nil) -> ParticipationAudience {
        .init(sessionID: template.sessionID, room: template.room, providerRoom: template.providerRoom,
            providerGroup: template.providerGroup, localParticipant: template.localParticipant,
            members: members, connection: connection ?? template.connection)
    }

    @MainActor
    private func participationStore() throws -> (AttentionStore, () -> Void) {
        let suite = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = AttentionStore(root: root, defaults: defaults, keychain: .init(service: "participation-tests-\(suite)"))
        store.enabled = true
        store.provider = try XCTUnwrap(AttentionProvider.defaults[.rapidMLX])
        return (store, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        })
    }

    @MainActor
    private func localParticipationFixture() throws -> (NativeDesktopMeetingModel, ParticipationAudience) {
        let url = URL(string: "https://example.test/calls/local-participation")!
        let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest), name: "Me", title: "Local room")
        let room = try XCTUnwrap(MeetingRoomIdentity(url, engine: .guest))
        return (model, .init(sessionID: model.sessionID, room: room, providerRoom: "room", providerGroup: "group",
            localParticipant: "me", members: ["me": "Me", "peer": "Remote attendee"], connection: ObjectIdentifier(model)))
    }
}
