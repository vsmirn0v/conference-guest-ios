import ConferenceCore
import Foundation

public enum VendorEndpointResolver {
    public static let calendarHostHints = ["jazz", "rock"]
    public static let calendarNativeSchemes: Set<String> = ["conferenceguest", "jcp", "jazz"]
    private static let session = URLSession(configuration: .ephemeral,
                                            delegate: AdditionalRootTrust(), delegateQueue: nil)

    public static func make() -> ConferenceEndpointResolver {
        return ConferenceEndpointResolver(serviceName: "jazz", session: session)
    }

    private static let detectorSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 3
        return URLSession(configuration: config, delegate: AdditionalRootTrust(), delegateQueue: nil)
    }()

    public static func makeDetector() -> MeetingEngineDetector {
        return MeetingEngineDetector(serviceName: "jazz", session: detectorSession)
    }
}
