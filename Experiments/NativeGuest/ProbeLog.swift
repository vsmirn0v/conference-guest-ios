import Foundation
import os

private let outputLock = NSLock()
private let systemLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "RockNRoll", category: "guest")
/// Recent events for Copy Diagnostics: memory only, bounded, guarded by outputLock.
nonisolated(unsafe) private var history: [String] = []
private let historyCapacity = 400
/// Keep-alives would push every useful event out of the bounded history.
private let historySkipped: Set<String> = ["rtc-pong"]

/// Diagnostic allowlisted fields only. Callers must never pass SDP, ICE or credentials.
/// Events also reach the unified system log, so release builds can be diagnosed.
func probeLog(_ event: String, _ fields: [String: Any] = [:]) {
    var value = fields
    value["event"] = event
    value["uptime"] = ProcessInfo.processInfo.systemUptime
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else { return }
    systemLog.log("\(line, privacy: .public)")
    outputLock.lock(); defer { outputLock.unlock() }
    if !historySkipped.contains(event) {
        history.append(line)
        if history.count > historyCapacity { history.removeFirst(history.count - historyCapacity) }
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

/// Oldest first.
func probeLogHistory() -> [String] {
    outputLock.lock(); defer { outputLock.unlock() }
    return history
}
