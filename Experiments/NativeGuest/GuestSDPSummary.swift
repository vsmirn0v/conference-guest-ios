import Foundation

/// Formal SDP diagnostics, restricted to codec/feedback capabilities. Never log
/// whole descriptions, ICE, fingerprints, identifiers or arbitrary fmtp values.
enum GuestSDPSummary {
    static func video(_ sdp: String) -> [[String: Any]] {
        var sections: [[String: Any]] = []
        var current: [String: Any]?
        var codecs: [String: String] = [:]
        var feedback: [String: Set<String>] = [:]
        var repair: [String: Int] = [:]
        var parameters: [String: [String: String]] = [:]
        func finish() {
            guard var section = current else { return }
            section["codecs"] = codecs
            section["feedback"] = feedback.mapValues { $0.sorted() }
            section["repairPayloads"] = repair
            section["codecParameters"] = parameters
            sections.append(section)
        }
        for line in sdp.components(separatedBy: .newlines) where !line.isEmpty {
            if line.hasPrefix("m=") {
                finish(); current = line.hasPrefix("m=video ") ? [:] : nil
                codecs = [:]; feedback = [:]; repair = [:]; parameters = [:]
            }
            guard current != nil else { continue }
            if line.hasPrefix("a=rtpmap:") {
                let fields = line.dropFirst(9).split(separator: " ")
                guard fields.count == 2, let payload = Int(fields[0]), (0...127).contains(payload),
                      let codec = fields[1].split(separator: "/").first?.lowercased(),
                      ["h264", "h265", "vp8", "vp9", "av1", "rtx", "red", "ulpfec", "flexfec-03"].contains(codec) else { continue }
                codecs[String(payload)] = codec
            } else if line.hasPrefix("a=rtcp-fb:") {
                let fields = line.dropFirst(10).split(separator: " ")
                guard fields.count >= 2, fields[0] == "*" || Int(fields[0]).map({ (0...127).contains($0) }) == true else { continue }
                let capability = fields.dropFirst().joined(separator: " ")
                guard ["nack", "nack pli", "ccm fir", "goog-remb", "transport-cc"].contains(capability) else { continue }
                feedback[String(fields[0]), default: []].insert(capability)
            } else if line == "a=rtcp-rsize" { current?["reducedSizeRTCP"] = true
            } else if line.hasPrefix("a=fmtp:") {
                let fields = line.dropFirst(7).split(separator: " ", maxSplits: 1)
                guard fields.count == 2, let payload = Int(fields[0]), (0...127).contains(payload) else { continue }
                for parameter in fields[1].split(separator: ";") {
                    let pair = parameter.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                    if pair.count == 2 {
                        let key = String(pair[0]), value = String(pair[1])
                        if key == "profile-level-id", value.count == 6, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) {
                            parameters[String(payload), default: [:]][key] = value
                        } else if ["packetization-mode", "level-asymmetry-allowed"].contains(key), ["0", "1"].contains(value) {
                            parameters[String(payload), default: [:]][key] = value
                        }
                    }
                    if pair.count == 2, pair[0] == "apt", let original = Int(pair[1]), (0...127).contains(original) { repair[String(payload)] = original }
                }
            }
        }
        finish()
        return sections
    }
}
