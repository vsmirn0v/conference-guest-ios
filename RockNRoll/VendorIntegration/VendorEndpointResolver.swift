import ConferenceCore
import Foundation

enum VendorEndpointResolver {
    private static let session = URLSession(configuration: .ephemeral,
                                            delegate: AdditionalRootTrust(), delegateQueue: nil)

    static func make() -> ConferenceEndpointResolver {
        return ConferenceEndpointResolver(serviceName: "jazz", session: session)
    }
}
