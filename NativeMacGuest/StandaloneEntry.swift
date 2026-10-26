import Foundation

/// An explicit companion launch may never fall back to manual admission.
enum NativeGuestLaunchMode: Equatable {
    case automatic, standalone, companion(UUID)

    static func parse(_ arguments: [String]) throws -> Self {
        let sessions = arguments.indices.filter { arguments[$0] == "--session" }
        let standalone = arguments.filter { $0 == "--standalone" }.count
        guard sessions.count <= 1, standalone <= 1, sessions.isEmpty || standalone == 0 else {
            throw NativeGuestEntryError.invalidLaunch
        }
        if let index = sessions.first {
            guard arguments.indices.contains(index + 1), let id = UUID(uuidString: arguments[index + 1]) else {
                throw NativeGuestEntryError.invalidLaunch
            }
            return .companion(id)
        }
        return standalone == 1 ? .standalone : .automatic
    }
}

enum NativeGuestEntryError: Error {
    case invalidLaunch, invalidName, invalidInvitation

    var message: String {
        switch self {
        case .invalidLaunch: return "The companion launch request is invalid. Join again from Rock’n’Roll."
        case .invalidName: return "Enter a short display name on one line."
        case .invalidInvitation: return "Enter a valid HTTPS guest invitation URL."
        }
    }
}

/// A manual join is local input, never an admitted app-group ticket.
struct NativeGuestJoinRequest: Equatable {
    let invitation: GuestInvitation
    let displayName: String

    static func parse(invitation: String, displayName: String) throws -> Self {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 512,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw NativeGuestEntryError.invalidName
        }
        guard let parsed = try? GuestInvitation.parse(invitation) else { throw NativeGuestEntryError.invalidInvitation }
        return Self(invitation: parsed, displayName: name)
    }
}

enum NativeGuestMeetingCompletion: Equatable {
    case left, failed, cleanupFailed

    var permitsRejoin: Bool { self != .cleanupFailed }
    var message: String {
        switch self {
        case .left: return "You left the meeting. Join again whenever you’re ready."
        case .failed: return "Could not connect. Check the invitation and network, then try again."
        case .cleanupFailed: return "Media could not stop cleanly. Quit and reopen Rock'N'Roll for Mac before joining again."
        }
    }
}
