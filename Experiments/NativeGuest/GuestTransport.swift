import Foundation

public enum GuestTransportError: Error, LocalizedError {
    case invalidURL, notConnected, alreadyConnecting, closed, timedOut
    case invalidEnvelope, queueOverflow, frameTooLarge, networkFailure
    case server(code: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid secure WebSocket URL."
        case .notConnected: return "Guest signaling is not connected."
        case .alreadyConnecting: return "Guest signaling is already connecting."
        case .closed: return "Guest signaling is closed."
        case .timedOut: return "Guest signaling request timed out."
        case .invalidEnvelope: return "Guest signaling received an invalid envelope."
        case .queueOverflow: return "Guest signaling queue capacity exceeded."
        case .frameTooLarge: return "Guest signaling frame capacity exceeded."
        case .networkFailure: return "Guest signaling network operation failed."
        case .server(let code): return "Guest signaling server error: \(code)."
        }
    }
}

private final class GuestSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let opened: () -> Void
    let ended: () -> Void
    init(opened: @escaping () -> Void, ended: @escaping () -> Void) {
        self.opened = opened; self.ended = ended
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) { opened() }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { ended() }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) { ended() }
}

/// One reader and writer preserve wire order. A stream exists before connect,
/// retaining early `joined` and `media-out` envelopes until its single consumer starts.
/// Overflow closes the transport and fails pending operations; it never continues
/// after silently losing a signaling event. No payloads, URLs, or SDP are logged.
public actor GuestTransport {
    public nonisolated let events: AsyncStream<[String: Any]>
    public private(set) var terminalError: GuestTransportError?
    private let eventContinuation: AsyncStream<[String: Any]>.Continuation
    private let url: URL
    private let origin: URL?
    private let capacity: Int
    private let maximumFrameBytes: Int
    private var roomID: String
    private var groupID: String?
    private enum State { case idle, connecting, open, closing, closed }
    private var state = State.idle
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var sendTimeout: Task<Void, Never>?
    private var activeFrameID: String?
    private var connectTimeout: Task<Void, Never>?
    private var closeTimeout: Task<Void, Never>?
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private struct Pending {
        let event: String
        let continuation: CheckedContinuation<[String: Any], Error>
        let timeout: Task<Void, Never>
    }
    private struct Frame { let id: String; let text: String }
    private struct Notification {
        let continuation: CheckedContinuation<Void, Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [String: Pending] = [:]
    private var notifications: [String: Notification] = [:]
    private var outgoing: [Frame] = []

    public init(url: URL, roomID: String, origin: URL? = nil,
                queueCapacity: Int = 256, maximumFrameBytes: Int = 4_194_304) {
        self.url = url; self.roomID = roomID; self.origin = origin
        self.capacity = max(1, queueCapacity)
        self.maximumFrameBytes = max(1, maximumFrameBytes)
        var continuation: AsyncStream<[String: Any]>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingOldest(max(1, queueCapacity))) { continuation = $0 }
        self.eventContinuation = continuation
    }

    public func connect(timeout: TimeInterval = 15) async throws {
        if state == .open { return }
        guard state != .closed else { throw terminalError ?? .closed }
        guard state == .idle else { throw GuestTransportError.alreadyConnecting }
        guard url.scheme?.lowercased() == "wss", url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.fragment == nil else { throw GuestTransportError.invalidURL }
        guard timeout.isFinite, timeout > 0, timeout <= 300 else { throw GuestTransportError.timedOut }
        try Task.checkCancellation()
        state = .connecting
        let delegate = GuestSocketDelegate(opened: { [weak self] in
            Task { await self?.didOpen() }
        }, ended: { [weak self] in
            Task { await self?.socketEnded() }
        })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: url)
        if let origin { request.setValue(origin.absoluteString, forHTTPHeaderField: "Origin") }
        let task = session!.webSocketTask(with: request)
        task.maximumMessageSize = maximumFrameBytes
        socket = task
        eventContinuation.onTermination = { [weak self] _ in Task { await self?.close() } }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                connectWaiter = continuation
                connectTimeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                    catch { return }
                    await self?.fail(.timedOut)
                }
                task.resume()
            }
        }, onCancel: { [weak self] in Task { await self?.close() } })
    }

    public func setScope(roomID: String, groupID: String?) {
        self.roomID = roomID; self.groupID = groupID
    }

    /// SDK correlation requires BOTH requestId and event-name-response (or error).
    /// The returned dictionary is the full response envelope.
    public func request(event: String, payload: [String: Any] = [:],
                        timeout: TimeInterval = 15, requestID: String? = nil) async throws -> [String: Any] {
        try checkCapacity()
        guard timeout.isFinite, timeout > 0, timeout <= 300 else { throw GuestTransportError.timedOut }
        try Task.checkCancellation()
        let id = requestID ?? UUID().uuidString.lowercased()
        guard !id.isEmpty, id.utf8.count <= 1_024, pending[id] == nil, notifications[id] == nil else {
            throw GuestTransportError.invalidEnvelope
        }
        let frame = try makeFrame(id: id, event: event, payload: payload)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                    catch { return }
                    await self?.expire(id)
                }
                pending[id] = Pending(event: event, continuation: continuation, timeout: timer)
                outgoing.append(frame)
                startWriter()
            }
        }, onCancel: { [weak self] in Task { await self?.cancel(id) } })
    }

    public func request(_ event: String, payload: [String: Any] = [:],
                        timeout: TimeInterval = 15) async throws -> [String: Any] {
        try await request(event: event, payload: payload, timeout: timeout)
    }

    public func notify(event: String, payload: [String: Any] = [:],
                       timeout: TimeInterval = 15) async throws {
        try checkCapacity()
        guard timeout.isFinite, timeout > 0, timeout <= 300 else { throw GuestTransportError.timedOut }
        try Task.checkCancellation()
        let id = UUID().uuidString.lowercased()
        let frame = try makeFrame(id: id, event: event, payload: payload)
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                    catch { return }
                    await self?.notificationExpired(id)
                }
                notifications[id] = Notification(continuation: continuation, timeout: timer)
                outgoing.append(frame)
                startWriter()
            }
        }, onCancel: { [weak self] in Task { await self?.cancel(id) } })
    }

    public func notify(_ event: String, payload: [String: Any] = [:],
                       timeout: TimeInterval = 15) async throws {
        try await notify(event: event, payload: payload, timeout: timeout)
    }

    public nonisolated static func isResponse(_ envelope: [String: Any],
                                              requestID: String, event: String) -> Bool {
        envelope["requestId"] as? String == requestID &&
            (envelope["event"] as? String == "\(event)-response" || envelope["event"] as? String == "error")
    }

    /// Send the WebSocket close frame, then allow the peer at most two seconds
    /// to complete the handshake before canceling the underlying URLSession.
    public func close() async {
        if state == .closed { return }
        guard state == .open || state == .closing else { finish(error: nil); return }
        await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
            guard state != .closing else { return }
            state = .closing
            closeTimeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
                await self?.finish(error: nil)
            }
            socket?.cancel(with: .goingAway, reason: nil)
        }
    }

#if DEBUG
    // Deterministic close-handshake tests never create a URLSession or socket.
    func openWithoutSocketForTesting() {
        precondition(state == .idle && socket == nil && session == nil)
        state = .open
    }
    var isClosingForTesting: Bool { state == .closing }
    func finishCloseForTesting() {
        precondition(state == .closing && socket == nil && session == nil)
        socketEnded()
    }
#endif

    private func checkCapacity() throws {
        // Sends racing the close handshake belong to the terminated connection,
        // just like pending sends completed by finish(). Reporting notConnected
        // here turns an expected socket interruption into a terminal session error.
        guard state == .open else {
            throw terminalError ?? (state == .closing || state == .closed ? .closed : .notConnected)
        }
        guard pending.count + notifications.count < capacity, outgoing.count < capacity else {
            throw GuestTransportError.queueOverflow
        }
    }

    private func makeFrame(id: String, event: String, payload: [String: Any]) throws -> Frame {
        guard !event.isEmpty, JSONSerialization.isValidJSONObject(payload) else { throw GuestTransportError.invalidEnvelope }
        var envelope: [String: Any] = ["event": event, "payload": payload, "requestId": id, "roomId": roomID]
        if let groupID { envelope["groupId"] = groupID }
        let data = try JSONSerialization.data(withJSONObject: envelope)
        guard data.count <= maximumFrameBytes else { throw GuestTransportError.frameTooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw GuestTransportError.invalidEnvelope }
        return Frame(id: id, text: text)
    }

    private func didOpen() {
        guard state == .connecting else { return }
        state = .open
        connectTimeout?.cancel(); connectTimeout = nil
        connectWaiter?.resume(); connectWaiter = nil
        reader = Task { [weak self] in await self?.readLoop() }
    }

    private func startWriter() {
        guard writer == nil else { return }
        writer = Task { [weak self] in await self?.writeLoop() }
    }

    private func writeLoop() async {
        while state == .open, !Task.isCancelled, let socket, !outgoing.isEmpty {
            let frame = outgoing.removeFirst()
            activeFrameID = frame.id
            // URLSession's WebSocket send has no independent completion deadline.
            // Bound even requests whose response timer expires during a stalled send.
            sendTimeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 15_000_000_000) }
                catch { return }
                await self?.sendExpired(frame.id)
            }
            do { try await socket.send(.string(frame.text)) }
            catch { fail(.networkFailure); return }
            sendTimeout?.cancel(); sendTimeout = nil; activeFrameID = nil
            if let notification = notifications.removeValue(forKey: frame.id) {
                notification.timeout.cancel()
                notification.continuation.resume()
            }
        }
        writer = nil
    }

    private func readLoop() async {
        while state == .open, !Task.isCancelled, let socket {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: throw GuestTransportError.invalidEnvelope
                }
                guard data.count <= maximumFrameBytes else { throw GuestTransportError.frameTooLarge }
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let event = object["event"] as? String, !event.isEmpty else {
                    throw GuestTransportError.invalidEnvelope
                }
                accept(object)
            } catch let error as GuestTransportError { fail(error); return }
            catch { fail(.networkFailure); return }
        }
    }

    private func accept(_ envelope: [String: Any]) {
        guard state == .open else { return }
        if let id = envelope["requestId"] as? String, let request = pending[id],
           Self.isResponse(envelope, requestID: id, event: request.event) {
            pending.removeValue(forKey: id)
            request.timeout.cancel()
            if envelope["event"] as? String == "error" {
                let payload = envelope["payload"] as? [String: Any]
                // Do not propagate arbitrary server messages, parameters, or secret payloads.
                let raw = payload?["code"] as? String ?? "UNKNOWN"
                let code = String(raw.prefix(128)).filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
                request.continuation.resume(throwing: GuestTransportError.server(code: code))
            } else { request.continuation.resume(returning: envelope) }
        }
        switch eventContinuation.yield(envelope) {
        case .dropped: fail(.queueOverflow)
        case .terminated: Task { await self.close() }
        case .enqueued: break
        @unknown default: fail(.queueOverflow)
        }
    }

    private func expire(_ id: String) {
        if let request = pending.removeValue(forKey: id) {
            request.continuation.resume(throwing: GuestTransportError.timedOut)
        }
        outgoing.removeAll { $0.id == id }
    }

    private func cancel(_ id: String) {
        if let request = pending.removeValue(forKey: id) {
            request.timeout.cancel()
            request.continuation.resume(throwing: CancellationError())
        }
        if let notification = notifications.removeValue(forKey: id) {
            notification.timeout.cancel()
            notification.continuation.resume(throwing: CancellationError())
        }
        outgoing.removeAll { $0.id == id }
    }

    private func sendExpired(_ id: String) {
        if activeFrameID == id { fail(.timedOut) }
    }

    private func notificationExpired(_ id: String) {
        if notifications[id] != nil { fail(.timedOut) }
    }

    private func socketEnded() {
        if state == .closing { finish(error: nil) }
        else { fail(.networkFailure) }
    }

    private func fail(_ error: GuestTransportError) {
        // Canceled receives/sends are expected while the close handshake runs.
        guard state != .closing else { return }
        finish(error: error)
    }

    private func finish(error: GuestTransportError?) {
        guard state != .closed else { return }
        let wasClosing = state == .closing
        state = .closed
        terminalError = error
        connectTimeout?.cancel(); connectTimeout = nil
        closeTimeout?.cancel(); closeTimeout = nil
        reader?.cancel(); reader = nil
        writer?.cancel(); writer = nil
        sendTimeout?.cancel(); sendTimeout = nil; activeFrameID = nil
        if !wasClosing { socket?.cancel(with: .goingAway, reason: nil) }
        socket = nil
        session?.invalidateAndCancel(); session = nil
        connectWaiter?.resume(throwing: error ?? .closed); connectWaiter = nil
        for request in pending.values {
            request.timeout.cancel()
            request.continuation.resume(throwing: error ?? .closed)
        }
        pending.removeAll()
        for notification in notifications.values {
            notification.timeout.cancel()
            notification.continuation.resume(throwing: error ?? .closed)
        }
        notifications.removeAll(); outgoing.removeAll()
        eventContinuation.finish()
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
