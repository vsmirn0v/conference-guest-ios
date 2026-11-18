import Foundation

func CoreL(_ key: String) -> String {
    Bundle.module.localizedString(forKey: key, value: key, table: nil)
}
