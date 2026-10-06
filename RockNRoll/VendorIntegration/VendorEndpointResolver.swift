import ConferenceCore
import Foundation

enum VendorEndpointResolver {
    static let calendarHostHints = ["jazz", "rock"]
    static let calendarNativeSchemes: Set<String> = ["conferenceguest", "jcp", "jazz"]
    private static let session = URLSession(configuration: .ephemeral,
                                            delegate: AdditionalRootTrust(), delegateQueue: nil)

    static func make() -> ConferenceEndpointResolver {
        return ConferenceEndpointResolver(serviceName: "jazz", session: session)
    }

    static func makeDetector() -> MeetingEngineDetector {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 3
        let session = URLSession(configuration: config, delegate: AdditionalRootTrust(), delegateQueue: nil)
        return MeetingEngineDetector(serviceName: "jazz", session: session)
    }
}
