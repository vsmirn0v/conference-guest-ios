import JazzSDK

/// An empty access token selects the provider's anonymous guest path.
/// This behavior was verified with the pinned SDK and a guest-enabled meeting.
final class AnonymousTokenProvider: JazzConferenceTokenProvider {
    func token() async -> Result<String, ConferenceTokenError> {
        .success("")
    }

    func provideToken(completion: @escaping AuthTokenCompletion) {
        completion(.success(""))
    }
}
