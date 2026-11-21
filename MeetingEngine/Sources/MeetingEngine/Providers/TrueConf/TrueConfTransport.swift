import Foundation

/// Serialize server events, but keep the socket reader/heartbeat independent
/// so an SDP handler can await an answer without starving control messages.
@MainActor
public final class TrueConfTransport {
    public var onMessage: (([String: Any]) async throws -> Void)?
    public var onFailure: ((Error) -> Void)?
    public var cid = ""
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private var reader: Task<Void, Never>?, processor: Task<Void, Never>?, heartbeat: Task<Void, Never>?
    private let events: AsyncStream<[String: Any]>
    private let continuation: AsyncStream<[String: Any]>.Continuation
    private var closed = false
    private var lastPong = ProcessInfo.processInfo.systemUptime
    public init(server: URL, session: URLSession) {
        self.session = session; socket = session.webSocketTask(with: server); socket.maximumMessageSize = 2_000_000
        var pipe: AsyncStream<[String: Any]>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(128)) { pipe = $0 }; continuation = pipe
    }
    public func start() {
        socket.resume()
        reader = Task { [weak self] in await self?.read() }
        processor = Task { [weak self, events] in
            for await event in events {
                guard let self, !closed else { return }
                do { try await onMessage?(event) }
                catch { if !Task.isCancelled { fail(error) }; return }
            }
        }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10)); try Task.checkCancellation()
                    guard let self else { return }
                    guard ProcessInfo.processInfo.systemUptime - lastPong < 35 else { throw TrueConfError.timedOut }
                    try await send(["method": "ping"])
                } catch { if !Task.isCancelled { self?.fail(error) }; return }
            }
        }
    }
    public func send(_ fields: [String: Any]) async throws {
        guard !closed else { throw TrueConfError.disconnected }
        var body = fields; if !cid.isEmpty { body["CID"] = cid }
        let data = try JSONSerialization.data(withJSONObject: body)
        guard data.count <= 1_000_000 else { throw TrueConfError.invalidResponse }
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    private func read() async {
        while !closed && !Task.isCancelled {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                guard data.count <= 2_000_000, let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let method = body["method"] as? String else { throw TrueConfError.invalidResponse }
                if method == "pong" { lastPong = ProcessInfo.processInfo.systemUptime; continue }
                if case .dropped = continuation.yield(body) { throw TrueConfError.invalidResponse }
            } catch { if !closed && !Task.isCancelled { fail(error) }; return }
        }
    }
    private func fail(_ error: Error) { let handler = onFailure; onFailure = nil; handler?(error) }
    public func close(room: String?) async {
        guard !closed else { return }
        closed = true
        onFailure = nil; onMessage = nil; heartbeat?.cancel(); processor?.cancel(); continuation.finish()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            reader?.cancel(); cid = ""; session.invalidateAndCancel()
        }
        if let room, !cid.isEmpty {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [self] in try? await self.send(["method": "hangup", "result": 0, "conferenceId": room]) }
                group.addTask { try? await Task.sleep(for: .seconds(1)) }
                _ = await group.next()
                group.cancelAll()
            }
        }
        for _ in 0..<50 { if socket.state == .completed { break }; try? await Task.sleep(for: .milliseconds(20)) }
    }
    #if DEBUG
    public func interruptForTesting() { socket.cancel(with: .goingAway, reason: nil) }
    #endif
}
