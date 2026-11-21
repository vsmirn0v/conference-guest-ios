import Foundation
import os

private let outputLock = NSLock()
private let stdoutQueue = DispatchQueue(label: "RockNRoll.ProbeLog.stdout", qos: .utility)
private let systemLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "RockNRoll", category: "guest")
/// Recent events for Copy Diagnostics: memory only, bounded, guarded by outputLock.
nonisolated(unsafe) private var history: [String] = []
private let historyCapacity = 400
/// Keep-alives would push every useful event out of the bounded history.
private let historySkipped: Set<String> = ["rtc-pong"]
/// Receives each kept line in order; copied under outputLock and invoked outside the lock.
nonisolated(unsafe) private var sink: ((String) -> Void)?
nonisolated(unsafe) private var sinkEvents: Set<String>?

public func setProbeLogSink(events: Set<String>? = nil, _ value: ((String) -> Void)?) {
    outputLock.lock(); defer { outputLock.unlock() }
    sink = value
    sinkEvents = events
}

/// Diagnostic allowlisted fields only. Callers must never pass SDP, ICE or credentials.
/// Events also reach the unified system log, so release builds can be diagnosed.
public func probeLog(_ event: String, _ fields: [String: Any] = [:]) {
    var value = fields
    value["event"] = event
    value["uptime"] = ProcessInfo.processInfo.systemUptime
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else { return }
    systemLog.log("\(line, privacy: .public)")
    let activeSink: ((String) -> Void)?
    outputLock.lock()
    if !historySkipped.contains(event) {
        history.append(line)
        if history.count > historyCapacity { history.removeFirst(history.count - historyCapacity) }
        activeSink = sinkEvents?.contains(event) != false ? sink : nil
    } else {
        activeSink = nil
    }
    outputLock.unlock()
    activeSink?(line)
    stdoutQueue.async {
        var lineData = data
        lineData.append(10)
        try? FileHandle.standardOutput.write(contentsOf: lineData)
    }
}

/// `value` with anything JSON cannot hold replaced: non-finite numbers become -1 and
/// other types their description, so a diagnostic event built from live state is
/// never dropped by `probeLog`'s validity check.
public func probeSafe(_ value: Any) -> Any {
    switch value {
    case let dictionary as [String: Any]: return dictionary.mapValues(probeSafe)
    case let array as [Any]: return array.map(probeSafe)
    case let number as Double: return number.isFinite ? number : -1
    case let number as Float: return number.isFinite ? Double(number) : -1
    case is String, is Int, is Bool, is NSNull, is Int64, is UInt64, is Int32, is UInt32: return value
    case let number as NSNumber: return number.doubleValue.isFinite ? number : -1
    default: return String(describing: value)
    }
}

/// Oldest first.
public func probeLogHistory() -> [String] {
    outputLock.lock(); defer { outputLock.unlock() }
    return history
}
