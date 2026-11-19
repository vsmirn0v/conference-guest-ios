#if NATIVE_DIRECT_UPDATES
import CryptoKit
import XCTest
@testable import RockNativeDesktop

final class AuthorSupportTrustTests: XCTestCase {
    let key = Curve25519.Signing.PrivateKey()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func signed(_ object: [String:Any]) throws -> Data {
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try JSONEncoder().encode(SupportEnvelope(payload: bytes, signature: key.signature(for: bytes)))
    }

    func testDeviceBoundReceiptNeedsTheRightSignerAndNonce() throws {
        let time = Int(now.timeIntervalSince1970)
        var p: [String:Any] = ["kind":"membership", "schema":1, "device":"this-mac", "nonce":"this-claim",
                               "issued":time, "through":time + 86400, "revision":1]
        let valid = try signed(p)
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        func validate(_ data: Data, nonce: String = "this-claim") throws -> SupportReceipt {
            try SupportReceipt.validate(data, device:"this-mac", nonce:nonce, now:now, publicKey:publicKey)
        }
        XCTAssertEqual(try validate(valid).through, time + 86400)
        XCTAssertThrowsError(try validate(valid, nonce:"unrelated"))
        XCTAssertThrowsError(try SupportReceipt.validate(valid, device:"this-mac", nonce:"this-claim", now:now))
        p["through"] = time + 365 * 86400
        XCTAssertThrowsError(try validate(signed(p)))
        p["through"] = 0
        XCTAssertEqual(try validate(signed(p)).through, 0)
    }

    func testCatalogRejectsUnsignedAndRetiredOrOlderDestinations() throws {
        let row = ["id":"bank-original","method":"bank","url":"https://t.tb.ru/pm_short/Example"]
        let expiry = Int(now.timeIntervalSince1970) + 86400
        var fields: [String:Any] = ["kind":"direct-mac-author-support", "schema":1, "revision":1, "quotedAt":1,
                                    "acceptUntil":expiry, "tiers":[], "destinations":[row], "retired":[]]
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        func load() throws -> SupportCatalog { try SupportCatalog.load(signed(fields), key:publicKey) }
        let original = try load()
        XCTAssertThrowsError(try SupportCatalog.load(signed(fields)))
        fields["revision"] = 2; fields["destinations"] = []
        XCTAssertFalse(try load().replaces(original, now:now))
        fields["retired"] = ["bank-original"]
        let withdrawn = try load()
        XCTAssertTrue(withdrawn.replaces(original, now:now))
        XCTAssertFalse(original.replaces(withdrawn, now:now))
        fields["revision"] = 3; fields["retired"] = []; fields["destinations"] = [row]
        XCTAssertFalse(try load().replaces(withdrawn, now:now))
        var wrongPayee = row; wrongPayee["url"] = "https://example.org/donate"
        fields["destinations"] = [wrongPayee]
        XCTAssertThrowsError(try load())
    }
}
#endif
