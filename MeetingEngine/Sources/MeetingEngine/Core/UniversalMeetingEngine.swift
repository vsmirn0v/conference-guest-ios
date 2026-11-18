import ConferenceCore
import Foundation
import LiveKitWebRTC

@MainActor public final class UniversalMeetingEngine {
    public struct Configuration: Equatable {
        private static let allProviders: Set<MeetingEngineKind> = [.guest, .community, .telemost, .trueconf]
        public let enabledProviders: Set<MeetingEngineKind>

        public init(enabledProviders: Set<MeetingEngineKind>) {
            self.enabledProviders = enabledProviders
        }

        public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
            guard let raw = environment["ROCK_UNIVERSAL_PROVIDERS"]?
                .split(separator: ",")
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .filter({ !$0.isEmpty }),
                  !raw.isEmpty else {
                return Self(enabledProviders: allProviders)
            }
            let parsed = Set(raw.compactMap(MeetingEngineKind.init(rawValue:)))
            return Self(enabledProviders: parsed.isEmpty ? allProviders : parsed)
        }
    }

    public static let forceTCPRelayKey = "nativeDesktop.forceTCPRelay"
    public nonisolated(unsafe) static var defaultCameraCaptureFactory: ((LKRTCVideoSource) -> any GuestCameraCapture)? {
        get { GuestCamera.defaultFactory }
        set { GuestCamera.defaultFactory = newValue }
    }
    public static let shared = UniversalMeetingEngine(sharedAudio: SharedAudioEngine.enabledAtLaunch ? SharedAudioEngine.shared : nil)

    private struct WeakSession {
        weak var session: MeetingSession?
    }

    public let configuration: Configuration
    public let sharedAudio: SharedAudioEngine?
    private var sessions: [MeetingSessionID: WeakSession] = [:]

    public init(sharedAudio: SharedAudioEngine? = nil, configuration: Configuration = .current()) {
        self.sharedAudio = sharedAudio
        self.configuration = configuration
    }

    public var activeSessionCount: Int {
        pruneReleasedSessions()
        return sessions.count
    }

    public var busy: Bool {
        activeSessionCount > 0 || sharedAudio?.busy == true
    }

    public var ownershipDiagnostics: [String: Any] {
        pruneReleasedSessions()
        let active = sessions.keys.sorted { $0.uuidString < $1.uuidString }.prefix(16).compactMap { id -> [String: Any]? in
            guard let session = sessions[id]?.session else { return nil }
            return session.ownershipDiagnostics
        }
        return [
            "engine": "universal-meeting-engine",
            "activeSessionCount": sessions.count,
            "sessions": active,
            "sharedAudio": sharedAudio?.ownershipDiagnostics ?? ["state": "disabled"],
        ]
    }

    public func makeSession(destination: JoinDestination,
                     chat: ChatStore? = nil,
                     adapter overrideAdapter: (any MeetingProviderAdapter)? = nil,
                     rockService: JamService? = nil,
                     exclusiveTalk: Bool = false) -> MeetingSession {
        let id = UUID()
        let adapter: any MeetingProviderAdapter
        if let overrideAdapter {
            adapter = overrideAdapter
        } else {
            switch destination.engineKind {
            case .guest:
                adapter = GuestAdapter(sharedAudio: sharedAudio, exclusiveTalk: exclusiveTalk)
            case .community:
                adapter = RockAdapter(service: rockService ?? JamService(), chat: chat ?? ChatStore(), sharedAudio: sharedAudio)
            case .telemost:
                adapter = TelemostAdapter(chat: chat ?? ChatStore(), sharedAudio: sharedAudio)
            case .trueconf:
                adapter = TrueConfAdapter(sharedAudio: sharedAudio)
            }
        }
        let session = MeetingSession(id: id, kind: destination.engineKind, adapter: adapter, exclusiveTalk: exclusiveTalk) { [weak self] sessionID in
            self?.unregister(sessionID: sessionID)
        }
        sessions[id] = WeakSession(session: session)
        return session
    }

    public func registerExternalSession(_ session: MeetingSession) {
        sessions[session.id] = WeakSession(session: session)
    }

    public func unregister(sessionID: MeetingSessionID) {
        sessions[sessionID] = nil
    }

    public func session(id: MeetingSessionID) -> MeetingSession? {
        pruneReleasedSessions()
        return sessions[id]?.session
    }

    private func pruneReleasedSessions() {
        sessions = sessions.filter { $0.value.session != nil }
    }
}
