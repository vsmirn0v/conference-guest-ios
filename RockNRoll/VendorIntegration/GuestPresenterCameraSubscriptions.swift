import Foundation

/// Exact qualified receive scope. Consumers must revalidate this value after
/// hopping queues; callbacks can race a newer lease or revocation.
struct GuestPresenterCameraLease: Equatable, Sendable {
    let generation: UUID
    let socketID: UUID
    let participantID: String
    let cameraSID: String
    let token: UUID
}

/// Semantic foreground demand, independent of whether the SDK has a renderer yet.
struct GuestPresenterCameraDemand {
    var participant: String?
    var cameraOn: Bool
    var sharing: Bool
    var allVideo: Bool
    var mounted: Bool
    var foreground: Bool
    var held: Bool
    var collapsed: Bool
    var cameraFocused: Bool
    var identity: String? {
        guard cameraOn, sharing, Self.allowsVideo(allVideo: allVideo, mounted: mounted, foreground: foreground, held: held),
              !collapsed || cameraFocused else { return nil }
        return participant
    }
    static func allowsVideo(allVideo: Bool, mounted: Bool, foreground: Bool, held: Bool) -> Bool {
        allVideo && mounted && foreground && !held
    }
    static func galleryOwner(visibleCameras: [String], sharing: Set<String>, preferred: String?) -> String? {
        if let preferred, sharing.contains(preferred), visibleCameras.contains(preferred) { return preferred }
        return visibleCameras.first { sharing.contains($0) }
    }
    static func stageOwner(participant: String?, isShare: Bool, sharing: Set<String>) -> String? {
        guard let participant, isShare || sharing.contains(participant) else { return nil }
        return participant
    }
}

/// Acquires one visible Presenter camera while sharing, then preserves the same
/// visible camera through share end. Other tracks/settings pass through.
/// The bridge serializes rewrite+forward with sends.
final class GuestPresenterCameraSubscriptions: @unchecked Sendable {
    typealias Send = (UUID, Data, @escaping () -> Bool) -> Void
    private struct Owner {
        let identity: String
        let version: Int
        let camera: String?
        let sharing: Bool
    }
    private struct Lease: Equatable {
        let generation: UUID; let socket: UUID; let participant: String; let track: String; let token: UUID
        var snapshot: GuestPresenterCameraLease {
            .init(generation: generation, socketID: socket, participantID: participant, cameraSID: track, token: token)
        }
    }
    private struct Command { let lease: Lease; let room: String; let group: String?; let subscribed: Bool }
    // Mutation and enqueueing its complete batch share one order. Send/unbind
    // only enqueue; validators may synchronously read state, never this lock.
    private let operation = NSLock()
    private let lock = NSLock()
    private let bind: (UUID) -> Bool
    private let unbind: (UUID) -> Void
    private let send: Send
    private var generation: UUID?
    private var room: String?
    private var socket: UUID?
    private var group: String?
    private var routingKnown = false
    private var retired: [UUID] = []
    private var localIdentity: String?
    private var owners: [String: Owner] = [:]
    private var retiredOwners = Set<String>()
    private var sdkIntent: [String: Bool] = [:]
    private var candidates: [String] = []
    private var retained: Lease?
    private var scopeComplete = true
    private var leaseHandler: ((GuestPresenterCameraLease?) -> Void)?
    private var answerHandler: ((GuestPresenterCameraLease) -> Void)?
    var currentLease: GuestPresenterCameraLease? {
        lock.lock(); defer { lock.unlock() }; return retained?.snapshot
    }
    /// Both handlers run without either policy lock. Revalidate currentLease
    /// before applying an event; a concurrent operation may already supersede it.
    var onLeaseChange: ((GuestPresenterCameraLease?) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return leaseHandler }
        set { lock.lock(); leaseHandler = newValue; lock.unlock() }
    }
    var onSubscriberAnswer: ((GuestPresenterCameraLease) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return answerHandler }
        set { lock.lock(); answerHandler = newValue; lock.unlock() }
    }
    #if DEBUG
    private var lastTrace: String?
    private var traceCount = 0
    var retainedCameraSIDForTesting: String? {
        lock.lock(); defer { lock.unlock() }; return retained?.track
    }
    #endif

    init(bind: @escaping (UUID) -> Bool = { _ in true }, unbind: @escaping (UUID) -> Void = { _ in },
         send: @escaping Send) {
        self.bind = bind; self.unbind = unbind; self.send = send
    }

    func begin(generation: UUID, room: String) {
        operation.lock(); let previous = currentLease
        defer { finishOperation(previous: previous) }
        lock.lock()
        let previousSocket = socket
        let commands = release()
        retireSocket()
        self.generation = generation; self.room = room; candidates = []
        lock.unlock(); dispatch(commands)
        if let previousSocket { unbind(previousSocket) }
    }
    func end(generation: UUID) {
        operation.lock(); let previous = currentLease
        defer { finishOperation(previous: previous) }
        lock.lock()
        guard self.generation == generation else { lock.unlock(); return }
        let previousSocket = socket
        let commands = release()
        retireSocket(); self.generation = nil; room = nil; candidates = []
        lock.unlock(); dispatch(commands)
        if let previousSocket { unbind(previousSocket) }
    }
    func setDemand(_ identity: String?, generation: UUID) {
        setVisibleCandidates(identity.map { [$0] } ?? [], generation: generation)
    }
    func setVisibleCandidates(_ identities: [String], generation: UUID) {
        operation.lock(); let previous = currentLease
        defer { finishOperation(previous: previous) }
        lock.lock()
        guard self.generation == generation, scopeComplete else { lock.unlock(); return }
        var seen = Set<String>()
        let next = identities.prefix(64).compactMap(Self.identifier).filter { seen.insert($0).inserted }
        guard candidates != next else { lock.unlock(); return }
        candidates = next
        let commands = reconcile()
        trace("demand")
        lock.unlock(); dispatch(commands)
    }

    func incoming(socket: UUID, data: Data) {
        guard let envelope = Self.envelope(data), envelope["event"] as? String == "media-out",
              let payload = envelope["payload"] as? [String: Any] else { return }
        operation.lock(); let previous = currentLease
        defer { finishOperation(previous: previous) }
        lock.lock()
        guard generation != nil, self.socket == socket,
              envelope["roomId"] == nil || envelope["roomId"] as? String == room else { lock.unlock(); return }
        let incomingGroup = Self.identifier(envelope["groupId"])
        guard envelope["groupId"] == nil || incomingGroup != nil,
              !routingKnown || envelope["groupId"] == nil || incomingGroup == group else { lock.unlock(); return }
        if !routingKnown, let incomingGroup { group = incomingGroup }
        let join = payload["join"] as? [String: Any]
        if let local = (join?["participant"] as? [String: Any])?["identity"] as? String { localIdentity = Self.identifier(local) }
        let values = join?["otherParticipants"] as? [[String: Any]] ??
            (payload["update"] as? [String: Any])?["participants"] as? [[String: Any]] ?? []
        if values.count <= 128 {
            for value in values {
                let version = value["version"] == nil ? 0 : value["version"] as? Int
                guard let sid = Self.identifier(value["sid"]), let identity = Self.identifier(value["identity"]),
                      let version, version >= 0,
                      !retiredOwners.contains(sid), version > (owners[sid]?.version ?? -1) else { continue }
                guard owners[sid] != nil || owners.count < 128 else { owners.removeAll(); scopeComplete = false; break }
                var cameras: [String] = [], sharing = false
                let tracks = value["tracks"] as? [[String: Any]] ?? []
                if identity != localIdentity, value["state"] as? String != "DISCONNECTED", tracks.count <= 32 {
                    for track in tracks where track["type"] as? String == "VIDEO" && track["muted"] as? Bool == false {
                        if track["source"] as? String == "CAMERA", let id = Self.identifier(track["sid"]) { cameras.append(id) }
                        if track["source"] as? String == "SCREEN_SHARE" { sharing = true }
                    }
                }
                // A replacement SID owns the current snapshot of this identity.
                for old in owners.keys.filter({ $0 != sid && owners[$0]?.identity == identity }) {
                    retiredOwners.insert(old)
                    if let previous = owners[old] { owners[old] = Owner(identity: "", version: previous.version, camera: nil, sharing: false) }
                }
                owners[sid] = Owner(identity: identity, version: version, camera: cameras.count == 1 ? cameras[0] : nil, sharing: sharing)
            }
        } else { owners.removeAll(); scopeComplete = false }
        let commands = reconcile()
        trace("incoming")
        lock.unlock(); dispatch(commands)
    }

    func outgoing(socket: UUID, data: Data) -> Data? {
        guard var envelope = Self.envelope(data), var payload = envelope["payload"] as? [String: Any] else { return nil }
        operation.lock(); let previous = currentLease
        var answer: GuestPresenterCameraLease?
        defer { finishOperation(previous: previous, answer: answer) }
        lock.lock()
        guard generation != nil, envelope["roomId"] as? String == room else { lock.unlock(); return nil }
        var commands: [Command] = []
        var previousSocket: UUID?
        defer {
            lock.unlock()
            dispatch(commands)
            if let previousSocket { unbind(previousSocket) }
        }
        if envelope["event"] as? String == "join", payload["jazzToken"] is String, payload["participantName"] is String,
           self.socket != socket, !retired.contains(socket) {
            let bound = bind(socket)
            commands += release(); previousSocket = self.socket; retireSocket()
            if bound { self.socket = socket }
        }
        if self.socket == socket, envelope["event"] as? String == "media-in" {
            let nextGroup = envelope["groupId"] == nil ? group : Self.identifier(envelope["groupId"])
            guard envelope["groupId"] == nil || nextGroup != nil else { return nil }
            if routingKnown, group != nextGroup {
                commands += release(); owners.removeAll(); retiredOwners.removeAll(); sdkIntent.removeAll()
            }
            group = nextGroup; routingKnown = true
            commands += reconcile()
            if payload["method"] as? String == "rtc:answer",
               let description = payload["description"] as? [String: Any],
               description["type"] as? String == "answer",
               let sdp = description["sdp"] as? String, !sdp.isEmpty, sdp.utf8.count <= 1_000_000 {
                // SDK receivers exist once its local answer has been installed.
                answer = retained?.snapshot
            }
        }
        trace("outgoing")
        guard self.socket == socket, envelope["event"] as? String == "media-in",
              var subscription = payload["subscription"] as? [String: Any],
              let subscribed = subscription["subscribe"] as? Bool,
              let ids = subscription["trackSids"] as? [String], !ids.isEmpty, ids.count <= 128,
              ids.allSatisfy({ Self.identifier($0) != nil }) else {
            return nil
        }
        if let track = retained?.track, ids.contains(track) {
            if sdkIntent[track] == nil, sdkIntent.count >= 128, let victim = sdkIntent.keys.first(where: { $0 != track }) {
                sdkIntent.removeValue(forKey: victim)
            }
            sdkIntent[track] = subscribed
        }
        for id in ids {
            if sdkIntent[id] == nil, sdkIntent.count >= 128 {
                // Losing SDK intent would make later restoration ambiguous.
                commands += release(); candidates = []; scopeComplete = false
                break
            }
            sdkIntent[id] = subscribed
        }
        var changed = false
        if !subscribed, let retained, retained.socket == socket, ids.contains(retained.track) {
            let remaining = ids.filter { $0 != retained.track }
            if remaining.isEmpty { subscription["subscribe"] = true }
            else { subscription["trackSids"] = remaining }
            payload["subscription"] = subscription; envelope["payload"] = payload; changed = true
        }
        return changed ? try? JSONSerialization.data(withJSONObject: envelope) : nil
    }

    private func reconcile() -> [Command] {
        guard scopeComplete, routingKnown else { return release() }
        let visible = candidates.compactMap { identity -> Owner? in
            let matches = owners.values.filter { $0.identity == identity && $0.camera != nil }
            return matches.count == 1 ? matches[0] : nil
        }
        let presenting = visible.filter(\.sharing)
        // Acquisition requires a live share. Keep that camera while it remains
        // visible after share end: an unsubscribe here races the SDK's layout
        // update and can strand its renderer on a retired MID. A new visible
        // presenter takes priority over this continuity lease, with one lease total.
        let owner = presenting.first(where: { $0.camera == retained?.track }) ??
            presenting.first ?? visible.first(where: { $0.camera == retained?.track })
        if retained?.socket == socket, retained?.track == owner?.camera, retained?.participant == owner?.identity { return [] }
        var commands = release()
        if let socket, let owner, let track = owner.camera, let room, let generation {
            let lease = Lease(generation: generation, socket: socket, participant: owner.identity, track: track, token: UUID())
            retained = lease; commands.append(Command(lease: lease, room: room, group: group, subscribed: true))
        }
        return commands
    }
    private func release() -> [Command] {
        guard let lease = retained, let room else { retained = nil; return [] }
        retained = nil
        return sdkIntent[lease.track] == true ? [] : [Command(lease: lease, room: room, group: group, subscribed: false)]
    }
    private func retireSocket() {
        if let socket { retired.append(socket); if retired.count > 128 { retired.removeFirst() } }
        socket = nil; group = nil; routingKnown = false; localIdentity = nil
        owners.removeAll(); retiredOwners.removeAll(); sdkIntent.removeAll(); scopeComplete = true
    }
    private func permits(_ command: Command) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if command.subscribed { return retained == command.lease && generation != nil }
        // Old socket cleanup remains valid after a new session starts. A camera
        // reclaimed on the same socket, or wanted by the SDK, must not be stopped.
        if retained?.socket == command.lease.socket && retained?.track == command.lease.track { return false }
        return socket != command.lease.socket || sdkIntent[command.lease.track] != true
    }
    private func dispatch(_ commands: [Command]) {
        for command in commands {
            var envelope: [String: Any] = ["event": "media-in", "roomId": command.room, "requestId": UUID().uuidString, "payload": [
                "method": "rtc:track:subscription:change", "subscription": ["trackSids": [command.lease.track], "subscribe": command.subscribed]]]
            if let group = command.group { envelope["groupId"] = group }
            guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { continue }
            send(command.lease.socket, data) { [weak self] in self?.permits(command) == true }
        }
    }
    private func finishOperation(previous: GuestPresenterCameraLease?, answer: GuestPresenterCameraLease? = nil) {
        lock.lock()
        let current = retained?.snapshot
        let changed = current != previous ? leaseHandler : nil
        let answered = answer != nil && answer == current ? answerHandler : nil
        lock.unlock()
        operation.unlock()
        changed?(current)
        if let answer { answered?(answer) }
    }
    private func trace(_ event: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_NATIVE_SHARE_TRACE"] == "1", traceCount < 64 else { return }
        let eligible = owners.values.filter { candidates.contains($0.identity) && $0.camera != nil && $0.sharing }.count
        let state = "generation=\(generation != nil) socket=\(socket != nil) routing=\(routingKnown) group=\(group != nil) owners=\(owners.count) candidates=\(candidates.count) eligible=\(eligible) retained=\(retained != nil) complete=\(scopeComplete)"
        if state != lastTrace { lastTrace = state; traceCount += 1; print("LEGACY_POLICY_STATE event=\(event) \(state)") }
        #endif
    }
    private static func envelope(_ data: Data) -> [String: Any]? {
        guard data.count <= 1_048_576 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 1024 else { return nil }
        return value
    }
}
