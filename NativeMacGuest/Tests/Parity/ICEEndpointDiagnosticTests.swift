#if DEBUG
import Foundation
import XCTest
@testable import RockNativeDesktop

final class ICEEndpointDiagnosticTests: XCTestCase {
    func testTURNDiagnosticExtractsOnlyValidatedEndpointFields() throws {
        let cases: [(String, String, Int?)] = [
            ("turn:relay.example.test:3478?transport=udp", "relay.example.test", 3478),
            ("turn:192.0.2.10:443?transport=tcp", "192.0.2.10", 443),
            ("turn:[2001:db8::10]:3478?transport=udp", "2001:db8::10", 3478),
            ("turns:relay.example.test:443?transport=tcp", "relay.example.test", 443),
            ("turn:relay.example.test?transport=tcp", "relay.example.test", nil)]
        for (url, host, port) in cases {
            let value = try XCTUnwrap(GuestICEPolicy.diagnosticTurnServer(url))
            XCTAssertEqual(Set(value.keys), ["scheme", "host", "port", "transport"])
            XCTAssertEqual(value["host"] as? String, host)
            if let port { XCTAssertEqual(value["port"] as? Int, port) }
            else { XCTAssertTrue(value["port"] is NSNull, "An unspecified server port must remain unavailable") }
            XCTAssertTrue(JSONSerialization.isValidJSONObject(value))
        }
    }
    func testTURNDiagnosticRejectsCredentialsAndUnrecognizedAuthorities() {
        for url in [
            "turn:user:secret@relay.example.test:443?transport=tcp",
            "turn:user%3Asecret%40relay.example.test:443?transport=tcp",
            "turn://relay.example.test:443?transport=tcp",
            "turn:relay.example.test:443/path?transport=tcp",
            "turn:relay.example.test:443?transport=tcp#secret",
            "turn:relay.example.test:443?transport=tcp&credential=secret",
            "turn:relay.example.test:443?transport=unknown",
            "turn:relay.example.test:?transport=tcp",
            "turn:relay.example.test:0?transport=tcp",
            "turn:relay.example.test:65536?transport=tcp",
            "https://relay.example.test:443?transport=tcp"] {
            XCTAssertNil(GuestICEPolicy.diagnosticTurnServer(url), url)
        }
    }
}
#endif
