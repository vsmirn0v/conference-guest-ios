import ConferenceCore
import Foundation
import LiveKitWebRTC

extension NativeDesktopExternalSession {
    func startConnection(_ attempt: UUID) async throws {
        try check(attempt)
        guard let invitation else { throw NativeDesktopRTCError.invalidResponse }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil; config.httpShouldSetCookies = false
        let session: URLSession
        if kind == .trueconf { session = URLSession(configuration: config, delegate: AdditionalRootTrust(), delegateQueue: nil) }
        else { session = URLSession(configuration: config) }
        http = session
        if kind == .telemost {
            let target = try TelemostTarget.parse(invitation.absoluteString)
            let bootstrap = try await TelemostBootstrap.load(target, name: name, session: session)
            try check(attempt); telemostBootstrap = bootstrap; localID = bootstrap.participantID; roomID = bootstrap.roomID
            subscriber = try makePeer(target: "SUBSCRIBER", ice: bootstrap.iceServers)
            publisher = try makePeer(target: "PUBLISHER", ice: bootstrap.iceServers)
            let transport = TelemostTransport(server: bootstrap.serverURL, session: session); telemost = transport
            transport.onMessage = { [weak self] kind, body in
                guard let self, epoch == attempt else { return }; try await receiveTelemost(kind, body, attempt: attempt)
            }
            transport.onFailure = { [weak self] error in guard let self, epoch == attempt else { return }; recover(error) }
            transport.start()
            try await transport.request("hello", Self.telemostHello(bootstrap, name: name, quiet: !outputIntent))
            try check(attempt); helloAccepted = true; mediaAccepted = true
            if bootstrap.chatAllowed { onTelemostChatContext?(invitation, bootstrap.roomID) }
            markConnected()
        } else {
            let target = try TrueConfTarget.parse(invitation.absoluteString); roomID = target.roomID
            let bootstrap = try await TrueConfBootstrap.load(target, name: name, session: session)
            try check(attempt)
            let transport = TrueConfTransport(server: bootstrap.socketURL, session: session); trueconf = transport
            transport.onMessage = { [weak self] body in
                guard let self, epoch == attempt else { return }; try await receiveTrueConf(body, attempt: attempt)
            }
            transport.onFailure = { [weak self] error in guard let self, epoch == attempt else { return }; recover(error) }
            transport.start()
            try await transport.send(["method": "ping"])
            try check(attempt)
            try await transport.send(["method": "loginUser", "AppID": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                "login": bootstrap.login, "credentials": bootstrap.credential, "credentialsType": 3, "chatV2Enabled": false,
                "browser": "RockNRoll Native", "appLang": "en", "appVersion": "5.1.0", "appName": "RockNRoll Native"])
            try check(attempt)
        }
        refresh()
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            guard let self, epoch == attempt, snapshot.phase != .connected else { return }
            recover(kind == .telemost ? TelemostError.timedOut : TrueConfError.timedOut)
        }
    }
    static func telemostHello(_ value: TelemostBootstrap, name: String, quiet: Bool) -> [String: Any] {
        let meta: [String: Any] = ["name": name, "role": "SPEAKER", "sendAudio": false, "sendVideo": false]
        return ["participantMeta": meta, "participantAttributes": ["name": name, "role": "SPEAKER"],
            "participantId": value.participantID, "roomId": value.roomID, "serviceName": value.serviceName,
            "credentials": value.credentials, "sendAudio": false, "sendVideo": false, "sendSharing": false,
            "disablePublisher": false, "disableSubscriber": false, "disableSubscriberAudio": quiet,
            "sdkInitializationId": UUID().uuidString,
            "sdkInfo": ["implementation": "native", "version": "1", "userAgent": "RockNRoll", "hwConcurrency": ProcessInfo.processInfo.processorCount],
            "capabilitiesOffer": ["offerAnswerMode": ["SEPARATE"], "initialSubscriberOffer": ["ON_HELLO"],
                "slotsMode": ["FROM_CONTROLLER"], "simulcastMode": ["DISABLED"], "selfVadStatus": ["FROM_SERVER"],
                "dataChannelSharing": ["TO_RTP"], "videoEncoderConfig": ["NO_CONFIG"],
                "subscriberDtlsPassiveMode": ["SUBSCRIBER_DTLS_PASSIVE_MODE_DISABLED"]]]
    }
    func receiveTelemost(_ kind: String, _ body: [String: Any], attempt: UUID) async throws {
        try check(attempt)
        switch kind {
        case "serverHello":
            if let config = body["rtcConfiguration"] as? [String: Any] { try subscriber?.configure(config); try publisher?.configure(config) }
            ready = true; scheduleMedia()
        case "subscriberSdpOffer":
            guard let subscriber, let telemost else { throw TelemostError.disconnected }
            let answer = try await subscriber.answer(body); try check(attempt)
            try await telemost.request("subscriberSdpAnswer", answer); try check(attempt)
            subscriber.localSDPSent(); scheduleSlots()
        case "publisherSdpAnswer":
            do { try await publisher?.accept(body); try check(attempt); pendingAnswer?.finish(.success(())); markConnected() }
            catch { pendingAnswer?.finish(.failure(error)); throw error }
        case "webrtcIceCandidate":
            if body["target"] as? String == "SUBSCRIBER" { try await subscriber?.addCandidate(body) }
            else if body["target"] as? String == "PUBLISHER" { try await publisher?.addCandidate(body) }
        case "updateDescription", "upsertDescription":
            if kind == "updateDescription" { descriptions.removeAll() }
            guard let values = body["description"] as? [[String: Any]], values.count <= 1000 else { throw TelemostError.invalidResponse }
            for value in values {
                guard let id = value["id"] as? String, !id.isEmpty, id.utf8.count <= 512 else { throw TelemostError.invalidResponse }
                descriptions[id] = value
            }
            guard descriptions.count <= 1000 else { throw TelemostError.invalidResponse }
            refresh()
        case "removeDescription":
            for id in body["descriptionId"] as? [String] ?? [] { descriptions.removeValue(forKey: id) }
            refresh()
        case "slotsConfig":
            if let key = body["key"] as? Int, key != 0, key < slotKey { return }
            guard let values = body["slots"] as? [[String: Any]], values.count <= 1000 else { throw TelemostError.invalidResponse }
            slots = values
            speaking = Set(values.compactMap { slot in
                guard slot["vad"] as? Bool == true else { return nil }
                let owner = (slot["participantVideoByMid"] ?? slot["participantScreenSharingByMid"] ?? slot["participant"]) as? [String: Any]
                return owner?["participantId"] as? String
            }); refresh(); scheduleSlots()
        case "vadActivity":
            if body["active"] as? Bool == true { speaking.insert(localID) } else { speaking.remove(localID) }; refresh()
        default: break
        }
    }
    func updateSlots() async throws {
        guard ready, let telemost else { return }
        let attempt = epoch
        var fields = NativeDesktopSlotDemand.request(slots: slots, visible: visibleParticipantIDs, focused: focusedParticipantID)
        let encoded = try JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)
        guard encoded != lastSlotConfiguration else { return }
        slotKey += 1
        fields["key"] = slotKey
        try await telemost.request("setSlots", fields)
        try check(attempt)
        guard self.telemost === telemost else { throw CancellationError() }
        lastSlotConfiguration = encoded
    }
    func receiveTrueConf(_ body: [String: Any], attempt: UUID) async throws {
        try check(attempt)
        guard let method = body["method"] as? String, let transport = trueconf else { throw TrueConfError.invalidResponse }
        switch method {
        case "loginResponse":
            guard body["result"] as? Int == 0 else { throw TrueConfError.rejected }
            guard let cid = body["CID"] as? String, !cid.isEmpty,
                  let id = body["trueconfId"] as? String, !id.isEmpty else { throw TrueConfError.invalidResponse }
            self.cid = cid; localID = id; transport.cid = cid; helloAccepted = true
            try await transport.send(["method": "join", "conferenceId": roomID, "Password": "", "simulcastSupported": true])
        case "conferenceStateChange":
            guard let conference = body["conference"] as? [String: Any] else { throw TrueConfError.invalidResponse }
            if conference["message"] as? String == "deleteConference" { throw TrueConfError.ended }
            guard conference["message"] as? String == "joinResponse", streamID.isEmpty,
                  let stream = conference["streamConferenceId"] as? String, !stream.isEmpty else { return }
            streamID = stream
            if let title = conference["topic"] as? String, !title.isEmpty { onTitle?(String(title.prefix(256))) }
            try await transport.send(["method": "getIceConfig", "streamConferenceId": stream])
        case "getIceConfig":
            guard publisher == nil, !streamID.isEmpty, let values = body["iceServers"] as? [[String: Any]] else { return }
            publisher = try makePeer(target: "COMPOSITE", ice: TrueConfICE.decode(values, cid: cid, stream: streamID), topology: .composite)
            try await transport.send(["method": "connectMedia", "streamConferenceId": streamID, "type": 1]); try check(attempt)
            try await transport.send(["method": "DeviceStatus", "value": 262148])
        case "connectMedia":
            guard body["result"] as? Bool == true else { throw TrueConfError.rejected }
            mediaAccepted = true; markConnected()
        case "webrtc":
            guard let type = body["type"] as? String, let publisher else { return }
            switch type {
            case "offer":
                let answer = try await publisher.answer(body); try check(attempt)
                try await sendTrueConfMedia(["type": "answer", "sdp": answer["sdp"] ?? "", "browser": "RockNRoll Native"]); try check(attempt)
                publisher.localSDPSent(); try publisher.enablePublishing(); ready = true
                try await transport.send(["method": "ManageLayout", "func": "Get"]); try check(attempt); scheduleMedia()
            case "answer":
                do { try await publisher.accept(body); try check(attempt); pendingAnswer?.finish(.success(())); markConnected() }
                catch { pendingAnswer?.finish(.failure(error)); throw error }
            case "candidate":
                var candidate = body; candidate["sdpMlineIndex"] = body["sdpMLineIndex"]
                try await publisher.addCandidate(candidate)
            case "layout": regions = try TrueConfRoster.regions(body); refresh()
            default: break
            }
        case "SendPartsList": try roster.apply(body); refresh()
        case "DeviceStatus": roster.updateDevices(body); refresh()
        case "setDeviceState":
            if body["Mute"] as? Bool == true {
                if body["Type"] as? String == "microphone" { try await setMicrophone(false) }
                if body["Type"] as? String == "camera" {
                    // Never await negotiation from the serialized event processor:
                    // its answer must be consumed by this same processor.
                    cameraIntent = false; snapshot.cameraOn = false
                    try await publisher?.setCamera(false); scheduleMedia(); publish()
                }
            }
        case "stopContentSharing":
            screenTrack = nil; try publisher?.setScreenTrack(nil); snapshot.sharing = false; scheduleMedia(); publish()
        default: break
        }
    }
    func sendTrueConfMedia(_ fields: [String: Any]) async throws {
        guard let trueconf else { throw TrueConfError.disconnected }
        try await trueconf.send(fields.merging(["method": "webrtc", "my_peer_id": localID, "conf_id": streamID]) { _, value in value })
    }
    func refresh() {
        var people: [NativeDesktopParticipant] = [], video: [NativeDesktopExternalVideo] = []
        if kind == .telemost {
            for value in descriptions.values where value["hideFromParticipantsList"] as? Bool != true {
                guard let id = value["id"] as? String, id != localID else { continue }
                let meta = value["meta"] as? [String: Any] ?? [:]
                let mic = meta["sendAudio"] as? Bool ?? value["sendAudio"] as? Bool
                let camera = meta["sendVideo"] as? Bool ?? value["sendVideo"] as? Bool
                var sharing = meta["sendSharing"] as? Bool ?? value["sendSharing"] as? Bool
                for slot in slots {
                    for (key, source) in [("participantVideoByMid", NativeDesktopVideoSource.camera), ("participantScreenSharingByMid", .screen)] {
                        guard let owner = slot[key] as? [String: Any], owner["participantId"] as? String == id,
                              let mid = owner["mid"] as? String, let track = tracks[mid], source != .camera || camera != false else { continue }
                        let key = id + "." + source.rawValue
                        if !video.contains(where: { $0.id == key }) { video.append(.init(id: key, participantID: id, source: source, track: track)) }
                        if source == .screen { sharing = true }
                    }
                }
                people.append(.init(id: id, name: String((meta["name"] as? String ?? "Participant").prefix(256)),
                    microphoneOn: mic, cameraOn: camera, sharing: sharing, speaking: speaking.contains(id) ? true : nil))
            }
        } else {
            let track = tracks.sorted(by: { $0.key < $1.key }).first?.value
            for person in roster.participants.values where person.id != localID {
                people.append(.init(id: person.id, name: person.name, microphoneOn: person.microphoneOn,
                    cameraOn: person.cameraOn, sharing: person.screenShareOn, speaking: nil))
                if let track, let crop = regions[person.id], person.cameraOn || person.screenShareOn {
                    let source: NativeDesktopVideoSource = person.screenShareOn ? .screen : .camera
                    video.append(.init(id: person.id + "." + source.rawValue, participantID: person.id, source: source, track: track, crop: crop))
                }
            }
        }
        people.sort { $0.id < $1.id }
        people.insert(.init(id: localID.isEmpty ? "local" : localID, name: name, isLocal: true,
            microphoneOn: snapshot.microphoneOn, cameraOn: snapshot.cameraOn, sharing: snapshot.sharing,
            speaking: kind == .telemost && speaking.contains(localID) ? true : nil), at: 0)
        if kind == .telemost {
            for track in tracks.values {
                let owners = video.filter { $0.track.isEqual(track) }.map(\.participantID)
                track.isEnabled = visibleParticipantIDs.map { allowed in owners.contains(where: allowed.contains) } ?? true
            }
        } else {
            // TrueConf sends one composite. Local demand can stop its renderer,
            // but cannot pretend to unsubscribe one person's pixels on the wire.
            for track in tracks.values { track.isEnabled = visibleParticipantIDs?.isEmpty != true }
        }
        snapshot.participants = people; incomingVideo = video.sorted { $0.id < $1.id }
        onVideo?(incomingVideo); publish()
    }
}

/// Only fields verified in the delivered Telemost client are emitted. Slot
/// indices stay stable across gallery reorder; a focused share preserves detail.
enum NativeDesktopSlotDemand {
    static func request(slots: [[String: Any]], visible: Set<String>?, focused: String?) -> [String: Any] {
        let count = max(8, min(49, slots.count))
        let sizes = (0..<count).map { index -> [String: Int] in
            let slot = slots.indices.contains(index) ? slots[index] : [:]
            let share = slot["participantScreenSharingByMid"] as? [String: Any]
            let camera = slot["participantVideoByMid"] as? [String: Any]
            let owner = (share ?? camera)?["participantId"] as? String
            if let focused, owner == focused, share != nil { return ["width": 3840, "height": 2160] }
            if let owner, visible?.contains(owner) == false { return ["width": 160, "height": 90] }
            return ["width": 1280, "height": 720]
        }
        return ["audioSlotsCount": 0, "slots": sizes, "gridConfig": [:],
            "withSelfView": false, "shutdownAllVideo": visible?.isEmpty == true]
    }
}
