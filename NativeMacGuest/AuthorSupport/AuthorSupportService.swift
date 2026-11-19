#if NATIVE_DIRECT_UPDATES
import Combine
import CryptoKit
import Foundation

enum AuthorSupportClaimState: Equatable {
    case none, code(String, expires: Date), pending, active(through: Date)
}

struct SupportReceipt: Codable {
    static let publicKey = "SyVA6vPGDZnu7wKtv9iqQM9Cj+zWxg2BdhkUXSH+og0="
    let kind: String
    let schema: Int
    let device: String
    let nonce: String
    let issued: Int
    let through: Int
    let revision: Int

    static func validate(_ data: Data, device: String, nonce: String, now: Date,
                         publicKey: String = publicKey) throws -> Self {
        let envelope = try JSONDecoder().decode(SupportEnvelope.self, from: data)
        let r = try envelope.decode(Self.self, publicKey: publicKey)
        guard r.kind == "membership", r.schema == 1, r.revision > 0,
              r.device == device, r.nonce == nonce, r.issued > 0,
              r.issued <= Int(now.timeIntervalSince1970) + 300, r.through >= 0,
              r.through <= r.issued + 32 * 86_400 else { throw SupportIssue.invalidData }
        return r
    }
}

private final class SupportTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class AuthorSupportService: ObservableObject {
    static let shared = AuthorSupportService()
    @Published private var catalog: SupportCatalog?
    @Published private(set) var claim: AuthorSupportClaimState = .none

    var monthlyTiers: [AuthorSupportTier] { catalog?.tiers.sorted { $0.amountRUB < $1.amountRUB } ?? [] }
    var quoteDate: Date? { catalog.map { Date(timeIntervalSince1970: TimeInterval($0.quotedAt)) } }
    var bankURL: URL? { destination("bank") }
    var boostyOneTimeURL: URL? { destination("boosty") }
    var hipolinkTipsURL: URL? { destination("hipolink") }
    private func destination(_ method: String) -> URL? { catalog?.destinations.first { $0.method == method }?.url }

    private static let base = URL(string: "https://rock.glowsoft.ru/author-support/")!
    private static let catalogURLs = [
        base.appendingPathComponent("catalog.json"),
        URL(string: "https://raw.githubusercontent.com/vsmirn0v/rocknroll/main/NativeMacGuest/AuthorSupport/SupportDestinations.json")!
    ]
    private nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config, delegate: SupportTransport(), delegateQueue: nil)
    }()

    private struct Registration: Codable {
        var nonce: String
        var requestedAt: Int?
        var code: String?
        var expires: Int?
        var sent = false
        var submissionStarted: Bool?
        var reviewUntil: Int?
        var receipt: Data?
    }
    private struct CodeResponse: Decodable { let code: String; let expires: Int }
    private struct SubmissionResponse: Decodable { let reviewUntil: Int }
    private let keys = AttentionKeychain(service: "dev.vsmirn0v.rocknroll.author-support", account: "device-v1")
    private let enrollment = AttentionKeychain(service: "dev.vsmirn0v.rocknroll.author-support", account: "registration-v1")
    private let enrolledFlag = "author-support.enrolled.v1"
    private let defaults = UserDefaults.standard
    private var registerTask: Task<Void, Error>?
    private var refreshTask: Task<Void, Never>?
    private var currentReceipt: SupportReceipt?
    private let cachedURL: URL

    private init() {
        cachedURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RockNRoll/AuthorSupport/catalog.json")
        let bundled = Bundle.main.url(forResource: "SupportDestinations", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }.flatMap { try? SupportCatalog.load($0) }
        catalog = bundled
        if let stored = try? Data(contentsOf: cachedURL), let cached = try? SupportCatalog.load(stored),
           bundled.map({ cached.revision >= $0.revision && cached.retired.isSuperset(of: $0.retired) }) ?? true {
            catalog = cached
        }
        if defaults.bool(forKey: enrolledFlag), let registration = try? readRegistration(),
           let device = try? deviceID(create: false) { display(registration, device: device) }
    }

    func hasActiveSubscription(at now: Date) -> Bool {
        guard let receipt = currentReceipt else { return false }
        let seconds = Int(now.timeIntervalSince1970)
        return receipt.issued - 300 <= seconds && seconds <= receipt.through
    }

    func refresh() async {
        if let refreshTask { await refreshTask.value; return }
        let task = Task { @MainActor in
            async let first = try? Self.request(URLRequest(url: Self.catalogURLs[0]))
            async let second = try? Self.request(URLRequest(url: Self.catalogURLs[1]))
            async let receipt: Void? = try? refreshClaim()
            let snapshots = await [first, second].compactMap { reply -> (Data, SupportCatalog)? in
                guard let (status, data) = reply, status == 200, let parsed = try? SupportCatalog.load(data) else { return nil }
                return (data, parsed)
            }.sorted { $0.1.revision > $1.1.revision }
            if let candidate = snapshots.first, let previous = catalog,
               candidate.1.replaces(previous, now: Date()),
               snapshots.allSatisfy({ $0.1.revision != candidate.1.revision || $0.0 == candidate.0 }) {
                do {
                    try FileManager.default.createDirectory(at: cachedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try candidate.0.write(to: cachedURL, options: .atomic)
                    catalog = candidate.1
                } catch { /* Keep the last catalog installed on disk. */ }
            }
            _ = await receipt
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private nonisolated static func request(_ request: URLRequest) async throws -> (Int, Data) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, response.url == request.url,
              http.expectedContentLength <= 65_536 else { throw SupportIssue.invalidData }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 65_536 else { throw SupportIssue.invalidData }
            data.append(byte)
        }
        return (http.statusCode, data)
    }

    private func deviceID(create: Bool) throws -> String {
        let key: Curve25519.Signing.PrivateKey
        if let raw = keys.read() {
            guard let data = Data(base64Encoded: raw) else { throw SupportIssue.storage }
            key = try .init(rawRepresentation: data)
        } else {
            guard create, !defaults.bool(forKey: enrolledFlag) else { throw SupportIssue.storage }
            key = Curve25519.Signing.PrivateKey()
            guard keys.write(key.rawRepresentation.base64EncodedString()) else { throw SupportIssue.storage }
        }
        return SHA256.hash(data: key.publicKey.rawRepresentation).map { String(format: "%02x", $0) }.joined()
    }
    private func readRegistration() throws -> Registration? {
        guard let raw = enrollment.read(), let data = Data(base64Encoded: raw) else { return nil }
        return try JSONDecoder().decode(Registration.self, from: data)
    }
    private func store(_ registration: Registration) throws {
        guard enrollment.write(try JSONEncoder().encode(registration).base64EncodedString()) else { throw SupportIssue.storage }
        defaults.set(true, forKey: enrolledFlag)
    }
    private func display(_ registration: Registration, device: String) {
        let now = Date()
        currentReceipt = registration.receipt.flatMap { try? SupportReceipt.validate($0, device: device, nonce: registration.nonce, now: now) }
        if let r = currentReceipt, hasActiveSubscription(at: now) {
            claim = .active(through: Date(timeIntervalSince1970: Double(r.through)))
        } else if currentReceipt == nil, let expires = registration.expires, let code = registration.code {
            claim = Self.unverifiedState(code: code, expires: expires, reviewUntil: registration.reviewUntil, at: now)
        } else { claim = .none }
    }
    static func unverifiedState(code: String, expires: Int, reviewUntil: Int?, at now: Date) -> AuthorSupportClaimState {
        if let reviewUntil, Double(reviewUntil) > now.timeIntervalSince1970 { return .pending }
        if Double(expires) > now.timeIntervalSince1970 { return .code(code, expires: Date(timeIntervalSince1970: Double(expires))) }
        return .none
    }

    func startClaim() async throws {
        if let registerTask { try await registerTask.value; return }
        let task = Task { @MainActor in try await register() }
        registerTask = task
        defer { registerTask = nil }
        try await task.value
    }
    private func register() async throws {
        let device = try deviceID(create: true)
        var prior = try readRegistration()
        if let registration = prior {
            display(registration, device: device)
            if claim != .none { return }
            // A network timeout can occur after the server stored a code. Retrying the same nonce is idempotent.
            if registration.expires != nil || (registration.requestedAt ?? 0) + 1800 < Int(Date().timeIntervalSince1970) { prior = nil }
        }
        let nonce = Curve25519.Signing.PrivateKey().rawRepresentation.map { String(format: "%02x", $0) }.joined()
        var registration = prior ?? Registration(nonce: nonce, requestedAt: Int(Date().timeIntervalSince1970))
        try store(registration)
        var req = URLRequest(url: Self.base.appendingPathComponent("claims"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["device":device,"nonce":registration.nonce])
        let (status, data) = try await Self.request(req)
        guard [200,201].contains(status) else { throw SupportIssue.unavailable }
        let reply = try JSONDecoder().decode(CodeResponse.self, from: data)
        let now = Int(Date().timeIntervalSince1970)
        guard reply.code.range(of: #"^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{5}-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{5}$"#, options: .regularExpression) != nil,
              reply.expires > now, reply.expires <= now + 2100 else { throw SupportIssue.invalidData }
        registration.code = reply.code
        registration.expires = reply.expires
        try store(registration)
        display(registration, device: device)
    }
    func markClaimSent() async throws {
        guard var registration = try readRegistration(), let expires = registration.expires,
              Double(expires) > Date().timeIntervalSince1970 || registration.submissionStarted == true
        else { throw SupportIssue.unavailable }
        let device = try deviceID(create: false)
        registration.submissionStarted = true
        try store(registration)
        try await submit(registration, device: device)
    }
    private func submit(_ registration: Registration, device: String) async throws {
        var req = URLRequest(url: Self.base.appendingPathComponent("claims/sent"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["device":device,"nonce":registration.nonce])
        let (status, data) = try await Self.request(req)
        guard var current = try readRegistration(), current.nonce == registration.nonce else { return }
        guard status == 200 else {
            if [400,404,409,410].contains(status) {
                current.submissionStarted = false
                try store(current)
                display(current, device: device)
            }
            throw SupportIssue.unavailable
        }
        let until = try JSONDecoder().decode(SubmissionResponse.self, from: data).reviewUntil
        let now = Int(Date().timeIntervalSince1970)
        guard until > now, until <= now + 7 * 86_400 + 300 else { throw SupportIssue.invalidData }
        current.sent = true
        current.submissionStarted = false
        current.reviewUntil = until
        try store(current)
        display(current, device: device)
    }
    func refreshClaim() async throws {
        guard defaults.bool(forKey: enrolledFlag), let registration = try readRegistration() else { return }
        let device = try deviceID(create: false)
        display(registration, device: device)
        // If the acknowledgement was lost, replay the idempotent submission with the original nonce.
        if registration.submissionStarted == true && registration.reviewUntil == nil {
            try? await submit(registration, device: device)
        }
        guard registration.sent || registration.receipt != nil || registration.code != nil else { return }
        let url = Self.base.appendingPathComponent("receipts").appendingPathComponent(device).appendingPathComponent(registration.nonce)
        let (status, data) = try await Self.request(URLRequest(url: url))
        if status == 404 { return }
        guard status == 200 else { throw SupportIssue.unavailable }
        let new = try SupportReceipt.validate(data, device: device, nonce: registration.nonce, now: Date())
        guard var latest = try readRegistration(), latest.nonce == registration.nonce else { return }
        if let existing = latest.receipt {
            let old = try SupportReceipt.validate(existing, device: device, nonce: latest.nonce, now: Date())
            guard new.revision > old.revision else { return }
        }
        latest.receipt = data
        try store(latest)
        display(latest, device: device)
    }
}
#endif
