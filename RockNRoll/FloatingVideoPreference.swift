import Foundation

enum FloatingVideoPreference {
    private static let key = "floatingVideoWhenMultitasking"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
