import Foundation

enum NativeRTCError: LocalizedError {
    case invalidResponse, disconnected
    var errorDescription: String? { L("Could not connect to the meeting. Check the invitation and your network.") }
}
