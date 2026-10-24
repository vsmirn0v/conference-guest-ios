import Foundation

private let outputLock = NSLock()

/// Diagnostic allowlisted fields only. Callers must never pass SDP, ICE or credentials.
func probeLog(_ event: String, _ fields: [String: Any] = [:]) {
    var value = fields
    value["event"] = event
    value["uptime"] = ProcessInfo.processInfo.systemUptime
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
    outputLock.lock(); defer { outputLock.unlock() }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}
