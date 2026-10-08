import Foundation

/// The reader resolves acknowledgments independently of serialized SDP/event handling.
/// An event handler can therefore await a request without blocking the socket reader.
@MainActor
final class TelemostTransport {
    var onMessage: ((String, [String: Any]) async throws -> Void)?
    var onFailure: ((Error) -> Void)?
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private let events: AsyncStream<(String, [String: Any], String)>
    private let continuation: AsyncStream<(String, [String: Any], String)>.Continuation
    private var reader: Task<Void, Never>?
    private var processor: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var closed = false
    private struct Pending { let completion: CheckedContinuation<Void, Error>; let timeout: Task<Void, Never> }
    private var pending: [String: Pending] = [:]

    init(server: URL, session: URLSession) {
        self.session = session; socket = session.webSocketTask(with: server)
        socket.maximumMessageSize = 2_000_000
        var pipe: AsyncStream<(String, [String: Any], String)>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(128)) { pipe = $0 }
        continuation = pipe
    }
    func start() {
        socket.resume()
        reader = Task { [weak self] in await self?.read() }
        processor = Task { [weak self, events] in
            for await (kind, body, uid) in events {
                guard let self, !self.closed else { break }
                do {
                    // Goloom gates the remaining messages on serverHello's acknowledgment.
                    if kind == "serverHello" { try await self.acknowledge(uid) }
                    try await self.onMessage?(kind, body)
                    if kind != "serverHello" { try await self.acknowledge(uid) }
                } catch { self.fail(error); break }
            }
        }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5)); try Task.checkCancellation()
                    try await self?.request("ping", [:])
                } catch { if !Task.isCancelled { self?.fail(error) }; break }
            }
        }
    }
    func request(_ kind: String, _ body: [String: Any]) async throws {
        guard !closed, pending.count < 64 else { throw TelemostError.disconnected }
        let uid = UUID().uuidString
        try await withCheckedThrowingContinuation { completion in
            let timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                self?.complete(uid, error: TelemostError.timedOut)
            }
            pending[uid] = Pending(completion: completion, timeout: timeout)
            Task { [weak self] in
                do { try await self?.send(kind, body, uid: uid) }
                catch { self?.complete(uid, error: error) }
            }
        }
    }
    private func send(_ kind: String, _ body: [String: Any], uid: String) async throws {
        guard !closed else { throw TelemostError.disconnected }
        let data = try JSONSerialization.data(withJSONObject: ["uid": uid, kind: body])
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    private func acknowledge(_ uid: String) async throws { try await send("ack", ["status": ["code": "OK"]], uid: uid) }
    private func complete(_ uid: String, error: Error? = nil) {
        guard let value = pending.removeValue(forKey: uid) else { return }
        value.timeout.cancel()
        if let error { value.completion.resume(throwing: error) } else { value.completion.resume() }
    }
    private func read() async {
        while !closed && !Task.isCancelled {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                guard data.count <= 2_000_000, let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let uid = envelope["uid"] as? String, !uid.isEmpty else { throw TelemostError.invalidResponse }
                for kind in envelope.keys.sorted() where kind != "uid" {
                    guard let body = envelope[kind] as? [String: Any] else { throw TelemostError.invalidResponse }
                    if kind == "ack" {
                        let code = (body["status"] as? [String: Any])?["code"] as? String ?? "OK"
                        complete(uid, error: code == "OK" ? nil : TelemostError.rejected(code))
                    } else if case .dropped = continuation.yield((kind, body, uid)) { throw TelemostError.invalidResponse }
                }
            } catch {
                if !closed && !Task.isCancelled { fail(TelemostError.socketFailure(code: socket.closeCode.rawValue, underlying: error)) }
                break
            }
        }
    }
    private func fail(_ error: Error) {
        guard !closed else { return }
        let handler = onFailure; onFailure = nil
        handler?(error)
    }
    #if DEBUG
    func interruptForTesting() { socket.cancel(with: .goingAway, reason: nil) }
    #endif
    func close() async {
        guard !closed else { return }
        closed = true; onFailure = nil; onMessage = nil
        processor?.cancel(); heartbeat?.cancel(); continuation.finish()
        for uid in Array(pending.keys) { complete(uid, error: CancellationError()) }
        socket.cancel(with: .normalClosure, reason: nil)
        for _ in 0..<100 {
            if socket.state == .completed { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        reader?.cancel()
        session.invalidateAndCancel()
    }
}
