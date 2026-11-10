import Foundation

@main
struct StartupTransportReadinessTests {
    enum Failure: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            switch self { case .message(let text): return text }
        }
    }

    static func main() throws {
        var checks = 0
        func check(_ actual: Bool, _ message: String) throws {
            checks += 1
            guard actual else { throw Failure.message(message) }
        }
        let pair: [String: Any] = ["type": "candidate-pair", "id": "pair1"]
        let transport: [String: Any] = [
            "type": "transport", "id": "transport1", "dtlsState": "connected",
            "iceState": "connected", "selectedCandidatePairId": "pair1", "bytesReceived": 100
        ]
        func summary(_ rows: [[String: Any]]) -> [String: Any] {
            ["statsAvailable": true, "rows": rows]
        }
        func ready(_ rows: [[String: Any]]) -> Bool {
            StartupTransportReadiness.confirmed(summary(rows))
        }
        try check(ready([pair, transport]), "connected transport is admitted")
        try check(ready([transport, pair]), "stats row order is irrelevant")
        var completed = transport
        completed["iceState"] = "completed"
        try check(ready([pair, completed]), "completed ICE is admitted")
        try check(!StartupTransportReadiness.confirmed([:]), "missing stats fail closed")
        for invalid: Any in [false, "true", NSNull()] {
            var value = summary([pair, transport])
            value["statsAvailable"] = invalid
            try check(!StartupTransportReadiness.confirmed(value), "invalid availability fails: \(invalid)")
        }
        var missingAvailability = summary([pair, transport])
        missingAvailability.removeValue(forKey: "statsAvailable")
        try check(!StartupTransportReadiness.confirmed(missingAvailability), "availability is required")
        for rows: Any in [NSNull(), "rows", ["type": "transport"], [42]] {
            try check(!StartupTransportReadiness.confirmed(["statsAvailable": true, "rows": rows]),
                      "malformed rows fail: \(rows)")
        }
        try check(!StartupTransportReadiness.confirmed(["statsAvailable": true]), "rows are required")
        try check(!ready([]), "empty rows fail")
        try check(!ready([pair]), "pair alone fails")
        try check(!ready([transport]), "selected pair must exist")
        try check(!ready([["id": "pair1"], transport]), "selected pair must have candidate-pair type")
        try check(!ready([["type": "candidate-pair"], transport]), "selected pair needs its id")
        try check(!ready([["type": "candidate-pair", "id": 1], transport]), "pair id must be a string")
        for key in ["type", "dtlsState", "iceState", "selectedCandidatePairId", "bytesReceived"] {
            var invalid = transport
            invalid.removeValue(forKey: key)
            try check(!ready([pair, invalid]), "missing transport \(key) fails")
            invalid[key] = NSNull()
            try check(!ready([pair, invalid]), "null transport \(key) fails")
        }
        for (key, values) in [
            ("dtlsState", ["new", "connecting", "failed", "closed", "Connected", ""]),
            ("iceState", ["new", "checking", "disconnected", "failed", "closed", "Connected", ""]),
            ("selectedCandidatePairId", ["", "unknown"])
        ] {
            for value in values {
                var invalid = transport
                invalid[key] = value
                try check(!ready([pair, invalid]), "unready \(key)=\(value) fails")
            }
        }
        for key in ["dtlsState", "iceState", "selectedCandidatePairId"] {
            var invalid = transport
            invalid[key] = 1
            try check(!ready([pair, invalid]), "non-string \(key) fails")
        }
        for bytes: Any in [0, -0.0, -1, Double.nan, Double.infinity, -Double.infinity, "100", NSNull()] {
            var invalid = transport
            invalid["bytesReceived"] = bytes
            try check(!ready([pair, invalid]), "invalid received bytes fail: \(bytes)")
        }
        for bytes in [Double.leastNonzeroMagnitude, 0.5, Double.greatestFiniteMagnitude] {
            var valid = transport
            valid["bytesReceived"] = bytes
            try check(ready([pair, valid]), "finite positive received bytes pass: \(bytes)")
        }
        let pair2: [String: Any] = ["type": "candidate-pair", "id": "pair2"]
        var second = completed
        second["id"] = "transport2"
        second["selectedCandidatePairId"] = "pair2"
        try check(ready([pair, transport, pair2, second]), "every connected transport may pass")
        try check(!ready([pair, transport, second]), "a partially resolved transport set fails")
        for key in ["dtlsState", "iceState", "selectedCandidatePairId", "bytesReceived"] {
            var invalid = second
            invalid.removeValue(forKey: key)
            try check(!ready([pair, transport, pair2, invalid]), "partial transport missing \(key) fails")
            try check(!ready([pair2, invalid, pair, transport]), "partial transport fails in either order")
        }
        second["dtlsState"] = "connecting"
        try check(!ready([pair, transport, pair2, second]), "partially connected transports fail")
        try check(ready([pair, transport, ["type": "codec", "id": "codec1"]]), "unrelated stats are ignored")

        func bracket(_ times: [Double]) -> Bool {
            StartupTransportReadiness.queryBracketsConfirmed(
                publisherStarted: times[0], publisherCompleted: times[1],
                receiverStarted: times[2], receiverCompleted: times[3], baselineCompleted: times[4])
        }
        let ordered = [1.0, 1.025, 1.05, 1.075, 1.1]
        try check(bracket(ordered), "ordered recent query brackets pass")
        try check(bracket([1, 1, 1, 1, 1]), "equal query timestamps are allowed")
        try check(bracket([1, 1.025, 1.05, 1.075, 1.25.nextDown]), "age immediately below 250ms passes")
        try check(!bracket([1, 1.025, 1.05, 1.075, 1.25]), "250ms boundary fails")
        try check(!bracket([1, 1.025, 1.05, 1.075, 1.25.nextUp]), "age above 250ms fails")
        try check(!bracket([1, 1.2, 1.21, 1.39, 1.4]), "slow reads plus lag fail")
        try check(!bracket([1, 1.01, 1.02, 1.3, 1.31]), "old receiver observation fails")
        try check(!bracket([1, 1.3, 1.31, 1.32, 1.33]), "old publisher observation fails")
        for index in ordered.indices {
            for invalid in [0.0, -0.0, -1, Double.nan, Double.infinity, -Double.infinity] {
                var times = ordered
                times[index] = invalid
                try check(!bracket(times), "invalid timestamp \(index)=\(invalid) fails")
            }
        }
        for index in 0..<ordered.count - 1 {
            var reversed = ordered
            reversed.swapAt(index, index + 1)
            try check(!bracket(reversed), "reversed adjacent timestamps \(index)/\(index + 1) fail")
        }

        // Private historical logs are optional. Default execution is synthetic only.
        var replayed = 0
        let arguments = Array(CommandLine.arguments.dropFirst())
        if !arguments.isEmpty {
            guard arguments.count == 2, arguments[0] == "--replay-dir" else {
                throw Failure.message("Usage: run-startup-transport.sh [--replay-dir PATH]")
            }
            for (label, expected) in [
                ("AIR-COLD-vpio-baseline-1", true),
                ("AIR-COLD-vpio-baseline-2", true),
                ("AIR-COLD-vpio-baseline-3", false)
            ] {
                let file = URL(fileURLWithPath: arguments[1]).appendingPathComponent("\(label).jsonl")
                let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
                var baselines = 0
                for line in lines {
                    guard let event = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                        throw Failure.message("Invalid event in \(file.path)")
                    }
                    guard event["event"] as? String == "micStartupStage",
                          event["phase"] as? String == "baseline" else { continue }
                    guard let publisher = event["publisher"] as? [String: Any],
                          let receiver = event["receiver"] as? [String: Any],
                          let subscriber = receiver["subscriber"] as? [String: Any],
                          let action = event["actionStart"] as? Double,
                          let age = event["publisherBaselineAgeAtActionSeconds"] as? Double,
                          let start = event["baselineStartedUptime"] as? Double,
                          let receiverStart = receiver["sampleStartedUptime"] as? Double,
                          let receiverEnd = receiver["sampleCompletedUptime"] as? Double,
                          let end = event["baselineCompletedUptime"] as? Double else {
                        throw Failure.message("Missing baseline fields in \(file.path)")
                    }
                    try check(StartupTransportReadiness.confirmed(publisher), "replayed publisher connected")
                    try check(StartupTransportReadiness.confirmed(subscriber) == expected,
                              "replayed \(label) receiver admission = \(expected)")
                    // Older logs store completion as age at action, not native report age.
                    try check(bracket([start, action - age, receiverStart, receiverEnd, end]),
                              "replayed \(label) query brackets pass")
                    baselines += 1
                }
                try check(baselines == 3, "expected three baselines in \(file.path)")
                replayed += baselines
            }
        }
        print("PASS \(checks) transport admission checks; historical baselines replayed: \(replayed)")
    }
}
