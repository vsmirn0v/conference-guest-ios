import ConferenceCore
import UIKit
import XCTest
@testable import RockNRoll

final class JamServiceTests: XCTestCase {
    final class Response: URLProtocol {
        static var status = 400
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    func testValidationRateLimitAndServiceFailuresHaveActionableErrors() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Response.self]
        let service = JamService(session: URLSession(configuration: config))
        let target = try JamTarget.parse("https://rock.glowsoft.ru/jams/test")
        for (status, text) in [(400, "name"), (429, "Wait"), (503, "temporarily")] {
            Response.status = status
            do { _ = try await service.join(target, name: "Ani"); XCTFail("Failure accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains(text), error.localizedDescription) }
        }
    }
}

@MainActor
final class ConferenceJoinOptionsTests: XCTestCase {
    final class FailedJoin: URLProtocol {
        private static let lock = NSLock()
        private static var names: [String] = []
        static var requestedNames: [String] { lock.lock(); defer { lock.unlock() }; return names }
        static func reset() { lock.lock(); names = []; lock.unlock() }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 1_024)
                while data.count < 4_096 {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    data.append(contentsOf: bytes.prefix(count))
                }
            }
            let name = (try? JSONDecoder().decode([String: String].self, from: data))?["name"] ?? "<missing>"
            Self.lock.lock(); Self.names.append(name); Self.lock.unlock()
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 400,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    private var savedName: Any?
    override func setUp() {
        super.setUp()
        savedName = UserDefaults.standard.object(forKey: "savedDisplayName")
        FailedJoin.reset()
    }
    override func tearDown() {
        if let savedName { UserDefaults.standard.set(savedName, forKey: "savedDisplayName") }
        else { UserDefaults.standard.removeObject(forKey: "savedDisplayName") }
        super.tearDown()
    }
    private func model() -> (ConferenceModel, UIViewController) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailedJoin.self]
        let model = ConferenceModel(jamService: JamService(session: URLSession(configuration: config)))
        model.installSyncFixture(RoomSyncCoordinator(history: model.history, name: model.displayName,
            preferences: UserDefaults(suiteName: "JoinOptions-" + UUID().uuidString)!,
            storage: RoomSyncCoordinatorTests.Storage(), transport: RoomSyncCoordinatorTests.Cloud()))
        model.displayName = "Configured musician"
        let container = UIViewController()
        model.configure(container: container)
        return (model, container)
    }
    private func invitation(_ url: String = "https://rock.glowsoft.ru/jams/test") -> ActiveJam {
        .init(deviceID: "source", invitation: URL(string: url)!, title: "Room",
              name: "Transferred musician", deviceLabel: "Mac", supportsCompanion: true)
    }
    private func waitForFailure(_ model: ConferenceModel) async {
        let end = Date().addingTimeInterval(3)
        while model.isJoining, Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isJoining)
        XCTAssertTrue(model.statusIsError)
    }
    func testFailedQuietJoinDoesNotChangeTheNextOrdinaryJoin() async {
        let (model, container) = model()
        XCTAssertNotNil(model.joinFromContinuation(invitation(), quiet: true))
        XCTAssertTrue(model.companionAudioPaused)
        await waitForFailure(model)
        XCTAssertFalse(model.companionAudioPaused)
        model.receive(url: invitation().invitation)
        model.join()
        XCTAssertTrue(model.isJoining)
        XCTAssertFalse(model.companionAudioPaused)
        await waitForFailure(model)
        XCTAssertEqual(FailedJoin.requestedNames, ["Transferred musician", "Configured musician"])
        withExtendedLifetime(container) {}
    }
    func testCancelledQuietJoinDoesNotChangeTheNextOrdinaryJoin() async {
        let (model, container) = model()
        model.joinFromContinuation(invitation(), quiet: true)
        model.leave()
        XCTAssertFalse(model.companionAudioPaused)
        model.receive(url: invitation().invitation)
        model.join()
        XCTAssertTrue(model.isJoining)
        XCTAssertFalse(model.companionAudioPaused)
        await waitForFailure(model)
        XCTAssertEqual(FailedJoin.requestedNames.last, "Configured musician")
        withExtendedLifetime(container) {}
    }
    func testInvalidContinuationLinkDoesNotOverrideTheNextJoinName() async {
        let (model, container) = model()
        XCTAssertNil(model.joinFromContinuation(invitation("http://invalid.example/room"), quiet: true))
        model.receive(url: invitation().invitation)
        model.join()
        XCTAssertFalse(model.companionAudioPaused)
        await waitForFailure(model)
        XCTAssertEqual(FailedJoin.requestedNames, ["Configured musician"])
        withExtendedLifetime(container) {}
    }
}
