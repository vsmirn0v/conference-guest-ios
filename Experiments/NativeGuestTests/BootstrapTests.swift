import Foundation

// Standalone contract tests: URLProtocol intercepts every HTTP request. No room
// creation, WebSocket connection, vendor framework, or external network is used.
private enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String { switch self { case .assertion(let message): return message } }
}

private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw TestFailure.assertion(message) }
}

private final class MockProtocol: URLProtocol {
    enum Action { case response(Int, Data), hold }
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Action)?
    private static var captured: [URLRequest] = []

    static func configure(_ handler: @escaping (URLRequest) -> Action) {
        lock.lock(); defer { lock.unlock() }
        Self.handler = handler; captured = []
    }
    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }
    static func reply(_ object: [String: Any], status: Int = 200) -> Action {
        .response(status, try! JSONSerialization.data(withJSONObject: object))
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.captured.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: TestFailure.assertion("Unconfigured mock request"))
            return
        }
        switch handler(request) {
        case .hold: break // URLSession cancellation must release this in-flight operation.
        case .response(let status, let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@main private struct BootstrapTests {
    private static let discovery: [String: Any] = ["jazz": ["serverUrl": "https://signal.fixture.invalid/api"]]
    private static let connector = "wss://signal.fixture.invalid/connect"

    static func main() async {
        do {
            try invitationParsing()
            try correlation()
            try await discoveryFallbackAndPayloads()
            try await preconnectFailures()
            try await discoveryFailures()
            try await bootstrapCancellation()
            try await transportLifecycle()
            print("PASS: native bootstrap and transport contract tests (no external network)")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func fixture() throws -> GuestInvitation {
        try GuestInvitation.parse("https://fixture.invalid:8443/calls/room%20code?psw=OAMDFgFVV0VdEwQAXkFAVlIZGQ")
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func invitationParsing() throws {
        let invitation = try fixture()
        try expect(invitation.roomID == "room code", "Percent-encoded room ID was not decoded once")
        try expect(invitation.password == "pass1234", "Encoded invitation password was not decoded")
        try expect(invitation.origin.absoluteString == "https://fixture.invalid:8443", "Origin did not retain port")
        let root = try GuestInvitation(url: URL(string: "https://fixture.invalid/room?psw=MRIDBBMFBBcIAgQSTBETBAcIGQ")!)
        try expect(root.roomID == "room", "Root-path invitations are unsupported")
        try expect(root.password == "a", "One-character password did not decode")
        // Independent golden vectors reproduced from PasswordCoderImpl's wire format.
        for (encoded, password) in [
            ("NxJJB00nOk8ISAdMbi9LBE0LRw", "a+b?C_9"),
            ("OUJQVkZRU0FRWlRBHkRHU1FRQQ", "123456789")
        ] {
            let target = try GuestInvitation.parse("https://fixture.invalid/room?psw=\(encoded)")
            try expect(target.password == password, "Golden invitation password vector failed")
        }
        let withoutPassword = try GuestInvitation.parse("https://fixture.invalid/calls/room")
        try expect(withoutPassword.password.isEmpty, "Missing optional password must remain empty")
        for text in [
            "http://fixture.invalid/room", "https://u:p@fixture.invalid/room",
            "https://fixture.invalid/", "https://fixture.invalid/a%2Fb",
            "https://fixture.invalid/a%5Cb", "https://fixture.invalid/%00",
            "https://fixture.invalid/room?psw=a&psw=b", "https://fixture.invalid/room?psw",
            "https://fixture.invalid/room#fragment", "https://fixture.invalid/room?psw=not-base64!",
            "https://fixture.invalid/room?psw=OEE", "https://fixture.invalid/room?psw=YQ"
        ] {
            do {
                _ = try GuestInvitation.parse(text)
                throw TestFailure.assertion("Invalid invitation was accepted")
            } catch GuestBootstrapError.invalidInvitation { }
        }
    }

    private static func correlation() throws {
        let requestID = "fixture-request"
        for event in ["join-response", "error"] {
            try expect(GuestTransport.isResponse(["requestId": requestID, "event": event],
                                                 requestID: requestID, event: "join"),
                       "Valid response was not correlated")
        }
        for envelope: [String: Any] in [
            ["requestId": "other", "event": "join-response"],
            ["requestId": requestID, "event": "joined"],
            ["requestId": requestID, "event": "media-out"],
            ["requestId": requestID, "event": "leave-response"],
            ["requestId": 1, "event": "join-response"], ["event": "error"]
        ] {
            try expect(!GuestTransport.isResponse(envelope, requestID: requestID, event: "join"),
                       "Unrelated event incorrectly completed a request")
        }
    }

    private static func discoveryFallbackAndPayloads() async throws {
        MockProtocol.configure { request in
            switch request.url!.path {
            case "/.well-known/jazz-services.json": return MockProtocol.reply([:], status: 404)
            case "/.well-known/s2b-services.json": return MockProtocol.reply(discovery)
            default: return MockProtocol.reply(["connectorUrl": connector, "roomTitle": "fixture", "roomType": "ANONYMOUS"])
            }
        }
        let session = session()
        defer { session.invalidateAndCancel() }
        let prepared = try await GuestBootstrap(session: session).prepare(
            fixture(), participantName: "Fixture", supportedFeatures: ["fixtureFeature": true],
            sessionID: "fixture-session", jazzToken: "fixture-token")
        let requests = MockProtocol.requests
        try expect(requests.count == 3, "Discovery fallback did not make exactly three requests")
        try expect(requests.map { $0.url!.path } == ["/.well-known/jazz-services.json", "/.well-known/s2b-services.json", "/api/room/room code/preconnect"],
                   "Discovery or preconnect endpoint differed from the SDK contract")
        try expect(requests[0].httpMethod == "GET", "Service discovery must use GET")
        try expect(requests[2].httpMethod == "POST", "Preconnect must use POST")
        try expect(requests[2].value(forHTTPHeaderField: "Accept") == "application/json", "Missing JSON accept header")
        try expect(requests[2].value(forHTTPHeaderField: "Content-Type") == "application/json", "Missing JSON content type")
        let body = try requestBody(requests[2])
        try expect(body["password"] as? String == "pass1234", "Preconnect password changed")
        let migration = body["jazzNextMigration"] as? NSDictionary
        let expectedMigration: NSDictionary = [
            "b2bBaseRoomSupport": true, "demoRoomBaseSupport": true, "demoRoomVersionSupport": 2,
            "mediaWithoutAutoSubscribeSupport": true, "webinarSpeakerSupport": false,
            "webinarViewerSupport": false, "sdkRoomSupport": true, "sberclassRoomSupport": false
        ]
        try expect(migration == expectedMigration, "Preconnect migration fields differed from SDK defaults")
        try expect(prepared.serverURL.absoluteString == "https://signal.fixture.invalid/api", "Server URL prefix changed")
        try expect(prepared.connectorURL.absoluteString == connector, "Connector URL changed")
        try expect(prepared.roomID == "room code", "Prepared room ID changed")
        let join = prepared.joinPayload
        try expect(join["participantName"] as? String == "Fixture", "Join participant name changed")
        try expect(join["password"] as? String == "pass1234", "Join password changed")
        try expect(join["sessionId"] as? String == "fixture-session", "Join session ID missing")
        try expect(join["jazzToken"] as? String == "fixture-token", "Join token missing")
        try expect(join["supportedFeatures"] as? [String: Bool] == ["fixtureFeature": true], "Join features changed")
        try expect(join["isSilent"] as? Bool == false, "Ordinary guest join must not be silent")
    }

    private static func preconnectFailures() async throws {
        for response: [String: Any] in [[:], ["connectorUrl": ""]] {
            try await expectPrepareFailure(response: response) {
                if case .unsupportedLegacyRoom = $0 { return true }; return false
            }
        }
        for url in ["ws://signal.fixture.invalid/connect", "https://signal.fixture.invalid/connect",
                    "wss://u:p@signal.fixture.invalid/connect", "wss://signal.fixture.invalid/connect#fragment"] {
            try await expectPrepareFailure(response: ["connectorUrl": url]) {
                if case .invalidPreconnect = $0 { return true }; return false
            }
        }
        try await expectPrepareFailure(response: [:], status: 403) {
            if case .httpStatus(403) = $0 { return true }; return false
        }
        // Missing optional join fields must remain omitted rather than become JSON null.
        MockProtocol.configure { request in
            MockProtocol.reply(request.url!.path.hasPrefix("/.well-known/") ? discovery : ["connectorUrl": connector])
        }
        let session = session()
        defer { session.invalidateAndCancel() }
        let result = try await GuestBootstrap(session: session).prepare(fixture(), participantName: "Fixture")
        try expect(result.joinPayload["sessionId"] == nil && result.joinPayload["jazzToken"] == nil,
                   "Optional session and token must be omitted")
    }

    private static func expectPrepareFailure(response: [String: Any], status: Int = 200,
                                             matches: (GuestBootstrapError) -> Bool) async throws {
        MockProtocol.configure { request in
            request.url!.path.hasPrefix("/.well-known/") ? MockProtocol.reply(discovery) : MockProtocol.reply(response, status: status)
        }
        let session = session()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await GuestBootstrap(session: session).prepare(fixture(), participantName: "Fixture")
            throw TestFailure.assertion("Invalid preconnect result was accepted")
        } catch let error as GuestBootstrapError {
            try expect(matches(error), "Unexpected bootstrap failure category")
        }
        try expect(MockProtocol.requests.count == 2, "Preconnect failure retried or used an unexpected endpoint")
    }

    private static func discoveryFailures() async throws {
        MockProtocol.configure { _ in MockProtocol.reply(["jazz": ["serverUrl": "http://signal.fixture.invalid"]]) }
        let session = session()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await GuestBootstrap(session: session).prepare(fixture(), participantName: "Fixture")
            throw TestFailure.assertion("Insecure discovery server was accepted")
        } catch GuestBootstrapError.invalidServiceDiscovery { }
        try expect(MockProtocol.requests.count == 1, "Invalid discovery data should fail before preconnect")
        MockProtocol.configure { request in
            MockProtocol.reply([:], status: request.url!.path.contains("jazz-services") ? 404 : 503)
        }
        do {
            _ = try await GuestBootstrap(session: session).prepare(fixture(), participantName: "Fixture")
            throw TestFailure.assertion("Failed discovery was accepted")
        } catch GuestBootstrapError.httpStatus(503) { }
        try expect(MockProtocol.requests.count == 2, "Failed discovery did not attempt exactly one fallback")
    }

    private static func bootstrapCancellation() async throws {
        MockProtocol.configure { request in
            request.url!.path.hasPrefix("/.well-known/") ? MockProtocol.reply(discovery) : .hold
        }
        let session = session()
        defer { session.invalidateAndCancel() }
        let bootstrap = GuestBootstrap(session: session)
        let invitation = try fixture()
        let operation = Task { try await bootstrap.prepare(invitation, participantName: "Fixture") }
        var started = false
        for _ in 0..<100 {
            if MockProtocol.requests.count == 2 { started = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard started else { operation.cancel(); throw TestFailure.assertion("Mock preconnect did not start") }
        operation.cancel()
        switch await operation.result {
        case .success: throw TestFailure.assertion("Canceled preconnect succeeded")
        case .failure(let error):
            try expect(error is CancellationError || (error as? URLError)?.code == .cancelled,
                       "Canceled preconnect did not propagate cancellation")
        }
    }

    private static func transportLifecycle() async throws {
        let transport = GuestTransport(url: URL(string: connector)!, roomID: "fixture-room")
        do {
            _ = try await transport.request("join")
            throw TestFailure.assertion("Disconnected transport accepted a request")
        } catch GuestTransportError.notConnected { }
        // Cancellation is set before entering connect, proving no socket is allocated.
        let connection = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await transport.connect()
        }
        do {
            try await connection.value
            throw TestFailure.assertion("Canceled connect succeeded")
        } catch is CancellationError { }
        await transport.close()
        await transport.close()
        do {
            _ = try await transport.request("join")
            throw TestFailure.assertion("Closed transport accepted a request")
        } catch GuestTransportError.closed { }
        do {
            try await transport.notify("media-in")
            throw TestFailure.assertion("Closed transport accepted a notification")
        } catch GuestTransportError.closed { }
        var iterator = transport.events.makeAsyncIterator()
        let event = await iterator.next()
        try expect(event == nil, "Closed transport did not finish its event stream")
    }

    private static func requestBody(_ request: URLRequest) throws -> [String: Any] {
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        guard let body = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw TestFailure.assertion("HTTP body was not a JSON object")
        }
        return body
    }
}
