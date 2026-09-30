#if DEBUG && targetEnvironment(simulator)
import ConferenceCore
import Foundation

@MainActor
enum MeetingContinuationUIFixture {
    private final class Cloud: MeetingContinuationTransport {
        var active: [ActiveJam]
        var request: JamTransfer?
        init(sharing: Bool) {
            active = [ActiveJam(deviceID: "fixture-mac", invitation: URL(string: "https://meeting.example.test/quartet?psw=fixture")!,
                                title: "Friday quartet", name: "Ani", deviceLabel: "Mac", isSharingScreen: sharing),
                      ActiveJam(deviceID: "fixture-ipad", invitation: URL(string: "https://meeting.example.test/practice")!,
                                title: "Morning practice", name: "Ani", deviceLabel: "iPad", updatedAt: Date().addingTimeInterval(-300))]
        }
        func connect(account: String) async throws {}
        func jams() async throws -> [ActiveJam] { active }
        func publish(_ jam: ActiveJam) async throws {}
        func withdraw(deviceID: String, sessionID: UUID?) async throws {}
        func claim(_ transfer: JamTransfer) async throws { request = transfer; request?.phase = .prepared }
        func transfer(sourceSession: UUID) async throws -> JamTransfer? { request }
        func transition(_ transfer: JamTransfer, to phase: JamTransfer.Phase, actor: String) async throws -> JamTransfer {
            var copy = transfer; copy.phase = phase == .connected ? .completed : phase
            request = copy
            if copy.phase == .completed { active.removeAll { $0.deviceID == copy.sourceDevice } }
            return copy
        }
        func clear() async throws { active = [] }
    }
    static func configure(_ model: ConferenceModel) {
        guard let mode = ProcessInfo.processInfo.environment["CONFERENCE_TEST_HANDOFF_FIXTURE"] else { return }
        let preferences = UserDefaults(suiteName: "ContinuationUIFixture")!
        preferences.set(true, forKey: "shareActiveJams")
        let value = MeetingContinuationCoordinator(deviceID: "fixture-phone", deviceLabel: "iPhone", preferences: preferences,
                                                   transport: Cloud(sharing: mode == "sharing"), automatic: false)
        value.onJoinTarget = { [weak value] jam, _ in
            let id = UUID()
            Task { value?.targetDidConnect(invitation: jam.invitation, sessionID: id) }
            return id
        }
        value.onCancelTarget = { _, _ in true }
        model.installContinuationFixture(value)
        value.setCloudAccount("fixture-account")
    }
}
#else
@MainActor enum MeetingContinuationUIFixture { static func configure(_ model: ConferenceModel) {} }
#endif
