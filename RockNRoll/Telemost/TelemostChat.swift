import ConferenceCore
import Foundation

/// Anonymous guests receive chat. The service denies anonymous writes, so this
/// adapter never requests account access or suggests that delivery is possible.
@MainActor
final class TelemostChat {
    private let store: ChatStore
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var task: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var historyDirty = false
    private var generation = UUID()
    private var sequence = 0
    private var chatID = "", userID = ""
    private var subscription: String?
    private struct Pending { let completion: CheckedContinuation<[String: Any], Error>; let timeout: Task<Void, Never> }
    private var pending: [Int: Pending] = [:]
    init(store: ChatStore) { self.store = store }
    func start(invitation: URL, roomID: String) {
        stop(); let attempt = generation
        store.isReadOnly = true
        store.unavailableReason = L("Connecting to meeting chat…")
        let config = URLSessionConfiguration.ephemeral
        config.urlCredentialStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config); self.session = session
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // Establish only fresh anonymous service cookies, never device/account cookies.
                _ = try await BoundedHTTP.load(URLRequest(url: invitation, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15), session: session, maximumBytes: 1_000_000)
                let token = try await http("https://api.messenger.yandex.ru/csrf-token/", method: "POST")
                guard let csrf = token["token"] as? String else { throw TelemostError.invalidResponse }
                let registered = try await http("https://api.messenger.yandex.ru/api/registry/api", method: "POST",
                    body: ["method": "request_user", "params": ["bind_phone_number": false, "get_secret_sign": true]], csrf: csrf)
                guard let data = registered["data"] as? [String: Any], let user = data["user"] as? [String: Any],
                    let id = user["guid"] as? String, let sign = data["secret_sign"] as? [String: Any],
                    let signature = sign["sign"] as? String, let ts = sign["ts"] else { throw TelemostError.invalidResponse }
                let encoded = roomID.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
                var url = URLComponents(string: "https://cloud-api.yandex.ru/telemost_front/v2/telemost/chats/\(encoded)/join")!
                url.queryItems = [.init(name: "user", value: id)]
                let joined: [String: Any]
                do { joined = try await http(url.url!.absoluteString, method: "PUT") }
                catch TelemostError.requestFailed(404) {
                    url.path = String(url.path.dropLast(5))
                    joined = try await http(url.url!.absoluteString, method: "PUT")
                }
                guard let chat = joined["chat_path"] as? String, !chat.isEmpty, chat.utf8.count <= 256 else { throw TelemostError.invalidResponse }
                try Task.checkCancellation(); guard generation == attempt else { return }
                chatID = chat; userID = id
                var ws = URLComponents(string: "wss://push.yandex.ru/v2/subscribe/websocket")!
                ws.queryItems = ["service": "messenger-prod:version5*common+version5*main", "session": UUID().uuidString,
                    "client": "web_main", "user": id, "sign": signature, "ts": String(describing: ts)].map { .init(name: $0.key, value: $0.value) }
                // Xiva decodes its query as form data: preserve the literal service-tag plus.
                ws.percentEncodedQuery = ws.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
                var request = URLRequest(url: ws.url!); request.setValue("https://telemost.yandex.ru", forHTTPHeaderField: "Origin")
                let socket = session.webSocketTask(with: request); socket.maximumMessageSize = 2_000_000; self.socket = socket
                socket.resume()
                reader = Task { [weak self] in await self?.read(attempt) }
                let deadline = Date().addingTimeInterval(10)
                while subscription == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)); try Task.checkCancellation() }
                guard generation == attempt, subscription != nil else { throw TelemostError.timedOut }
                let history = try await requestHistory()
                guard generation == attempt else { return }
                store.replace(TelemostChatWire.entries(history, chatID: chat, ownID: id))
                store.unavailableReason = L("Read-only chat. This meeting service requires sign-in to send messages.")
            } catch {
                guard !Task.isCancelled, generation == attempt else { return }
                #if DEBUG
                print("Native chat initialization failed: \((error as NSError).domain)/\((error as NSError).code)")
                #endif
                disconnect()
                store.unavailableReason = L("Meeting chat is unavailable. Audio and video can continue.")
            }
        }
    }
    private func http(_ url: String, method: String, body: [String: Any]? = nil, csrf: String? = nil) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard let session else { throw CancellationError() }
        var request = URLRequest(url: URL(string: url)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method
        for (key, value) in ["Content-Type": "application/json", "Accept": "application/json", "X-Application-Id": "telemost", "Origin": "https://telemost.yandex.ru", "Referer": "https://telemost.yandex.ru/"] { request.setValue(value, forHTTPHeaderField: key) }
        if let csrf { request.setValue(csrf, forHTTPHeaderField: "X-CSRF-TOKEN") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await BoundedHTTP.load(request, session: session, maximumBytes: 1_000_000)
        try Task.checkCancellation()
        guard response.statusCode == 200 else { throw TelemostError.requestFailed(response.statusCode) }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TelemostError.invalidResponse }; return value
    }
    private func requestHistory() async throws -> [String: Any] {
        guard let socket, sequence < 65535, pending.count < 16 else { throw TelemostError.disconnected }
        sequence += 1; let id = sequence
        let packet = try TelemostChatWire.request(id: id, method: "history", body: ["RequestId": UUID().uuidString, "ChatId": chatID, "Limit": 200, "ChatDataFilter": [:]])
        return try await withCheckedThrowingContinuation { completion in
            let timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                self?.complete(id, result: .failure(TelemostError.timedOut))
            }
            pending[id] = .init(completion: completion, timeout: timeout)
            Task { [weak self] in do { try await socket.send(.data(packet)) } catch { self?.complete(id, result: .failure(error)) } }
        }
    }
    private func read(_ attempt: UUID) async {
        guard let socket else { return }
        do {
            while generation == attempt, !Task.isCancelled {
                let message = try await socket.receive()
                guard generation == attempt else { break }
                switch message {
                case .string(let value):
                    guard value.utf8.count <= 16_000, let object = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else { throw TelemostError.invalidResponse }
                    if object["operation"] as? String == "subscribed" { subscription = object["subscription-id"] as? String }
                    if object["operation"] as? String == "unsubscribe" || object["operation"] as? String == "xivaws-error" { throw TelemostError.disconnected }
                case .data(let data):
                    let packet = try TelemostChatWire.decode(data)
                    if packet.type == 3 {
                        if TelemostChatWire.messageChatID(packet.body) == chatID {
                            refreshHistory(attempt)
                        }
                    } else if let id = packet.requestID {
                        let status = packet.body["Status"] as? Int ?? 0
                        complete(id, result: packet.type == 2 || status != 0 ? .failure(TelemostError.rejected(String(status))) : .success(packet.body))
                    }
                @unknown default: break
                }
            }
        } catch {
            guard generation == attempt, !Task.isCancelled else { return }
            disconnect(); store.unavailableReason = L("Meeting chat is unavailable. Audio and video can continue.")
        }
    }
    private func refreshHistory(_ attempt: UUID) {
        historyDirty = true
        guard historyTask == nil else { return }
        historyTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == attempt { self.historyTask = nil } }
            while historyDirty, generation == attempt, !Task.isCancelled {
                historyDirty = false
                do {
                    let snapshot = try await requestHistory()
                    guard generation == attempt, !Task.isCancelled else { return }
                    store.replace(TelemostChatWire.entries(snapshot, chatID: chatID, ownID: userID))
                } catch {
                    guard generation == attempt, !Task.isCancelled else { return }
                    store.unavailableReason = L("Meeting chat is unavailable. Audio and video can continue.")
                    return
                }
            }
        }
    }
    private func complete(_ id: Int, result: Result<[String: Any], Error>) {
        guard let value = pending.removeValue(forKey: id) else { return }
        value.timeout.cancel(); value.completion.resume(with: result)
    }
    private func disconnect() {
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        for id in Array(pending.keys) { complete(id, result: .failure(CancellationError())) }
        session?.invalidateAndCancel(); session = nil
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; reader?.cancel(); reader = nil
        historyTask?.cancel(); historyTask = nil; historyDirty = false
        disconnect(); chatID = ""; userID = ""; subscription = nil; sequence = 0
        store.canSend = false
    }
}
