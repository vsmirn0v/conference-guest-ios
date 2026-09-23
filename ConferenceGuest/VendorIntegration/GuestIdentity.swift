import Foundation
import JazzSDK

final class GuestIdentity: JazzUserNameService {
    let id: UUID
    private let lock = NSLock()
    private var currentName: String = "Guest"

    init() {
        let key = "anonymousGuestID"
        if let saved = UserDefaults.standard.string(forKey: key), let parsed = UUID(uuidString: saved) {
            id = parsed
        } else {
            let fresh = UUID()
            id = fresh
            UserDefaults.standard.set(fresh.uuidString, forKey: key)
        }
    }

    func setName(_ value: String) {
        lock.lock()
        currentName = value
        lock.unlock()
    }

    func userName() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return currentName
    }

    func userNameUpdated(newName: String) {
        setName(newName)
    }
}
