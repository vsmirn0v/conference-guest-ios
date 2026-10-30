import AVFoundation
import Foundation
import LiveKitWebRTC

enum GuestEngineError: Error { case malformed, admissionDenied, evicted, publicationTimedOut, disconnected, mediaMissing }

/// LiveKit's legacy stream ID carries the authoritative participant and track SID.
private struct GuestRemotePublication: Hashable {
    let participant: String
    let track: String
    init?(streamID: String) {
        let parts = streamID.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts[0].isEmpty, parts[1].hasPrefix("TR_") else { return nil }
        participant = String(parts[0]); track = String(parts[1])
    }
}

private struct GuestRemoteTrackState {
    let participant: String
    let type: String
    let source: String?
    let muted: Bool
}

/// Experimental guest signaling owner; intentionally absent from the application target.
@MainActor
final class NativeGuestEngine {
    /// Official next-room feature key registered by the transcription plugin.
    static let supportedFeatures: [String: Any] = ["transcription": true]
    let label: String
    let audio: GuestSyntheticAudio?
    let systemAudio: GuestSystemAudio?
    var releaseSystemAudio: ((Bool) async -> Bool)?
    private let icePolicy: GuestICEPolicy
    private let verifyReceivedPixels: Bool
    private let factory: LKRTCPeerConnectionFactory
    var onFailure: ((Error) -> Void)?
    var onForcedMute: ((Bool) -> Void)?
    var onMeetingChange: ((GuestMeetingSnapshot) -> Void)? {
        didSet { onMeetingChange?(meetingSnapshot) }
    }
    var meetingSnapshot: GuestMeetingSnapshot { meetingFeatures.snapshot }
    /// Production capture injection, also used for an explicitly selected device.
    var cameraCaptureFactory: ((LKRTCVideoSource) -> any GuestCameraCapture)?
    private var meetingFeatures = GuestMeetingFeatures()
    private var loadingChat = false
    private var loadingTranscript = false
    var onPermissionsChange: ((GuestMediaPermissions) -> Void)? {
        didSet { onPermissionsChange?(mediaPermissions) }
    }
    var onIncomingVideoChange: (([GuestRemoteVideo]) -> Void)? {
        didSet { onIncomingVideoChange?(incomingVideo) }
    }
    var onLocalCameraTrackChange: ((LKRTCVideoTrack?) -> Void)? {
        didSet { onLocalCameraTrackChange?(localCameraTrack) }
    }
    var mediaPermissions: GuestMediaPermissions {
        .init(canShareMicrophone: permissions["canShareMicrophone"] == true,
              canShareCamera: permissions["canShareCamera"] == true)
    }
    var incomingVideo: [GuestRemoteVideo] {
        guard !closing, !outputSuppressed, visibleParticipantIDs?.isEmpty != true else { return [] }
        return (subscriber?.receivedVideo ?? []).compactMap { video in
            var video = video
            let references = Set(video.streamIDs.compactMap(GuestRemotePublication.init(streamID:)))
            let trackID = references.count == 1 ? references.first?.track : video.track.trackId
            // Keep the receiver warm, but never show its frozen final frame
            // while muted or after its authoritative publication departs.
            if let trackID {
                if let state = remoteTracks[trackID] {
                    if state.muted { return nil }
                    if !receivesCameras, state.source != "SCREEN_SHARE" { return nil }
                    if let visibleParticipantIDs, state.source != "SCREEN_SHARE",
                       !visibleParticipantIDs.contains(remoteParticipantIdentities[state.participant] ?? "") { return nil }
                } else if seenRemoteVideoTrackIDs.contains(trackID) { return nil }
            }
            let metadata: (participant: String, name: String?, source: String?)?
            if let reference = references.first {
                // A reused RTC track ID must not associate a replacement with stale metadata.
                let candidate = remoteVideoMetadata[reference.track]
                metadata = references.count == 1 && candidate?.participant == reference.participant ? candidate : nil
            } else {
                metadata = remoteVideoMetadata[video.track.trackId]
            }
            if let metadata {
                video.participantName = metadata.name; video.source = metadata.source
                video.participantID = remoteParticipantIdentities[metadata.participant]
            }
            return video
        }
    }
    /// Cached decoded incoming PCM evidence; never waits on native stats or devices.
    var receivedAudioSamples: Int { subscriber?.pcmMeter.snapshot.samples ?? 0 }
    var localCameraTrack: LKRTCVideoTrack? {
        camera != nil && cameraStop == nil && localMuteIntent[true] == false && !outputSuppressed ? publisher?.localVideoTrack : nil
    }
    private(set) var sessionID: String?
    private(set) var connectedRemoteParticipants: Set<String> = []
    private(set) var remoteMediaGeneration: UInt64 = 0
    private var remoteTrackIDs: [String: Set<String>] = [:]
    private var remoteParticipantIdentities: [String: String] = [:]
    private var visibleParticipantIDs: Set<String>?
    private var preferredScreenParticipantID: String?
    private var receivesCameras = true
    private var leaveTask: Task<Bool, Never>?
    private var muteWaiters: [String: (Bool, GuestCompletion<Void>, Int)] = [:]
    private var localMuteIntent: [Bool: Bool] = [:]
    private var outputSuppressed = false
    private var startupPlaybackGain: GuestStartupPlaybackGain?
    private var participantVolumes: [String: Double] = [:]
    private var startupAudioTask: Task<Void, Error>?
    private var startupAudioGeneration = UUID()
    private var startupPlayoutEpoch: UUID?
    private var sharedPlayoutClosed = true
    private var startupAudioDeadline: TimeInterval?
    private var startupReadyTopology: GuestStartupAudioObservation.Topology?
    private var startupDecision: GuestStartupAudioReport.Decision?
    private var startupConnected = false
    private var startupReport: GuestStartupAudioReport?
    var startupAudioReport: [String: Any] { startupReport?.dictionary ?? [:] }
    private var localParticipantVersion = -1
    private var serverMute: [String: Bool] = [:]
    private var lastMediaEvent = ProcessInfo.processInfo.systemUptime
    private(set) var subscriber: GuestPeer?
    private var publisher: GuestPeer?
    private var transport: GuestTransport?
    private var reader: Task<Void, Never>?
    private var ping: Task<Void, Never>?
    private var closing = false
    private var cleanupSucceeded = false
    private var camera: (any GuestCameraCapture)?
    private var cameraStop: Task<Bool, Never>?
    private var cameraPublication = false
    private var screenCapture: (any GuestCameraCapture)?
    private var screenStop: Task<Bool, Never>?
    private var screenIntent = false
    private var screenStarting = false
    private var screenGeneration: UInt64 = 0
    var screenSharing: Bool { meetingFeatures.snapshot.screenSharing }
    var localScreenTrack: LKRTCVideoTrack? { screenSharing ? publisher?.localScreenVideoTrack : nil }
    func cameraCaptureDevice() async -> AVCaptureDevice? {
        guard !closing, localCameraTrack != nil, let capture = camera else { return nil }
        let device = await capture.captureDevice()
        guard !closing, camera === capture, localCameraTrack != nil else { return nil }
        return device
    }
    private var remoteVideoMetadata: [String: (participant: String, name: String?, source: String?)] = [:]
    private var remoteTracks: [String: GuestRemoteTrackState] = [:]
    private var seenRemoteVideoTrackIDs = Set<String>()
    private(set) var admittedParticipants = 0
    private var joined = false
    private var joinAttempted = false
    private var rtcJoined = false
    private(set) var screenCodecs: Set<String> = []
    private var localIdentity = ""
    private var subscriptions = Set<String>()
    private var activePublicationDemand = false
    private var participantVersions: [String: Int] = [:]
    private var permissions: [String: Bool] = [:]
    private var published: [String: String] = [:]
    private var publicationKinds: [String: String] = [:]
    private var forcedMuteSIDs = Set<String>()
    private var pendingPublications: [String: GuestCompletion<[String: Any]>] = [:]
    private(set) var failure: Error?
#if DEBUG
    private var videoTraceSubscriptionState: [String: Any] = [:]
    private var videoTraceSubscriptionRevision: UInt64 = 0
    func beginSharedSoundOffProofForTesting() throws -> GuestPeer.SoundOffSourceProof {
        try checkActive()
        guard startupConnected, startupPlaybackGain?.soundEnabled == false, let owner = systemAudio,
              owner.sharedPlayoutGateForTesting.permitsSoundOffProof(expected: startupPlayoutEpoch),
              let subscriber, subscriber.transportConnected, subscriber.receivedAudioSources.count == 1,
              let publication = knownPublication(subscriber.receivedAudioSources[0], type: "AUDIO"), !publication.muted,
              owner.startupAudioObservation.supports(input: true),
              let proof = subscriber.beginSoundOffSourceProofForTesting() else { throw GuestEngineError.disconnected }
        guard owner.sharedPlayoutGateForTesting.permitsSoundOffProof(expected: startupPlayoutEpoch) else {
            _ = proof.restore(); throw GuestEngineError.disconnected
        }
        return proof
    }
    var cameraFactoryForTesting: ((LKRTCVideoSource) -> any GuestCameraCapture)?
    /// Opt-in SDK transport probe only. Shipping/native companion never sets it.
    /// SFU addTrack admission remains authoritative; app screen permission UI
    /// and the full Presenter lifecycle are deliberately outside this hook.
    var diagnosticScreenShareProfileForTesting: GuestVideoProfile?
    var mediaNotifyForTesting: (([String: Any]) async throws -> Void)?
    var muteNotifyFinishedForTesting: (() -> Void)?
    var featureRequestForTesting: ((String, [String: Any], String?) async throws -> [String: Any])?
    var featureNotifyForTesting: ((String, [String: Any]) async throws -> Void)?
#endif

    init(label: String, systemAudio: GuestSystemAudio? = nil, icePolicy: GuestICEPolicy = .automatic, verifyReceivedPixels: Bool = true) {
        self.label = label; self.systemAudio = systemAudio; self.icePolicy = icePolicy
        self.verifyReceivedPixels = verifyReceivedPixels
        _ = LKRTCInitializeSSL()
        NativeScreenEncoderQuality.prepare()
        if let systemAudio { audio = nil; factory = systemAudio.factory }
        else {
            let synthetic = GuestSyntheticAudio(); audio = synthetic
            factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(),
                decoderFactory: LKRTCDefaultVideoDecoderFactory(), audioDevice: synthetic)
        }
    }

    func join(_ invitation: GuestInvitation, sessionID: String? = nil) async throws {
        LKRTCInitializeSSL()
        let prepared = try await GuestBootstrap().prepare(invitation, participantName: label,
            supportedFeatures: Self.supportedFeatures, sessionID: sessionID)
        try checkActive()
        let transport = GuestTransport(url: prepared.connectorURL, roomID: prepared.roomID, origin: invitation.origin)
        self.transport = transport
        subscriber = try makePeer(.subscriber)
        publisher = try makePeer(.publisher)
        reader = Task { [weak self] in
            for await event in transport.events {
                guard let self, !closing else { break }
                do { try await receive(event) }
                catch { recordFailure(error); break }
            }
            if let self, !closing { recordFailure(await transport.terminalError ?? GuestTransportError.closed) }
        }
        try await transport.connect()
        try checkActive()
        probeLog("transport-open", ["client": label, "nativeMacOS": true, "resumingSession": sessionID != nil])
        joinAttempted = true
        let response = try await transport.request(event: "join", payload: prepared.joinPayload)
        try checkActive()
        if let payload = response["payload"] as? [String: Any], payload["participant"] != nil {
            try await receive(["event": "joined", "payload": payload])
        }
        for _ in 0..<200 {
            try checkActive()
            if let failure { throw failure }
            if joined && rtcJoined { probeLog("guest-connected", ["client": label]); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw GuestTransportError.timedOut
    }

    private func makePeer(_ target: GuestPeerTarget) throws -> GuestPeer {
        let peer = try GuestPeer(target: target, factory: factory, physicalAudio: systemAudio != nil, icePolicy: icePolicy, verifyReceivedPixels: verifyReceivedPixels,
            startupPlaybackGain: startupPlaybackGain)
        if GuestPeer.diagnosticEventLogDirectory != nil { probeLog("rtc-event-log", ["client": label, "target": target.rawValue, "id": peer.diagnosticID]) }
        peer.sendCandidate = { [weak self] value in
            guard let self, !closing else { throw GuestPeerError.closed }
            try await media(["method": "rtc:ice", "rtcIceCandidates": [value]])
        }
        peer.onFailure = { [weak self] in self?.recordFailure($0) }
        if target == .subscriber {
            peer.onIncomingAudioChange = { [weak self, weak peer] in
                guard let self, let peer, self.subscriber === peer, !self.closing else { return }
                self.refreshSubscriberDemand(); self.continueArmedStartupAudio()
            }
            peer.onIncomingVideoChange = { [weak self, weak peer] _ in
                guard let self, let peer, self.subscriber === peer, !self.closing, !self.outputSuppressed else { return }
                self.refreshSubscriberDemand()
                self.onIncomingVideoChange?(self.incomingVideo)
            }
        }
        return peer
    }

    private func receive(_ event: [String: Any]) async throws {
        guard let kind = event["event"] as? String else { throw GuestEngineError.malformed }
        try checkActive()
        if kind != "joined", meetingFeatures.roomID != nil, !meetingFeatures.acceptsScope(event) { return }
        let payload = event["payload"] as? [String: Any] ?? [:]
        if !["media-out", "media-in"].contains(kind) {
            probeLog("signal-event", ["client": label, "kind": kind, "payloadKeys": payload.keys.sorted()])
        }
        switch kind {
        case "joined":
            guard let participant = payload["participant"] as? [String: Any],
                  let group = payload["participantGroup"] as? [String: Any],
                  let groupID = group["groupId"] as? String,
                  let roomID = payload["roomId"] as? String else { throw GuestEngineError.malformed }
            permissions = participant["permissions"] as? [String: Bool] ?? [:]
            onPermissionsChange?(mediaPermissions)
            self.sessionID = participant["sessionId"] as? String ?? sessionID
            await transport?.setScope(roomID: roomID, groupID: groupID)
            joined = true
            meetingFeatures.receive(event); meetingFeatures.setConnected(rtcJoined); emitMeetingChange()
            admittedParticipants = (group["participants"] as? [Any])?.count ?? 0
            probeLog("room-joined", ["client": label, "participants": (group["participants"] as? [Any])?.count ?? 0])
        case "media-out": try await receiveMedia(payload)
        case "permissions-updated":
            permissions.merge(payload as? [String: Bool] ?? [:]) { _, new in new }
            meetingFeatures.receive(event); emitMeetingChange()
            onPermissionsChange?(mediaPermissions)
            for (key, video) in [("canShareCamera", true), ("canShareMicrophone", false)] where permissions[key] == false {
                forceMute(video: video)
            }
            if permissions["canShareScreen"] == false { setScreenShareIntent(false) }
        case "evicted": throw GuestEngineError.evicted
        case "participant-left":
            meetingFeatures.receive(event); emitMeetingChange()
            if let id = payload["participantId"] as? String {
                let departing = remoteParticipantIdentities.filter { $0.value == id }.map { sid, identity in
                    ["sid": sid, "identity": identity, "version": (participantVersions[sid] ?? 0) + 1,
                     "state": "DISCONNECTED", "tracks": []] as [String: Any]
                }
                try await updateParticipants(departing)
            }
        case "participant-name-updated":
            meetingFeatures.receive(event); emitMeetingChange()
            if let id = payload["participantId"] as? String, let name = payload["participantName"] as? String {
                for (track, metadata) in remoteVideoMetadata where remoteParticipantIdentities[metadata.participant] == id {
                    remoteVideoMetadata[track] = (metadata.participant, name, metadata.source)
                }
                onIncomingVideoChange?(incomingVideo)
            }
        case "error":
            // Correlated errors are delivered to their request. Unsolicited errors fail closed.
            probeLog("server-error", ["client": label, "correlated": event["requestId"] != nil])
            if event["requestId"] == nil { throw GuestEngineError.admissionDenied }
        default:
            meetingFeatures.receive(event); emitMeetingChange()
            if ["participant-joined", "participant-left"].contains(kind) {
                probeLog(kind, ["client": label, "participantToken": (payload["participantId"] as? String).map { String($0.hashValue) } ?? "absent"])
            }
        }
    }

    private func receiveMedia(_ payload: [String: Any]) async throws {
        lastMediaEvent = ProcessInfo.processInfo.systemUptime
        guard let method = payload["method"] as? String else { throw GuestEngineError.malformed }
        if method != "rtc:ice" && method != "rtc:pong" { probeLog("media-event", ["client": label, "method": method]) }
        switch method {
        case "rtc:config":
            guard let config = payload["configuration"] as? [String: Any] else { throw GuestEngineError.malformed }
            try subscriber?.configure(config); try publisher?.configure(config)
            probeLog("rtc-config", ["client": label, "iceServers": (config["iceServers"] as? [Any])?.count ?? 0])
        case "rtc:join":
            guard let join = payload["join"] as? [String: Any], let participant = join["participant"] as? [String: Any],
                  let identity = participant["identity"] as? String else { throw GuestEngineError.malformed }
            localIdentity = identity; rtcJoined = true
            screenCodecs = Set(((join["room"] as? [String: Any])?["enabledCodecs"] as? [[String: Any]] ?? [])
                .compactMap { ($0["mime"] as? String)?.lowercased() })
            meetingFeatures.updateRTC([participant]); meetingFeatures.setConnected(joined)
            try await updateParticipants(join["otherParticipants"] as? [[String: Any]] ?? [])
            startPing(interval: (join["pingInterval"] as? NSNumber)?.doubleValue ?? 5,
                timeout: (join["pingTimeout"] as? NSNumber)?.doubleValue ?? 15)
        case "rtc:participants:update":
            let update = payload["update"] as? [String: Any] ?? [:]
            try await updateParticipants(update["participants"] as? [[String: Any]] ?? [])
        case "rtc:speakers:changed":
            meetingFeatures.updateSpeakers((payload["speakersChanged"] as? [String: Any])?["speakers"] as? [[String: Any]] ?? [])
            emitMeetingChange()
        case "rtc:offer":
            guard let description = payload["description"] as? [String: Any], let subscriber else { throw GuestEngineError.malformed }
            let answer = try await subscriber.answer(description)
            try await media(["method": "rtc:answer", "description": answer])
            try await subscriber.didSendDescription()
        case "rtc:answer":
            guard let description = payload["description"] as? [String: Any] else { throw GuestEngineError.malformed }
            try await publisher?.acceptAnswer(description)
            probeLog("publisher-answer", ["client": label])
        case "rtc:ice":
            guard let values = payload["rtcIceCandidates"] as? [[String: Any]] else { throw GuestEngineError.malformed }
            try await subscriber?.addCandidates(values); try await publisher?.addCandidates(values)
        case "rtc:track:published":
            guard let response = payload["trackPublishedResponse"] as? [String: Any], let cid = response["cid"] as? String,
                  let track = response["track"] as? [String: Any] else { throw GuestEngineError.malformed }
            if let kind = publicationKinds[cid], let sid = track["sid"] as? String {
                published[kind] = sid
                // Every registration requests muted=true. An accepted publish
                // response establishes that initial state even before RTP exists.
                serverMute[sid] = track["muted"] as? Bool ?? true
                if forcedMuteSIDs.contains(sid) {
                    if kind == "screen" { setScreenShareIntent(false) }
                    else { forceMute(video: kind == "video") }
                }
            }
            pendingPublications.removeValue(forKey: cid)?.finish(.success(track))
        case "rtc:track:subscription:quality:update":
            let update = payload["subscribedQualityUpdate"] as? [String: Any] ?? [:]
            let qualities = (update["subscribedQualities"] as? [[String: Any]] ?? []).compactMap { value -> [String: Any]? in
                guard let quality = value["quality"] as? String, ["LOW", "MEDIUM", "HIGH", "OFF"].contains(quality),
                      let enabled = value["enabled"] as? Bool else { return nil }
                return ["quality": quality, "enabled": enabled]
            }
            probeLog("publishing-quality-request", ["client": label, "matchesLocalVideo": (update["trackSid"] as? String).map { $0 == published["video"] } ?? false, "qualities": qualities])
        case "rtc:pong": probeLog("rtc-pong", ["client": label])
        case "rtc:track:muted":
            if let mute = payload["mute"] as? [String: Any], let sid = mute["sid"] as? String, mute["muted"] as? Bool == true {
                guard forcedMuteSIDs.count < 256 || forcedMuteSIDs.contains(sid) else { throw GuestEngineError.malformed }
                forcedMuteSIDs.insert(sid)
                for (kind, current) in published where current == sid {
                    if kind == "screen" { setScreenShareIntent(false); continue }
                    let video = kind == "video"
                    forceMute(video: video)
                }
            }
        default: break
        }
    }

    private func updateParticipants(_ participants: [[String: Any]]) async throws {
        meetingFeatures.updateRTC(participants); emitMeetingChange()
        for participant in participants {
            try checkActive()
            #if DEBUG
            if participant["identity"] as? String != localIdentity {
                let sid = participant["sid"] as? String
                probeLog("remote-snapshot", ["client": label,
                    "participantToken": sid.map { String($0.hashValue) } ?? "absent",
                    "identityToken": (participant["identity"] as? String).map { String($0.hashValue) } ?? "absent",
                    "hasIdentity": participant["identity"] is String, "hasSID": sid != nil,
                    "version": participant["version"] ?? "absent",
                    "previousVersion": sid.flatMap { participantVersions[$0] } ?? -1,
                    "state": participant["state"] ?? "absent", "keys": participant.keys.sorted(),
                    "acceptedVersion": (participant["version"] as? Int ?? 0) > (sid.flatMap { participantVersions[$0] } ?? -1)])
            }
            #endif
            guard let identity = participant["identity"] as? String,
                  let sid = participant["sid"] as? String else { continue }
            let version = participant["version"] as? Int ?? 0
            if identity == localIdentity {
                probeLog("local-snapshot", ["client": label, "version": version,
                    "previous": participantVersions[sid] ?? -1,
                    "tracks": (participant["tracks"] as? [[String: Any]] ?? []).map { ["type": $0["type"] as? String ?? "unknown", "muted": $0["muted"] as? Bool ?? true] }])
            }
            if let old = participantVersions[sid], old >= version { continue }
            participantVersions[sid] = version
            if identity == localIdentity {
                localParticipantVersion = version
                for track in participant["tracks"] as? [[String: Any]] ?? [] {
                    guard let trackSID = track["sid"] as? String, let muted = track["muted"] as? Bool else { continue }
                    serverMute[trackSID] = muted
                    if let waiter = muteWaiters[trackSID], waiter.0 == muted, version > waiter.2 {
                        muteWaiters.removeValue(forKey: trackSID)?.1.finish(.success(()))
                    }
                }
                continue
            }
            let previousParticipants = connectedRemoteParticipants, previousTracks = remoteTrackIDs
            if participant["state"] as? String == "DISCONNECTED" {
                connectedRemoteParticipants.remove(sid); remoteTrackIDs.removeValue(forKey: sid)
                remoteParticipantIdentities.removeValue(forKey: sid)
            } else {
                let retired = remoteParticipantIdentities.filter { $0.key != sid && $0.value == identity }.map(\.key)
                for old in retired {
                    connectedRemoteParticipants.remove(old); remoteTrackIDs.removeValue(forKey: old)
                    remoteParticipantIdentities.removeValue(forKey: old)
                    remoteVideoMetadata = remoteVideoMetadata.filter { $0.value.participant != old }
                    remoteTracks = remoteTracks.filter { $0.value.participant != old }
                }
                connectedRemoteParticipants.insert(sid)
                remoteParticipantIdentities[sid] = identity
                remoteTrackIDs[sid] = Set((participant["tracks"] as? [[String: Any]] ?? []).compactMap { $0["sid"] as? String })
            }
            if previousParticipants != connectedRemoteParticipants || previousTracks != remoteTrackIDs { remoteMediaGeneration &+= 1 }
            remoteVideoMetadata = remoteVideoMetadata.filter { $0.value.participant != sid }
            remoteTracks = remoteTracks.filter { $0.value.participant != sid }
            guard participant["state"] as? String != "DISCONNECTED" else {
                onIncomingVideoChange?(incomingVideo); continue
            }
            for track in participant["tracks"] as? [[String: Any]] ?? [] {
                guard let trackSID = track["sid"] as? String,
                      let type = track["type"] as? String,
                      type == "AUDIO" || type == "VIDEO" else { continue }
                let source = track["source"] as? String
                remoteTracks[trackSID] = .init(participant: sid, type: type, source: source,
                                                muted: track["muted"] as? Bool ?? true)
                if type == "VIDEO" {
                    seenRemoteVideoTrackIDs.insert(trackSID)
                    remoteVideoMetadata[trackSID] = (sid, participant["name"] as? String, source)
                }
            }
            onIncomingVideoChange?(incomingVideo)
        }
        // A receiver can attach before its publication metadata names the speaker.
        if !participantVolumes.isEmpty { startupPlaybackGain?.reconcile() }
        try await reconcileSubscriptions()
    }

    private func reconcileSubscriptions() async throws {
        guard rtcJoined else { return }
        // Audio stays subscribed through remote mute, so a later unmute is
        // audible without reopening the window. Limit video to what the gallery
        // can display; a new screen share takes priority over an unseen camera.
        let audioIDs = remoteTracks.filter { $0.value.type == "AUDIO" }.map(\.key)
        func eligible(_ track: GuestRemoteTrackState) -> Bool {
            // nil permits discovery; an explicit empty viewport retires all
            // video, including screens and warm muted subscriptions.
            guard visibleParticipantIDs?.isEmpty != true else { return false }
            if track.source == "SCREEN_SHARE" { return true }
            guard receivesCameras else { return false }
            guard let visibleParticipantIDs else { return true }
            return visibleParticipantIDs.contains(remoteParticipantIdentities[track.participant] ?? "")
        }
        let activeVideoIDs = remoteTracks.filter { $0.value.type == "VIDEO" && !$0.value.muted && eligible($0.value) }
            .map(\.key).sorted { lhs, rhs in
                let leftShare = remoteTracks[lhs]?.source == "SCREEN_SHARE"
                let rightShare = remoteTracks[rhs]?.source == "SCREEN_SHARE"
                if leftShare != rightShare { return leftShare }
                if leftShare, let preferredScreenParticipantID {
                    let leftPreferred = remoteTracks[lhs].flatMap { remoteParticipantIdentities[$0.participant] } == preferredScreenParticipantID
                    let rightPreferred = remoteTracks[rhs].flatMap { remoteParticipantIdentities[$0.participant] } == preferredScreenParticipantID
                    if leftPreferred != rightPreferred { return leftPreferred }
                }
                let leftActive = subscriptions.contains(lhs)
                let rightActive = subscriptions.contains(rhs)
                return leftActive == rightActive ? lhs < rhs : leftActive
            }
        let activeAudio = remoteTracks.values.contains { $0.type == "AUDIO" && !$0.muted }
        activePublicationDemand = activeAudio || !activeVideoIDs.isEmpty
        refreshSubscriberDemand()
        var videoIDs = Array(activeVideoIDs.prefix(6))
        // A camera can resume RTP before the SFU's unmute snapshot arrives.
        // Keep already-subscribed muted tracks warm while gallery capacity is
        // free, so a rapid camera toggle does not wait on a fresh subscription.
        if videoIDs.count < 6 {
            let retainedMuted = subscriptions.filter {
                guard let track = remoteTracks[$0] else { return false }
                return track.type == "VIDEO" && track.muted && eligible(track)
            }.sorted()
            videoIDs += retainedMuted.prefix(6 - videoIDs.count)
        }
        let desired = Set(audioIDs + videoIDs)
        let removed = subscriptions.subtracting(desired).sorted()
#if DEBUG
        let remoteVideoIDs = remoteTracks.keys.filter { remoteTracks[$0]?.type == "VIDEO" }.sorted()
        let traceState: [String: Any] = ["desired": Array(desired.sorted().prefix(64)), "desiredCount": desired.count,
            "remoteVideoCount": remoteVideoIDs.count, "videoTracks": remoteVideoIDs.prefix(64).map { id -> [String: Any] in
                ["trackID": id, "muted": remoteTracks[id]?.muted ?? true, "source": remoteTracks[id]?.source ?? ""]
            }]
        if !NSDictionary(dictionary: traceState).isEqual(to: videoTraceSubscriptionState) {
            videoTraceSubscriptionState = traceState; videoTraceSubscriptionRevision += 1
            probeLog("video-subscription-intent", traceState.merging(["client": label,
                "peerID": subscriber?.diagnosticID ?? "", "revision": videoTraceSubscriptionRevision]) { _, value in value })
        }
#endif
        if !removed.isEmpty {
#if DEBUG
            probeLog("video-subscription-request", ["client": label, "peerID": subscriber?.diagnosticID ?? "",
                "subscribe": false, "trackIDs": Array(removed.prefix(64)), "count": removed.count])
#endif
            try await media(["method": "rtc:track:subscription:change",
                             "subscription": ["trackSids": removed, "subscribe": false]])
            subscriptions.subtract(removed)
        }
        let added = desired.subtracting(subscriptions).sorted()
        if !added.isEmpty {
#if DEBUG
            probeLog("video-subscription-request", ["client": label, "peerID": subscriber?.diagnosticID ?? "",
                "subscribe": true, "trackIDs": Array(added.prefix(64)), "count": added.count])
#endif
            try await media(["method": "rtc:track:subscription:change",
                             "subscription": ["trackSids": added, "subscribe": true]])
            subscriptions.formUnion(added)
        }
        for trackSID in added {
            guard let track = remoteTracks[trackSID] else { continue }
            if track.type == "VIDEO" {
                var width = 1280, height = 720
#if DEBUG
                if track.source == "SCREEN_SHARE", let profile = diagnosticScreenShareProfileForTesting {
                    width = Int(profile.width); height = Int(profile.height)
                }
#endif
                try await media(["method": "rtc:track:settings:update", "trackSetting": [
                    "trackSids": [trackSID], "disabled": false, "width": width, "height": height, "quality": "HIGH"]])
            }
            probeLog("subscribe", ["client": label, "kind": track.type])
        }
    }

    func publishPattern(codec: String, camera useCamera: Bool = false, audioMuted: Bool = false, videoMuted: Bool = false) async throws {
        guard joined, rtcJoined, let publisher else { throw GuestEngineError.admissionDenied }
        if localMuteIntent[false] == nil { localMuteIntent[false] = audioMuted }
        if localMuteIntent[true] == nil { localMuteIntent[true] = videoMuted }
        cameraPublication = useCamera
        // A muted join can always receive. Register only publication kinds the
        // room permits; unmuted requests still fail clearly when prohibited.
        for (video, muted) in [(false, audioMuted), (true, videoMuted)] {
            if permissions[video ? "canShareCamera" : "canShareMicrophone"] != true && !muted {
                throw GuestEngineError.admissionDenied
            }
        }
        if let systemAudio, !(await systemAudio.setMicrophoneMuted(true)) { throw GuestEngineError.disconnected }
        if mediaPermissions.canShareMicrophone {
            let cid = UUID().uuidString.lowercased()
            let audio = publisher.prepareAudio(cid: cid, profile: systemAudio?.profile ?? .speech)
            audio.isEnabled = false
            try requirePermission(video: false)
            let info = try await register(["cid": cid, "type": "AUDIO", "source": "MICROPHONE", "muted": true])
            guard let sid = info["sid"] as? String else { throw GuestEngineError.malformed }
            try requirePermission(video: false)
            published["audio"] = sid
            try publisher.attach(audio, codec: codec)
        }
        if mediaPermissions.canShareCamera {
            let cid = UUID().uuidString.lowercased()
            var profile: GuestVideoProfile = useCamera ? .camera : .pattern
            var publicationSource = "CAMERA"
#if DEBUG
            if let screen = diagnosticScreenShareProfileForTesting {
                guard useCamera, cameraFactoryForTesting != nil else { throw GuestEngineError.malformed }
                profile = screen; publicationSource = "SCREEN_SHARE"
            }
#endif
            let video = publisher.prepareVideo(cid: cid, profile: profile, screenCast: publicationSource == "SCREEN_SHARE")
            video.isEnabled = false
            try requirePermission(video: true)
            let info = try await register(["cid": cid, "type": "VIDEO", "source": publicationSource, "muted": true,
                "width": profile.width, "height": profile.height, "layers": [profile.layer],
                "simulcastCodecs": [["codec": codec.lowercased(), "cid": cid]]])
            guard let sid = info["sid"] as? String else { throw GuestEngineError.malformed }
#if DEBUG
            if diagnosticScreenShareProfileForTesting != nil {
                guard info["source"] as? String == "SCREEN_SHARE" else { throw GuestEngineError.malformed }
                probeLog("diagnostic-screen-registration", ["requestedSource": publicationSource,
                    "acceptedSource": info["source"] as? String ?? "absent", "profile": profile.layer])
            }
#endif
            try requirePermission(video: true)
            published["video"] = sid
            try publisher.attach(video, codec: codec)
            try publisher.setMuted(true, video: true)
        }
        guard !published.isEmpty else { return }
        try await media(["method": "rtc:offer", "description": try await publisher.makeOffer()])
        try await publisher.didSendDescription()
        try checkActive()
        // Registration starts muted; the video-unmute path alone starts the
        // synthetic generator or physical camera after permission checks.
        if published["audio"] != nil { try await mute(localMuteIntent[false] ?? true, video: false) }
        if published["video"] != nil { try await mute(localMuteIntent[true] ?? true, video: true) }
        probeLog("publishing", ["client": label, "codecRequested": codec, "synthetic": !useCamera])
    }

    func activateMicrophone() async throws {
        try checkActive()
        if let systemAudio, !(await systemAudio.activateMicrophone()) {
            throw GuestSystemAudioError.microphoneActivationFailure(authorization: AVCaptureDevice.authorizationStatus(for: .audio))
        }
        try checkActive()
    }

    func setPlayoutEnabled(_ enabled: Bool) async throws {
        try checkActive()
        setStartupPlaybackIntent(enabled)
        try checkActive()
        if let systemAudio, !(await systemAudio.setPlayoutEnabled(enabled, expectedEpoch: startupPlayoutEpoch)) {
            throw GuestEngineError.disconnected
        }
        try checkActive()
    }

    func configureStartupPlayback(sound: Bool) {
        guard !closing else { return }
        startupPlayoutEpoch = systemAudio?.playoutEpoch
        if systemAudio?.closeSharedPlayout(expected: startupPlayoutEpoch) == false {
            sharedPlayoutClosed = false; recordFailure(GuestEngineError.disconnected); return
        }
        _ = systemAudio?.setSharedSoundIntent(sound, expected: startupPlayoutEpoch)
        startupPlaybackGain = GuestStartupPlaybackGain(sound: sound)
        startupPlaybackGain?.level = { [weak self] source in self?.participantLevel(source) ?? 1 }
        startupReport = .init(configuredUptime: ProcessInfo.processInfo.systemUptime,
            initialSoundIntent: sound, latestSoundIntent: sound)
    }

    /// Listener-only levels keyed by participant identity; nothing is signaled.
    func setParticipantVolumes(_ volumes: [String: Double]) {
        participantVolumes = volumes
        startupPlaybackGain?.reconcile()
    }
    private func participantLevel(_ source: GuestStartupPlaybackGain.Source) -> Double {
        guard !participantVolumes.isEmpty, let publication = knownPublication(source, type: "AUDIO"),
              let identity = remoteParticipantIdentities[publication.participant] else { return 1 }
        return participantVolumes[identity] ?? 1
    }

    /// Intent is recorded immediately, even when session control is awaiting readiness.
    func setStartupPlaybackIntent(_ enabled: Bool) {
        if let systemAudio {
            let accepted = systemAudio.setSharedSoundIntent(enabled, expected: startupPlayoutEpoch)
            if !accepted, systemAudio.playoutEpoch == startupPlayoutEpoch {
                sharedPlayoutClosed = false; recordFailure(GuestEngineError.disconnected)
            }
        }
        startupPlaybackGain?.setSound(enabled); startupReport?.latestSoundIntent = enabled
        if let systemAudio {
            if enabled, startupPlaybackGain?.isOpen == true,
               !systemAudio.sharedPlayoutIsOpen(expected: startupPlayoutEpoch) {
                startupPlaybackGain?.hold(); startupDecision = nil; startupReadyTopology = nil
            }
        }
        continueArmedStartupAudio()
    }

    private var startupRequiresInput: Bool {
        published["audio"] != nil && systemAudio?.snapshot["inputAvailable"] as? Bool == true
    }

    private func knownPublication(_ source: GuestStartupPlaybackGain.Source, type: String) -> GuestRemoteTrackState? {
        let references = Set(source.streamIDs.compactMap(GuestRemotePublication.init(streamID:)))
        guard references.count <= 1 else { return nil }
        let id = references.count == 1 ? references.first?.track : source.trackID
        guard let id, let publication = remoteTracks[id], publication.type == type else { return nil }
        if let reference = references.first, reference.participant != publication.participant { return nil }
        return publication
    }
    private func refreshSubscriberDemand() {
        guard let subscriber, !closing else { return }
        // Unacknowledged desired publications already count as demand. An
        // attached receiver remains conservative until typed metadata resolves
        // it; matched muted/offscreen publications do not reactivate idle ICE.
        let unknownAudio = subscriber.receivedAudioSources.contains { knownPublication($0, type: "AUDIO") == nil }
        let unknownVideo = subscriber.receivedVideo.contains {
            knownPublication(.init(trackID: nil, streamIDs: $0.streamIDs), type: "VIDEO") == nil
        }
        subscriber.setActiveIncomingMediaDemand(activePublicationDemand || unknownAudio || unknownVideo)
    }
    private func startupReceiveReadiness(_ sources: GuestStartupPlaybackGain.SourceSnapshot) -> GuestStartupAudioReceiveReadiness {
        // remoteTracks is authoritative even while subscribe acknowledgement is
        // pending. A receiver without matching metadata remains conservative.
        let active = remoteTracks.values.contains { $0.type == "AUDIO" && !$0.muted }
        let sourceRequiresTransport = sources.sources.contains { source in
            guard let publication = knownPublication(source, type: "AUDIO") else { return true }
            return !publication.muted
        }
        return .init(activePublication: active, sourceRequiresTransport: sourceRequiresTransport,
                     transportConnected: subscriber?.transportConnected == true)
    }

    func waitForStartupAudio() async throws {
        guard let gain = startupPlaybackGain, !gain.isOpen, let owner = systemAudio else { return }
        if let task = startupAudioTask { try await task.value; return }
        let generation = startupAudioGeneration
        if startupAudioDeadline == nil { startupAudioDeadline = ProcessInfo.processInfo.systemUptime + 8 }
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            defer { self.startupAudioTask = nil }
            var stability = GuestStartupAudioStability()
#if DEBUG
            @MainActor func record(_ event: String) {
                let now = ProcessInfo.processInfo.systemUptime
                let value = owner.startupAudioObservation
                let receive = startupReceiveReadiness(gain.sourceSnapshot)
                startupReport?.record(["event": event, "uptime": now,
                    "deadline": startupAudioDeadline ?? 0, "inputRequired": startupRequiresInput,
                    "receiveTransportRequired": receive.requiresTransport, "receiveTransportConnected": receive.transportConnected,
                    "supports": value.supports(input: startupRequiresInput), "observation": value.evidence,
                    "stability": stability.evidence(at: now), "tap": owner.startupCallbackEvidence])
            }
#endif
            do {
            while ProcessInfo.processInfo.systemUptime < (startupAudioDeadline ?? 0) {
                try checkActive()
                guard generation == startupAudioGeneration else { throw CancellationError() }
                if !gain.soundEnabled { startupDecision = .soundDisabled; return }
                if !startupRequiresInput && !gain.hasSources && !startupReceiveReadiness(gain.sourceSnapshot).requiresTransport {
                    startupDecision = .noDemand; return
                }
                guard await GuestStartupAudioBudget.refresh(deadline: startupAudioDeadline ?? 0,
                    clock: { ProcessInfo.processInfo.systemUptime },
                    read: { await owner.refreshSnapshot(timeout: $0) }) else { throw GuestStartupAudioError.timedOut }
                try checkActive()
                guard generation == startupAudioGeneration else { throw CancellationError() }
                let value = owner.startupAudioObservation
                let ready = stability.observe(value, input: startupRequiresInput, at: ProcessInfo.processInfo.systemUptime)
                let receiveReady = startupReceiveReadiness(gain.sourceSnapshot).ready
#if DEBUG
                record("observed")
#endif
                if ready && receiveReady {
                    startupReadyTopology = value.topology; startupDecision = .active
                    startupReport?.graphReadyUptime = ProcessInfo.processInfo.systemUptime
                    return
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw GuestStartupAudioError.timedOut
            } catch {
#if DEBUG
                record("failed")
                let value: [String: Any] = ["event": "startup-audio-failure",
                    "error": String(describing: error), "generation": generation.uuidString,
                    "report": startupReport?.dictionary ?? [:], "owner": owner.snapshot]
                if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                   let json = String(data: data, encoding: .utf8) { NSLog("%@", json) }
#endif
                throw error
            }
        }
        startupAudioTask = task
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    /// No await separates gain release from GuestSession's Connected notification.
    func releaseStartupAudio() -> Bool {
        guard !closing, failure == nil, !outputSuppressed else { return false }
        guard let gain = startupPlaybackGain else { return true }
        if gain.isOpen {
            if !gain.soundEnabled || systemAudio?.sharedPlayoutIsOpen(expected: startupPlayoutEpoch) != false { return true }
            gain.hold(); startupDecision = nil; startupReadyTopology = nil
            return false
        }
        switch startupDecision {
        case .soundDisabled: guard !gain.soundEnabled else { return false }
        case .noDemand:
            guard !startupRequiresInput, !gain.hasSources,
                  !startupReceiveReadiness(gain.sourceSnapshot).requiresTransport else { return false }
        case .active:
            let sources = gain.sourceSnapshot
            guard ProcessInfo.processInfo.systemUptime < (startupAudioDeadline ?? 0),
                  gain.soundEnabled, startupReadyTopology == systemAudio?.startupAudioObservation.topology,
                  startupReceiveReadiness(sources).ready,
                  gain.open(expectedSourceRevision: sources.revision, releaseGlobal: {
                      guard ProcessInfo.processInfo.systemUptime < (self.startupAudioDeadline ?? 0) else { return false }
                      guard self.systemAudio?.openSharedPlayout(expected: self.startupPlayoutEpoch) != false,
                            ProcessInfo.processInfo.systemUptime < (self.startupAudioDeadline ?? 0) else {
                          _ = self.systemAudio?.closeSharedPlayout(expected: self.startupPlayoutEpoch)
                          return false
                      }
                      return true
                  }) else {
                _ = systemAudio?.closeSharedPlayout(expected: startupPlayoutEpoch)
                startupDecision = nil; startupReadyTopology = nil
                return false
            }
            startupReport?.openUptime = ProcessInfo.processInfo.systemUptime
        default: return false
        }
        startupReport?.decision = startupDecision
        startupConnected = true
        return true
    }

    private func continueArmedStartupAudio() {
        guard startupConnected, let gain = startupPlaybackGain, !gain.isOpen, gain.soundEnabled,
              !closing, failure == nil, startupAudioTask == nil else { return }
        startupAudioDeadline = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                repeat { try await waitForStartupAudio() } while !releaseStartupAudio()
            } catch { if !closing, !(error is CancellationError) { recordFailure(error) } }
        }
    }

    private func suppressCamera() {
        guard let camera else { return }
        camera.cancel()
        onLocalCameraTrackChange?(nil)
        if cameraStop == nil {
            cameraStop = Task { do { try await camera.stop(); return true } catch { return false } }
        }
    }

    private func drainCameraStop() async throws {
        guard let cameraStop else { return }
        let stopped = await cameraStop.value
        guard stopped else { throw GuestCameraError.timedOut }
        self.cameraStop = nil; camera = nil
    }

    private func startCameraIfNeeded() async throws {
        try await drainCameraStop()
        guard cameraPublication, camera == nil, localMuteIntent[true] == false, !outputSuppressed else { return }
        try requirePermission(video: true)
        guard let source = publisher?.source else { throw GuestPeerError.malformed }
        let capture: any GuestCameraCapture
#if DEBUG
        capture = cameraFactoryForTesting?(source) ?? cameraCaptureFactory?(source) ?? GuestCamera(source: source)
#else
        capture = cameraCaptureFactory?(source) ?? GuestCamera(source: source)
#endif
        camera = capture
        do {
            let info = try await capture.start()
            try checkActive()
            guard localMuteIntent[true] == false, !outputSuppressed else {
                suppressCamera(); try await drainCameraStop(); return
            }
            try requirePermission(video: true)
            onLocalCameraTrackChange?(localCameraTrack)
            probeLog("native-camera-started", ["width": info.width, "height": info.height, "fps": info.fps,
                "mirrored": info.mirrored, "rotation": info.rotationDegrees, "pixelFormat": info.pixelFormat,
                "requestedWidth": info.requestedWidth, "requestedHeight": info.requestedHeight,
                "requestedFPS": info.requestedFPS, "sessionPreset": info.sessionPreset,
                "minimumFrameDurationValue": info.minimumFrameDuration.value,
                "minimumFrameDurationTimescale": info.minimumFrameDuration.timescale,
                "maximumFrameDurationValue": info.maximumFrameDuration.value,
                "maximumFrameDurationTimescale": info.maximumFrameDuration.timescale])
        } catch {
            suppressCamera(); try? await drainCameraStop()
            if localMuteIntent[true] == true || outputSuppressed { return }
            throw error
        }
    }

    func requestCameraReaction() async -> Bool { await camera?.performReaction() ?? false }
    var observedCameraReaction: Bool { camera?.snapshot().observedReaction ?? false }

    private func register(_ request: [String: Any], kind: String? = nil) async throws -> [String: Any] {
        guard !closing, let cid = request["cid"] as? String else { throw GuestEngineError.malformed }
        let completion = GuestCompletion<[String: Any]>()
        pendingPublications[cid] = completion
        publicationKinds[cid] = kind ?? (request["type"] as? String == "VIDEO" ? "video" : "audio")
        defer { pendingPublications.removeValue(forKey: cid); publicationKinds.removeValue(forKey: cid) }
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation, timeout: 15)
                Task { [weak self] in
                    do { try await self?.media(["method": "rtc:track:add", "addTrackRequest": request]) }
                    catch { completion.finish(.failure(error)) }
                }
            }
        }, onCancel: { completion.finish(.failure(CancellationError())) })
    }

    /// Synchronous privacy barrier used even while publication/control is suspended.
    func setLocalMuteIntent(_ muted: Bool, video: Bool) {
        localMuteIntent[video] = muted
        meetingFeatures.setLocalMute(muted, video: video); emitMeetingChange()
        if !muted, let sid = published[video ? "video" : "audio"] { forcedMuteSIDs.remove(sid) }
        if muted {
            publisher?.suppress(video: video)
            if video { publisher?.stopPattern(); suppressCamera() }
            if !video { systemAudio?.suppressMicrophone() }
            if let sid = published[video ? "video" : "audio"], let waiter = muteWaiters[sid], !waiter.0 {
                // Resolve a superseded unmute; its caller rechecks current intent.
                muteWaiters.removeValue(forKey: sid)?.1.finish(.success(()))
            }
        }
    }

    func suppressOutgoingMedia() {
        sharedPlayoutClosed = (systemAudio?.closeSharedPlayout(expected: startupPlayoutEpoch) ?? true) && sharedPlayoutClosed
        startupPlaybackGain?.close(); startupAudioTask?.cancel(); startupAudioGeneration = UUID()
        startupReport?.retiredUptime = ProcessInfo.processInfo.systemUptime
        outputSuppressed = true
        setScreenShareIntent(false)
        meetingFeatures.setConnected(false); emitMeetingChange()
        onIncomingVideoChange?([])
        setLocalMuteIntent(true, video: false); setLocalMuteIntent(true, video: true)
        publisher?.stopPattern()
    }

    private func forceMute(video: Bool) {
        setLocalMuteIntent(true, video: video)
        onForcedMute?(video)
    }

    private func requirePermission(video: Bool) throws {
        try checkActive()
        guard !outputSuppressed, permissions[video ? "canShareCamera" : "canShareMicrophone"] == true else {
            throw GuestEngineError.admissionDenied
        }
    }

    func mute(_ muted: Bool, video: Bool = false) async throws {
        try checkActive()
        guard let sid = published[video ? "video" : "audio"], let publisher else {
            if muted { return }
            throw GuestEngineError.admissionDenied
        }
        if localMuteIntent[video] == nil { localMuteIntent[video] = muted }
        if muted {
            publisher.suppress(video: video)
            if video { publisher.stopPattern(); suppressCamera(); try await drainCameraStop() }
            else if let systemAudio, !(await systemAudio.setMicrophoneMuted(true)) { throw GuestEngineError.disconnected }
        }
        // A superseding mute/permission revocation can arrive while this command
        // awaits the SFU. It must never be overwritten by this older unmute.
        if !muted, (localMuteIntent[video] != false || outputSuppressed) { return }
        if !muted, permissions[video ? "canShareCamera" : "canShareMicrophone"] != true {
            forceMute(video: video); return
        }
        if !video && !muted, let systemAudio, !systemAudio.canUnmuteMicrophone {
            throw GuestSystemAudioError.microphoneActivationFailure(authorization: AVCaptureDevice.authorizationStatus(for: .audio))
        }
        if video && !muted {
            if cameraPublication { try await startCameraIfNeeded() }
            else { try publisher.startPattern() }
            guard localMuteIntent[video] == false, !outputSuppressed else { return }
        }
        if serverMute[sid] != muted {
            let completion = GuestCompletion<Void>()
            guard muteWaiters[sid] == nil else { throw GuestEngineError.malformed }
            muteWaiters[sid] = (muted, completion, localParticipantVersion)
            defer { muteWaiters.removeValue(forKey: sid) }
            do { try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { continuation in
                    completion.install(continuation, timeout: 5)
                    Task { [weak self] in
#if DEBUG
                        defer { self?.muteNotifyFinishedForTesting?() }
#endif
                        do {
                            guard let self else { throw GuestEngineError.disconnected }
                            try await self.media(["method": "rtc:track:muted", "mute": ["sid": sid, "muted": muted]])
                            // The SFU does not advertise a newly registered video
                            // track until RTP arrives. Prime only after sending the
                            // unmute intent, then regenerate a keyframe after its
                            // authoritative participant update below.
                            if video && !muted && self.localMuteIntent[video] == false && !self.outputSuppressed {
                                try self.requirePermission(video: true)
                                try publisher.setMuted(false, video: true)
                            }
                        } catch { completion.finish(.failure(error)) }
                    }
                }
            }, onCancel: { completion.finish(.failure(CancellationError())) })
            } catch {
                probeLog("local-mute-unconfirmed", ["client": label, "video": video, "muted": muted,
                    "causeType": String(describing: type(of: error)),
                    "participantVersion": localParticipantVersion, "trackAdvertised": serverMute[sid] != nil,
                    "physicalAudio": systemAudio?.snapshot ?? [:]])
                throw error
            }
        }
        try checkActive()
        if !muted {
            guard localMuteIntent[video] == false, !outputSuppressed else { return }
            try requirePermission(video: video)
            if !video, let systemAudio {
                guard await systemAudio.setMicrophoneMuted(false) else { throw GuestEngineError.disconnected }
                try checkActive()
                guard localMuteIntent[video] == false, !outputSuppressed else {
                    _ = await systemAudio.setMicrophoneMuted(true); return
                }
                try requirePermission(video: video)
            }
            if video { try publisher.setMuted(true, video: true) }
            try publisher.setMuted(false, video: video)
        }
        probeLog("local-mute", ["client": label, "video": video, "muted": muted, "serverConfirmed": true])
    }

    private func startPing(interval: Double, timeout: Double) {
        ping?.cancel()
        guard interval.isFinite, interval >= 0, interval <= 300, timeout.isFinite, timeout >= 0, timeout <= 300 else { recordFailure(GuestEngineError.malformed); return }
        lastMediaEvent = ProcessInfo.processInfo.systemUptime
        guard interval > 0 || timeout > 0 else { return }
        ping = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64((interval > 0 ? interval : min(timeout, 1)) * 1_000_000_000))
                    guard let self, !closing else { return }
                    if timeout > 0 && ProcessInfo.processInfo.systemUptime - lastMediaEvent > timeout + 1 { throw GuestTransportError.timedOut }
                    if interval > 0 { try await media(["method": "rtc:ping", "ping_req": ["timestamp": Int64(Date().timeIntervalSince1970 * 1000), "rtt": 0]]) }
                } catch { if !Task.isCancelled { self?.recordFailure(error) }; return }
            }
        }
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        guard !closing else { throw CancellationError() }
        if let failure { throw failure }
    }

    private func media(_ payload: [String: Any]) async throws {
#if DEBUG
        if let notify = mediaNotifyForTesting {
            try checkActive(); try await notify(payload); return
        }
#endif
        guard !closing, let transport else { throw GuestEngineError.disconnected }
        try await transport.notify(event: "media-in", payload: payload)
    }
    private func recordFailure(_ error: Error) {
        guard !closing, failure == nil else { return }
        failure = error
        setScreenShareIntent(false)
        meetingFeatures.setConnected(false); emitMeetingChange()
        for waiter in pendingPublications.values { waiter.finish(.failure(error)) }
        for waiter in muteWaiters.values { waiter.1.finish(.failure(error)) }
        onFailure?(error)
        probeLog("engine-failure", ["client": label, "errorType": String(describing: type(of: error))])
    }

#if DEBUG
    func videoTraceStateForTesting(_ target: GuestPeerTarget, includingDemand: Bool = false) -> [String: Any]? {
        guard !closing else { return nil }
        guard var state = (target == .publisher ? publisher : subscriber)?.videoTraceStateForTesting else { return nil }
        state["localVideoMutedIntent"] = localMuteIntent[true].map { $0 as Any } ?? NSNull()
        if includingDemand {
            state["subscriptionState"] = videoTraceSubscriptionState
            state["subscriptionRevision"] = videoTraceSubscriptionRevision
            state["confirmedSubscriptions"] = Array(subscriptions.sorted().prefix(64))
            state["confirmedSubscriptionCount"] = subscriptions.count
        }
        return state
    }
    func screenShareStatsForTesting(_ target: GuestPeerTarget) async -> [[String: Any]]? {
        guard !closing else { return nil }
        return await (target == .publisher ? publisher : subscriber)?.stats()
    }
#endif

    func evidence() async -> [String: Any] {
        let statisticsStartedUptime = ProcessInfo.processInfo.systemUptime
        let physicalAudioFresh = await systemAudio?.refreshSnapshot() ?? false
        let rx = await subscriber?.stats(), tx = await publisher?.stats()
        if let camera {
            let snapshot = camera.snapshot()
            probeLog("camera-evidence", ["frames": snapshot.frames, "advancingPTS": snapshot.advancingPTS,
                "width": snapshot.width, "height": snapshot.height, "dropped": snapshot.dropped,
                "systemBackgroundSelected": snapshot.systemBackgroundSelected as Any? ?? NSNull(),
                "systemBackgroundActive": snapshot.systemBackgroundActive as Any? ?? NSNull(),
                "reactionObserved": snapshot.observedReaction, "startupMilliseconds": snapshot.startupMilliseconds])
        }
        return ["statisticsStartedUptime": statisticsStartedUptime,
            "statisticsCompletedUptime": ProcessInfo.processInfo.systemUptime,
            "client": label, "icePolicy": icePolicy.rawValue, "joined": joined, "rtcJoined": rtcJoined, "failed": failure != nil,
            "render": subscriber?.renderer.evidence ?? [:], "subscriberConnected": subscriber?.iceConnected ?? false,
            "decodedAudioRMS": (audio?.snapshot ?? subscriber?.pcmMeter.snapshot ?? .init()).rms,
            "physicalAudio": systemAudio?.snapshot ?? [:],
            "physicalInputMeter": systemAudio?.privateInputMeterEvidence ?? [:],
            "physicalPlayoutMeter": systemAudio?.playoutMeterEvidence ?? [:],
            "physicalAudioSnapshotFresh": physicalAudioFresh,
            "subscriberStatsFresh": rx != nil, "publisherStatsFresh": tx != nil,
            "localVideo": publisher?.localVideoState ?? [:], "stats": (rx ?? []) + (tx ?? []), "subscriptions": subscriptions.count, "publications": published.count]
    }

    var publicationIdentity: [String: String] {
        published.merging(publisher?.publicationIdentity ?? [:]) { old, _ in old }
    }

    var mediaSnapshot: GuestMediaSnapshot {
        GuestMediaSnapshot(render: subscriber?.renderer.evidence ?? [:], audio: audio?.snapshot ?? subscriber?.pcmMeter.snapshot ?? .init(),
            connected: subscriber?.iceConnected == true, failed: failure != nil)
    }

    var cameraSnapshot: GuestCameraSnapshot? { camera?.snapshot() }

    @discardableResult
    func leave(sendLeave: Bool = true) async -> Bool {
        if let leaveTask { return await leaveTask.value }
        suppressOutgoingMedia()
        closing = true; onFailure = nil; onForcedMute = nil
        meetingFeatures.stop(); emitMeetingChange(); onMeetingChange = nil
        onIncomingVideoChange?([]); onLocalCameraTrackChange?(nil)
        onIncomingVideoChange = nil; onLocalCameraTrackChange = nil; onPermissionsChange = nil
        let task = Task { await self.cleanup(sendLeave: sendLeave) }
        leaveTask = task
        return await task.value
    }

    func interruptTransportForTesting() async { await transport?.close() }

    private func cleanup(sendLeave: Bool) async -> Bool {
        for waiter in muteWaiters.values { waiter.1.finish(.failure(CancellationError())) }
        muteWaiters.removeAll()
        ping?.cancel(); ping = nil
        for waiter in pendingPublications.values { waiter.finish(.failure(CancellationError())) }
        pendingPublications.removeAll()
        if sendLeave, joinAttempted, let transport {
            do { _ = try await transport.request(event: "leave", timeout: 3); probeLog("leave-ack", ["client": label]) }
            catch { probeLog("leave-unacknowledged", ["client": label]) }
        }
        var cameraStopped = true
        suppressCamera()
        do { try await drainCameraStop() } catch { cameraStopped = false }
        var screenStopped = true
        setScreenShareIntent(false)
        do { try await drainScreenStop() } catch { screenStopped = false }
        remoteVideoMetadata.removeAll()
        remoteTracks.removeAll(); seenRemoteVideoTrackIDs.removeAll(); subscriptions.removeAll()
        remoteParticipantIdentities.removeAll(); connectedRemoteParticipants.removeAll(); remoteTrackIDs.removeAll()
        subscriber?.close(); publisher?.close(); subscriber = nil; publisher = nil
        await transport?.close(); transport = nil
        reader?.cancel(); reader = nil
        let audioStopped: Bool
        if let releaseSystemAudio {
            if !sharedPlayoutClosed, let systemAudio, systemAudio.playoutEpoch == startupPlayoutEpoch {
                _ = await systemAudio.shutdown()
            }
            audioStopped = await releaseSystemAudio(cameraStopped && screenStopped && sharedPlayoutClosed)
        }
        else if let systemAudio { audioStopped = await systemAudio.shutdown() }
        else { audioStopped = audio?.terminateDevice() ?? true }
        cleanupSucceeded = audioStopped && cameraStopped && screenStopped
        joined = false; rtcJoined = false
        probeLog("engine-stopped", ["client": label, "physicalAudioUsed": systemAudio != nil,
            "cameraStopped": cameraStopped, "screenStopped": screenStopped, "audioWorkerStopped": audioStopped])
        return cleanupSucceeded
    }
}

extension NativeGuestEngine {
    private func emitMeetingChange() { onMeetingChange?(meetingSnapshot) }

    /// Room participant identities, not RTC SIDs. The SFU remains subscribed to
    /// every audio track; a viewport only changes the bounded video demand.
    /// Without cameras only screen shares are subscribed or delivered.
    func setVisibleParticipantIDs(_ ids: Set<String>?, preferredScreenParticipantID: String? = nil,
                                  cameras: Bool = true) async throws {
        try checkActive()
        visibleParticipantIDs = ids; self.preferredScreenParticipantID = preferredScreenParticipantID
        receivesCameras = cameras
        onIncomingVideoChange?(incomingVideo)
        try await reconcileSubscriptions()
        onIncomingVideoChange?(incomingVideo)
    }

    private func featureRequest(_ event: String, payload: [String: Any] = [:], requestID: String? = nil) async throws -> [String: Any] {
        try checkActive()
        guard joined else { throw GuestEngineError.admissionDenied }
#if DEBUG
        if let request = featureRequestForTesting { return try await request(event, payload, requestID) }
#endif
        guard let transport else { throw GuestEngineError.disconnected }
        return try await transport.request(event: event, payload: payload, requestID: requestID)
    }

    /// The supplied ID is also the transport request ID, matching the official
    /// chat plugin's optimistic delivery/echo deduplication contract.
    @discardableResult
    func sendChatMessage(_ text: String) async throws -> String {
        try checkActive()
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard joined, meetingSnapshot.permissions.canSendChat, !text.isEmpty, text.count <= 2_000,
              text.utf8.count <= 16_384 else { throw GuestEngineError.admissionDenied }
        let id = UUID().uuidString.lowercased()
        meetingFeatures.addOutgoing(id: id, text: text); emitMeetingChange()
        do {
            _ = try await featureRequest("send-chat-message", payload: ["messageText": text], requestID: id)
            try checkActive()
            meetingFeatures.finishOutgoing(id: id, succeeded: true); emitMeetingChange()
            return id
        } catch {
            meetingFeatures.finishOutgoing(id: id, succeeded: false); emitMeetingChange()
            throw error
        }
    }

    func sendReaction(_ reaction: GuestMeetingReaction) async throws {
        try checkActive()
        guard joined, meetingSnapshot.permissions.canSendReaction else { throw GuestEngineError.admissionDenied }
#if DEBUG
        if let notify = featureNotifyForTesting { try await notify("send-reaction", ["reaction": reaction.rawValue]); return }
#endif
        guard let transport else { throw GuestEngineError.disconnected }
        try await transport.notify(event: "send-reaction", payload: ["reaction": reaction.rawValue])
        try checkActive()
    }

    func loadChatHistory() async throws { try await loadHistory(transcript: false) }
    func loadTranscriptHistory() async throws { try await loadHistory(transcript: true) }

    private func loadHistory(transcript: Bool) async throws {
        try checkActive()
        guard joined, transcript ? meetingSnapshot.permissions.canViewTranscript : meetingSnapshot.permissions.canViewChat else {
            throw GuestEngineError.admissionDenied
        }
        if transcript ? loadingTranscript : loadingChat { return }
        if transcript { loadingTranscript = true } else { loadingChat = true }
        defer { if transcript { loadingTranscript = false } else { loadingChat = false } }
        let epoch = meetingFeatures.epoch
        let page = transcript ? meetingFeatures.transcriptPage : meetingFeatures.chatPage
        var requestPayload: [String: Any] = ["limit": 25]
        if let page { requestPayload["pageKey"] = page }
        else if transcript { requestPayload["pageKey"] = NSNull() }
        let response = try await featureRequest(transcript ? "get-transcription-messages" : "get-chat-messages",
            payload: requestPayload)
        try checkActive()
        guard meetingFeatures.acceptsScope(response), let payload = response["payload"] as? [String: Any] else {
            throw GuestEngineError.malformed
        }
        try meetingFeatures.acceptHistory(payload, transcript: transcript, epoch: epoch); emitMeetingChange()
    }

    func setTranscriptionEnabled(_ enabled: Bool) async throws {
        try checkActive()
        guard joined, meetingSnapshot.permissions.canManageTranscript else { throw GuestEngineError.admissionDenied }
        let epoch = meetingFeatures.epoch
        _ = try await featureRequest(enabled ? "start-transcription" : "stop-transcription")
        try checkActive()
        guard epoch == meetingFeatures.epoch, meetingSnapshot.permissions.canManageTranscript else { return }
        meetingFeatures.setTranscriptionStatus(enabled ? .active : .stopped); emitMeetingChange()
    }

    /// Stops RTP and capture synchronously, including during registration or an
    /// outstanding control request. Call before scheduling an async stop.
    func setScreenShareIntent(_ enabled: Bool) {
        screenIntent = enabled
        if enabled { return }
        screenGeneration &+= 1
        publisher?.suppressScreenVideo()
        if let sid = published["screen"], let waiter = muteWaiters[sid], !waiter.0 {
            muteWaiters.removeValue(forKey: sid)?.1.finish(.success(()))
        }
        meetingFeatures.setScreenSharing(false); emitMeetingChange()
        if let screenCapture {
            screenCapture.cancel()
            if screenStop == nil {
                screenStop = Task { do { try await screenCapture.stop(); return true } catch { return false } }
            }
        }
    }

    private func requireScreenPermission(generation: UInt64) throws {
        try checkActive()
        guard screenIntent, generation == screenGeneration, !outputSuppressed,
              permissions["canShareScreen"] == true else { throw GuestEngineError.admissionDenied }
    }

    /// Update the source/encoder contract when a captured window changes size.
    func updateScreenShareProfile(_ profile: GuestVideoProfile) throws {
        try requireScreenPermission(generation: screenGeneration)
        guard profile.width > 0, profile.height > 0, profile.fps > 0, profile.maximumBitrate > 0 else {
            throw GuestEngineError.malformed
        }
        publisher?.updateScreenProfile(profile)
    }

    private func drainScreenStop() async throws {
        guard let screenStop else { return }
        guard await screenStop.value else { throw GuestCameraError.timedOut }
        self.screenStop = nil; screenCapture = nil
    }

    private func negotiatePublisher() async throws {
        guard let publisher else { throw GuestEngineError.disconnected }
        // The initial camera/mic offer may still be awaiting its answer.
        try await publisher.waitForStableSignaling()
        try checkActive()
        try await media(["method": "rtc:offer", "description": try await publisher.makeOffer()])
        try await publisher.didSendDescription()
        try await publisher.waitForStableSignaling()
        try checkActive()
    }

    /// A second VIDEO/SCREEN_SHARE sender shares the existing publisher. Camera
    /// and microphone tracks remain independent. The caller owns source choice.
    func startScreenShare(profile: GuestVideoProfile, codec: String = "h264",
                          captureFactory: (LKRTCVideoSource) -> any GuestCameraCapture) async throws {
        try checkActive()
        guard joined, rtcJoined, !screenStarting, screenCapture == nil, let publisher,
              published["screen"] == nil, publisher.localScreenVideoTrack == nil,
              profile.width > 0, profile.height > 0, profile.fps > 0,
              profile.maximumBitrate > 0 else { throw GuestEngineError.admissionDenied }
        screenStarting = true; screenIntent = true
        let generation = screenGeneration
        defer { screenStarting = false }
        do {
            try requireScreenPermission(generation: generation)
            let cid = UUID().uuidString.lowercased()
            let track = publisher.prepareScreenVideo(cid: cid, profile: profile)
            guard let source = publisher.screenSource else { throw GuestEngineError.malformed }
            let capture = captureFactory(source); screenCapture = capture
            let info = try await capture.start()
            try requireScreenPermission(generation: generation)
            guard info.width > 0, info.height > 0 else { throw GuestEngineError.malformed }
            let actual = GuestVideoProfile(width: info.width, height: info.height, fps: profile.fps,
                                           maximumBitrate: profile.maximumBitrate)
            publisher.updateScreenProfile(actual)
            let infoTrack = try await register(["cid": cid, "type": "VIDEO", "source": "SCREEN_SHARE", "muted": true,
                "width": actual.width, "height": actual.height, "layers": [actual.layer],
                "simulcastCodecs": [["codec": codec.lowercased(), "cid": cid]]], kind: "screen")
            probeLog("screen-codec-registration", ["requested": codec.lowercased(), "source": infoTrack["source"] as? String ?? "absent",
                "codecs": (infoTrack["codecs"] as? [[String: Any]] ?? []).compactMap { $0["mimeType"] as? String }])
            try requireScreenPermission(generation: generation)
            guard infoTrack["source"] as? String == "SCREEN_SHARE", let sid = infoTrack["sid"] as? String else {
                throw GuestEngineError.malformed
            }
            published["screen"] = sid
            try publisher.attachScreenVideo(track, codec: codec)
            try await negotiatePublisher()
            try requireScreenPermission(generation: generation)
            try await setScreenServerMuted(false, generation: generation)
            try requireScreenPermission(generation: generation)
            meetingFeatures.setScreenSharing(true); emitMeetingChange()
        } catch {
            setScreenShareIntent(false)
            try? await finishScreenShare()
            throw error
        }
    }

    /// Sender-bound production evidence; camera/audio statistics never label a share.
    func screenEncodingEvidence() async -> (codec: String, powerEfficient: Bool?, encoder: String?)? {
        guard !closing, let publisher, let track = publisher.localScreenVideoTrack,
              let sender = publisher.connection.senders.first(where: { $0.track?.trackId == track.trackId }),
              let mid = publisher.connection.transceivers.first(where: { $0.sender.senderId == sender.senderId })?.mid,
              let rows = await publisher.stats(), !closing, self.publisher === publisher,
              publisher.localScreenVideoTrack === track,
              let outbound = rows.first(where: { $0["type"] as? String == "outbound-rtp" && $0["mid"] as? String == mid &&
                  (($0["framesEncoded"] as? NSNumber)?.intValue ?? 0) > 0 }),
              let codecID = outbound["codecId"] as? String,
              let mime = rows.first(where: { $0["id"] as? String == codecID })?["mimeType"] as? String,
              mime.lowercased().hasPrefix("video/") else { return nil }
        return (String(mime.dropFirst(6)), outbound["powerEfficientEncoder"] as? Bool, outbound["encoderImplementation"] as? String)
    }

    func stopScreenShare() async throws {
        setScreenShareIntent(false)
        // The start operation owns pending registration/negotiation cleanup.
        if screenStarting { try await drainScreenStop(); return }
        try await finishScreenShare()
    }

    private func setScreenServerMuted(_ muted: Bool, generation: UInt64) async throws {
        guard let sid = published["screen"], let publisher else { return }
        if serverMute[sid] != muted {
            let completion = GuestCompletion<Void>()
            guard muteWaiters[sid] == nil else { throw GuestEngineError.malformed }
            muteWaiters[sid] = (muted, completion, localParticipantVersion)
            defer { muteWaiters.removeValue(forKey: sid) }
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    completion.install(continuation, timeout: 5)
                    Task { [weak self] in
                        do {
                            guard let self else { throw GuestEngineError.disconnected }
                            if !muted { try self.requireScreenPermission(generation: generation) }
                            try await self.media(["method": "rtc:track:muted", "mute": ["sid": sid, "muted": muted]])
                            if !muted {
                                try self.requireScreenPermission(generation: generation)
                                try publisher.setScreenMuted(false)
                            }
                        } catch { completion.finish(.failure(error)) }
                    }
                }
            }, onCancel: { completion.finish(.failure(CancellationError())) })
        }
        if !muted {
            try requireScreenPermission(generation: generation)
            try publisher.setScreenMuted(true); try publisher.setScreenMuted(false)
        }
    }

    private func finishScreenShare() async throws {
        try await drainScreenStop()
        guard let publisher else { return }
        if let sid = published["screen"] {
            // Mute is best effort after a transport failure; capture/RTP already stopped.
            if !closing, failure == nil { try? await setScreenServerMuted(true, generation: screenGeneration) }
            serverMute.removeValue(forKey: sid); published.removeValue(forKey: "screen")
        }
        if try publisher.removeScreenVideo(), !closing, failure == nil { try await negotiatePublisher() }
    }
}

#if DEBUG
extension NativeGuestEngine {
    func processEventForTesting(_ event: [String: Any]) async throws { try await receive(event) }
    func preparePublicationForTesting(cid: String, video: Bool) { publicationKinds[cid] = video ? "video" : "audio" }
    var stateForTesting: (intent: [Bool: Bool], server: [String: Bool], version: Int, suppressed: Bool) {
        (localMuteIntent, serverMute, localParticipantVersion, outputSuppressed)
    }
    func identifyForTesting(_ identity: String) { localIdentity = identity }
    func prepareSubscriberForTesting() throws -> GuestPeer {
        guard subscriber == nil else { throw GuestEngineError.malformed }
        let peer = try makePeer(.subscriber)
        let config = peer.connection.configuration
        config.iceServers = []; config.iceTransportPolicy = .none
        guard peer.connection.setConfiguration(config) else { throw GuestPeerError.malformed }
        subscriber = peer; localIdentity = "local"
        return peer
    }
    func prepareJoinForTesting(microphone: Bool = true, camera: Bool = true) throws -> GuestPeer {
        guard publisher == nil else { throw GuestEngineError.malformed }
        let peer = try GuestPeer(target: .publisher, factory: factory)
        let config = peer.connection.configuration
        config.iceServers = []; config.iceTransportPolicy = .none
        guard peer.connection.setConfiguration(config) else { throw GuestPeerError.malformed }
        publisher = peer; joined = true; rtcJoined = true; localIdentity = "local"
        permissions["canShareMicrophone"] = microphone; permissions["canShareCamera"] = camera
        return peer
    }
    func prepareVideoUnmuteForTesting(camera: Bool = false) async throws -> GuestPeer {
        guard systemAudio == nil, publisher == nil else { throw GuestEngineError.malformed }
        let peer = try GuestPeer(target: .publisher, factory: factory)
        publisher = peer
        let configuration = peer.connection.configuration
        configuration.iceServers = []
        configuration.iceTransportPolicy = .none
        guard peer.connection.setConfiguration(configuration) else { throw GuestPeerError.malformed }
        cameraPublication = camera
        let track = peer.prepareVideo(cid: "test-video-cid")
        track.isEnabled = false
        try peer.attach(track, codec: "vp8")
        _ = try await peer.makeOffer()
        try peer.setMuted(true, video: true)
        joined = true; rtcJoined = true
        localIdentity = "local"; localParticipantVersion = 1
        permissions["canShareCamera"] = true
        published["video"] = "test-video-sid"
        serverMute["test-video-sid"] = true
        localMuteIntent[true] = false
        return peer
    }
}
#endif
