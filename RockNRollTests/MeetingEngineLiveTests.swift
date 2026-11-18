import ConferenceCore
import XCTest
@testable import RockNRoll

final class MeetingEngineLiveTests: XCTestCase {
    func testBundledRootsDoNotAcceptExpiredOrMismatchedCertificates() async throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_ENGINE_PROBES"] == "1" else {
            throw XCTSkip("Opt-in live TLS rejection check.")
        }
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config, delegate: AdditionalRootTrust(), delegateQueue: nil)
        for host in ["expired.badssl.com", "wrong.host.badssl.com"] {
            do {
                _ = try await BoundedHTTP.load(URLRequest(url: URL(string: "https://" + host)!), session: session, maximumBytes: 8192)
                XCTFail("Invalid certificate accepted")
            } catch let error as URLError {
                XCTAssertTrue([.serverCertificateUntrusted, .serverCertificateHasBadDate,
                               .serverCertificateHasUnknownRoot, .secureConnectionFailed, .cancelled].contains(error.code),
                              "A transport failure is not evidence of TLS rejection: \(error.code)")
            }
        }
    }
    func testPublicOriginsAdvertiseExpectedEnginesWithSystemAndBundledTrust() async throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_ENGINE_PROBES"] == "1" else {
            throw XCTSkip("Opt-in read-only live discovery check.")
        }
        let detector = VendorEndpointResolver.makeDetector()
        for (text, expected) in [("https://rock.glowsoft.ru/jams/test", MeetingEngineKind.community),
                                 ("https://salutejazz.ru/calls/probe", .guest),
                                 ("https://jazz.sberbank.ru/probe", .guest)] {
            let start = Date()
            let result = try await detector.detect(URL(string: text)!)
            switch (result, expected) {
            case (.verified(.community), .community), (.verified(.guest), .guest): break
            default: XCTFail("Expected \(expected), got \(result)")
            }
            print("Read-only \(expected) discovery: \(Int(Date().timeIntervalSince(start) * 1_000)) ms")
        }
    }
}
