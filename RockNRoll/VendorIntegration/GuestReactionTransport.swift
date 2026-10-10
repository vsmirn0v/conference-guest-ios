import ConferenceCore
import Foundation
import UIKit

/// Verified JazzNext protocol values. Legacy SDK values remain decodable.
enum GuestReactionCode: String, Codable, CaseIterable, Sendable {
    case heart = "RED_HEART", like = "THUMBS_UP", smile = "FACE_WITH_TEARS_OF_JOY"
    case applause = "PARTY_POPPER", fire = "FIRE", wave = "WAVING_HAND", handshake = "HANDSHAKE"
    case thanks = "FOLDED_HANDS", thinking = "THINKING_FACE", sad = "CRYING_FACE"
    case dislike = "THUMBS_DOWN", surprise = "FACE_SCREAMING_IN_FEAR"

    var kind: MeetingReaction {
        switch self {
        case .heart: .heart; case .like: .like; case .smile: .smile; case .applause: .applause
        case .fire: .fire; case .wave: .wave; case .handshake: .handshake; case .thanks: .thanks
        case .thinking: .thinking; case .sad: .sad; case .dislike: .dislike; case .surprise: .surprise
        }
    }
    static func received(_ value: String) -> MeetingReaction? {
        if let code = Self(rawValue: value) { return code.kind }
        switch value { case "CLAP": return .applause; case "JOY": return .smile
        case "OPEN_MOUTH": return .surprise; default: return nil }
    }
    static func sent(_ kind: MeetingReaction) -> Self {
        switch kind {
        case .heart: .heart; case .like: .like; case .smile: .smile; case .applause: .applause
        case .fire: .fire; case .wave: .wave; case .handshake: .handshake; case .thanks: .thanks
        case .thinking: .thinking; case .sad: .sad; case .dislike: .dislike; case .surprise: .surprise
        }
    }
    static let legacy: [MeetingReaction] = [.like, .dislike, .applause, .smile, .surprise]
}

enum GuestReactionWireEvent: Decodable, Sendable {
    struct Joined: Sendable {
        let requestID: String
        let participantID: String
        let sessionID: String
        let groupID: String
    }
    case join(room: String, request: String)
    case joined(room: String, Joined)
    case reaction(room: String, group: String, GuestReceivedReaction)

    private enum Keys: String, CodingKey { case event, roomId, requestId, groupId, payload }
    private enum Payload: String, CodingKey { case roomId, participant, participantGroup, participantId, reaction }
    private enum Participant: String, CodingKey { case participantId, sessionId }
    private enum Group: String, CodingKey { case groupId }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        let event = try values.decode(String.self, forKey: .event)
        let room = try Self.identifier(values.decode(String.self, forKey: .roomId))
        switch event {
        case "join":
            self = .join(room: room, request: try Self.identifier(values.decode(String.self, forKey: .requestId)))
        case "join-response":
            let payload = try values.nestedContainer(keyedBy: Payload.self, forKey: .payload)
            guard try payload.decode(String.self, forKey: .roomId) == room else { throw Invalid.event }
            let participant = try payload.nestedContainer(keyedBy: Participant.self, forKey: .participant)
            let group = try payload.nestedContainer(keyedBy: Group.self, forKey: .participantGroup)
            self = .joined(room: room, Joined(
                requestID: try Self.identifier(values.decode(String.self, forKey: .requestId)),
                participantID: try Self.identifier(participant.decode(String.self, forKey: .participantId)),
                sessionID: try Self.identifier(participant.decode(String.self, forKey: .sessionId)),
                groupID: try Self.identifier(group.decode(String.self, forKey: .groupId))))
        case "reaction":
            let payload = try values.nestedContainer(keyedBy: Payload.self, forKey: .payload)
            guard let kind = GuestReactionCode.received(try payload.decode(String.self, forKey: .reaction)) else { throw Invalid.event }
            self = .reaction(room: room,
                group: try Self.identifier(values.decode(String.self, forKey: .groupId)),
                GuestReceivedReaction(kind: kind, participantID: try Self.identifier(payload.decode(String.self, forKey: .participantId))))
        default: throw Invalid.event
        }
    }
    static func decode(_ data: Data) -> Self? {
        guard data.count <= 64 * 1024 else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    private enum Invalid: Error { case event }
    private static func identifier(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 1024 else { throw Invalid.event }
        return value
    }
}

/// A task is eligible only after its exact outgoing join and correlated response.
/// The SDK's public local-participant identity must confirm that response.
struct GuestReactionScope {
    let roomID: String
    private(set) var taskID: UUID?
    private(set) var joined: GuestReactionWireEvent.Joined?
    private var requestID: String?
    private var localParticipantID: String?
    private var retired = Set<UUID>()
    private var stopped = false
    init(roomID: String) { self.roomID = roomID }
    var hasModernProtocol: Bool { taskID != nil && !stopped }
    var ready: Bool { !stopped && joined?.participantID == localParticipantID && joined != nil }
    mutating func confirmLocalParticipant(_ id: String) { localParticipantID = id }
    mutating func accept(_ event: GuestReactionWireEvent, task: UUID, outgoing: Bool) -> GuestReceivedReaction? {
        guard !stopped, !retired.contains(task) else { return nil }
        switch event {
        case .join(let room, let request) where outgoing && room == roomID:
            if taskID != task {
                if let taskID { retired.insert(taskID) }
                taskID = task
            }
            requestID = request; joined = nil
        case .joined(let room, let context) where !outgoing && room == roomID && taskID == task && context.requestID == requestID:
            joined = context
        case .reaction(let room, let group, let reaction) where !outgoing && room == roomID && taskID == task && ready && group == joined?.groupID:
            return reaction
        default: break
        }
        return nil
    }
    mutating func retire(_ task: UUID) {
        retired.insert(task)
        if taskID == task { joined = nil }
    }
    mutating func stop() { stopped = true; taskID = nil; joined = nil; requestID = nil; localParticipantID = nil }
}

/// Invalidates queued callbacks when the connection scope ends, independent of UI visibility.
final class GuestReactionDeliveryWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UUID? = UUID()
    var token: UUID? { lock.lock(); defer { lock.unlock() }; return generation }
    func setActive(_ visible: Bool) { lock.lock(); generation = visible ? UUID() : nil; lock.unlock() }
    func accepts(_ token: UUID?) -> Bool { token != nil && token == self.token }
}

@MainActor
final class GuestReactionTransport {
    private var tap: GuestWebSocketTap?
    private var scope: GuestReactionScope
    private let valid: () -> Bool
    private let onReaction: (GuestReceivedReaction, Bool) -> Void
    private let taskIDs = NSMapTable<URLSessionWebSocketTask, NSUUID>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private weak var currentTask: URLSessionWebSocketTask?
    private let delivery = GuestReactionDeliveryWindow()
    private let presentation = GuestReactionDeliveryWindow()
    private var notifications: [NSObjectProtocol] = []
    var onStateChanged: (() -> Void)?
    var hasModernProtocol: Bool { scope.hasModernProtocol }
    var ready: Bool { scope.ready && currentTask != nil && valid() }

    init(roomID: String, valid: @escaping () -> Bool, onReaction: @escaping (GuestReceivedReaction, Bool) -> Void) {
        scope = GuestReactionScope(roomID: roomID); self.valid = valid; self.onReaction = onReaction
        let delivery = delivery, presentation = presentation
        presentation.setActive(UIApplication.shared.applicationState == .active)
        tap = GuestWebSocketTap { [weak self] task, outgoing, data in
            // Decode before crossing queues. Unrelated bodies are never retained.
            guard let event = GuestReactionWireEvent.decode(data) else { return }
            let token = delivery.token, presentationToken = presentation.token, receipt = Date()
            Task { @MainActor [weak self] in self?.observe(event, task: task, outgoing: outgoing, token: token,
                present: presentation.accepts(presentationToken), receivedAt: receipt) }
        }
        for (name, visible) in [(UIApplication.willResignActiveNotification, false), (UIApplication.didBecomeActiveNotification, true)] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in presentation.setActive(visible) })
        }
    }
    func confirmLocalParticipant(_ id: String) {
        let previous = ready
        scope.confirmLocalParticipant(id)
        if ready != previous { onStateChanged?() }
    }
    private func observe(_ event: GuestReactionWireEvent, task: URLSessionWebSocketTask, outgoing: Bool, token: UUID?, present: Bool, receivedAt: Date) {
        guard valid() else { return }
        let id: UUID
        if let existing = taskIDs.object(forKey: task) { id = existing as UUID }
        else { id = UUID(); taskIDs.setObject(id as NSUUID, forKey: task) }
        let previous = (scope.hasModernProtocol, ready)
        let reaction = scope.accept(event, task: id, outgoing: outgoing)
        if scope.taskID == id { currentTask = task }
        if previous != (scope.hasModernProtocol, ready) { onStateChanged?() }
        if let reaction, delivery.accepts(token) { onReaction(reaction.stamped(at: receivedAt), present) }
    }
    @discardableResult func send(_ kind: MeetingReaction, completion: ((Bool) -> Void)? = nil) -> Bool {
        guard ready, UIApplication.shared.applicationState != .background,
              let task = currentTask, let taskID = scope.taskID, let group = scope.joined?.groupID else { return false }
        struct Envelope: Encodable {
            struct Payload: Encodable { let reaction: GuestReactionCode }
            let event = "send-reaction"
            let roomId: String
            let groupId: String
            let requestId = UUID().uuidString
            let payload: Payload
        }
        let envelope = Envelope(roomId: scope.roomID, groupId: group, payload: .init(reaction: .sent(kind)))
        guard let data = try? JSONEncoder().encode(envelope), let text = String(data: data, encoding: .utf8) else { return false }
        task.send(.string(text)) { [weak self] error in
            Task { @MainActor [weak self] in
                completion?(error == nil)
                guard let self, self.scope.taskID == taskID, self.valid() else { return }
                if error != nil { self.scope.retire(taskID); self.onStateChanged?() }
            }
        }
        return true
    }
    func stop() {
        delivery.setActive(false); tap?.invalidate(); tap = nil; scope.stop(); currentTask = nil
        presentation.setActive(false); notifications.forEach(NotificationCenter.default.removeObserver); notifications = []
        onStateChanged?(); onStateChanged = nil
    }
    deinit { tap?.invalidate(); notifications.forEach(NotificationCenter.default.removeObserver) }
}
