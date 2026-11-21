import Foundation
import Darwin
private let allowed: Set<String> = ["guest-connected", "publishing", "prototype-pass", "prototype-failed", "engine-stopped"]
func setProbeLogSink(_ value: ((String) -> Void)?) {}
func probeLog(_ event: String, _ fields: [String: Any] = [:]) {
    guard allowed.contains(event), let text = ProcessInfo.processInfo.environment["P0_EVENT_FD"],
          let fd = Int32(text), fd >= 3 else { return }
    let bytes = Array((event + "\n").utf8)
    bytes.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        _ = Darwin.write(fd, base, raw.count)
    }
}
func probeSafe(_ value: Any) -> Any { value }
func probeLogHistory() -> [String] { [] }
