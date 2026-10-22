import Foundation

enum FloatingVideoPreference {
    private static let key = "floatingVideoWhenMultitasking"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static var experimentalBackgroundStart: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CONFERENCE_EXPERIMENT_BACKGROUND_PIP"] == "1" { return true }
        #endif
        return !ProcessInfo.processInfo.isiOSAppOnMac &&
            UserDefaults.standard.bool(forKey: BackgroundExperimentPreferences.firstPiPKey)
    }
}

enum BackgroundExperimentPreferences {
    static let audioJoinKey = "experiments.backgroundAudioJoin"
    static let firstPiPKey = "experiments.firstBackgroundPiP"
    static let changed = Notification.Name("BackgroundMeetingExperimentsChanged")
}
