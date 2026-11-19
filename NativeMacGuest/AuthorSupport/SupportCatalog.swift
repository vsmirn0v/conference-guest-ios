#if NATIVE_DIRECT_UPDATES
import CryptoKit
import Foundation

struct AuthorSupportTier: Codable, Equatable {
    let id: String
    let amountRUB: Int
    let usd: Decimal?
    let eur: Decimal?
    let checkoutURL: URL
}

struct SupportEnvelope: Codable {
    let payload: Data
    let signature: Data

    func decode<T: Decodable>(_ type: T.Type, publicKey: String) throws -> T {
        guard let keyBytes = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
              key.isValidSignature(signature, for: payload)
        else { throw SupportIssue.invalidData }
        return try JSONDecoder().decode(type, from: payload)
    }
}

enum SupportIssue: Error { case invalidData, unavailable, storage }

struct SupportCatalog: Codable {
    struct Destination: Codable {
        let id: String
        let method: String
        let url: URL
    }
    static let publicKey = "EqdxgBL6FZiCOOgihOjJkl6bG9SytDodMRE4iB3WTnE="
    let kind: String
    let schema: Int
    let revision: Int
    let quotedAt: Int
    let acceptUntil: Int
    let tiers: [AuthorSupportTier]
    let destinations: [Destination]
    let retired: Set<String>

    var identifiers: Set<String> { Set(tiers.map(\.id) + destinations.map(\.id)) }

    static func load(_ data: Data, key: String = publicKey) throws -> Self {
        guard data.count <= 64 * 1024 else { throw SupportIssue.invalidData }
        let envelope = try JSONDecoder().decode(SupportEnvelope.self, from: data)
        let value = try envelope.decode(Self.self, publicKey: key)
        guard value.kind == "direct-mac-author-support", value.schema == 1, value.revision > 0,
              value.quotedAt > 0, value.acceptUntil > value.quotedAt,
              value.tiers.count <= 24, value.destinations.count <= 8,
              value.identifiers.count == value.tiers.count + value.destinations.count,
              value.retired.isDisjoint(with: value.identifiers),
              Set(value.tiers.map(\.amountRUB)).count == value.tiers.count,
              Set(value.destinations.map(\.method)).count == value.destinations.count,
              value.tiers.allSatisfy({ tier in
                  (1...150_000).contains(tier.amountRUB) && tier.usd.map { $0 > 0 } != false &&
                    tier.eur.map { $0 > 0 } != false && valid(tier.checkoutURL, method: "tier")
              }), value.destinations.allSatisfy({ valid($0.url, method: $0.method) })
        else { throw SupportIssue.invalidData }
        return value
    }

    private static func valid(_ url: URL, method: String) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil else { return false }
        switch method {
        case "tier":
            return parts.host == "boosty.to" &&
                parts.percentEncodedPath.range(of: #"^/rwrt/purchase/[0-9]+$"#, options: .regularExpression) != nil &&
                (parts.percentEncodedQuery == nil || parts.percentEncodedQuery == "ssource=DIRECT&share=subscription_link")
        case "boosty": return url.absoluteString == "https://boosty.to/rwrt/donate"
        case "bank":
            return parts.host == "t.tb.ru" && parts.query == nil &&
                parts.percentEncodedPath.range(of: #"^/pm_short/[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
        case "hipolink": return url.absoluteString == "https://hipolink.net/vsmirnov/tips"
        default: return false
        }
    }

    /// A signed full replacement carries forward every removal so even an app update cannot revive it.
    func replaces(_ old: Self, now: Date) -> Bool {
        revision > old.revision && TimeInterval(acceptUntil) > now.timeIntervalSince1970 &&
            retired.isSuperset(of: old.retired.union(old.identifiers.subtracting(identifiers))) &&
            identifiers.isDisjoint(with: old.retired) &&
            tiers.allSatisfy { new in
                old.tiers.first(where: { $0.id == new.id }).map { $0.checkoutURL == new.checkoutURL && $0.amountRUB == new.amountRUB } ?? true
            } && destinations.allSatisfy { new in
                old.destinations.first(where: { $0.id == new.id }).map { $0.url == new.url && $0.method == new.method } ?? true
            }
    }
}
#endif
