import ConferenceCore

enum VendorEndpointResolver {
    static func make() -> ConferenceEndpointResolver {
        ConferenceEndpointResolver(serviceName: "jazz")
    }
}
