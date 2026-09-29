import Foundation

public enum BoundedHTTPError: LocalizedError {
    case invalidOrigin, oversizedBody, rejectedRedirect
    public var errorDescription: String? {
        switch self {
        case .invalidOrigin: "This jam did not provide a secure HTTPS connection."
        case .oversizedBody: "This jam returned an unexpectedly large response. Try again later."
        case .rejectedRedirect: "This jam redirected to another website. Use an invitation for that website instead."
        }
    }
}

/// Limits receipt rather than merely limiting JSON parsing after download.
public enum BoundedHTTP {
    public static func load(_ request: URLRequest, session: URLSession,
                            maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        guard let origin = request.url, origin.scheme?.lowercased() == "https",
              maximumBytes > 0 else { throw BoundedHTTPError.invalidOrigin }
        let redirects = SameOriginRedirects(origin: origin)
        let (bytes, response) = try await session.bytes(for: request, delegate: redirects)
        defer { bytes.task.cancel() }
        guard !redirects.rejected else { throw BoundedHTTPError.rejectedRedirect }
        guard let http = response as? HTTPURLResponse,
              let final = http.url, SameOriginRedirects.matches(final, origin) else {
            throw BoundedHTTPError.invalidOrigin
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            throw BoundedHTTPError.oversizedBody
        }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 4_096))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw BoundedHTTPError.oversizedBody }
            data.append(byte)
        }
        return (data, http)
    }
}

final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: URL
    private let lock = NSLock()
    private var wasRejected = false
    var rejected: Bool { lock.lock(); defer { lock.unlock() }; return wasRejected }
    init(origin: URL) { self.origin = origin }
    static func matches(_ candidate: URL, _ origin: URL) -> Bool {
        candidate.scheme?.lowercased() == "https" &&
            candidate.host?.lowercased() == origin.host?.lowercased() &&
            (candidate.port ?? 443) == (origin.port ?? 443) &&
            candidate.user == nil && candidate.password == nil
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.matches(url, origin) else {
            lock.lock(); wasRejected = true; lock.unlock()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
    // Do not override authentication challenges: the session's trust delegate
    // retains ownership of system and bundled certificate evaluation.
}
