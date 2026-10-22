import Foundation

enum FloatingVideoPreference {
    private static let key = "floatingVideoWhenMultitasking"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    #if DEBUG
    /// No release setting: iPhone scheduling/energy acceptance is pending.
    static var experimentalBackgroundStart: Bool {
        ProcessInfo.processInfo.environment["CONFERENCE_EXPERIMENT_BACKGROUND_PIP"] == "1" ||
            UserDefaults.standard.bool(forKey: "experiments.firstBackgroundPiP")
    }
    #endif
}
