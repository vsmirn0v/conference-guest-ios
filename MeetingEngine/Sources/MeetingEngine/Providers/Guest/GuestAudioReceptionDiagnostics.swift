import Foundation

/// A receive window for one Guest subscriber. Raw WebRTC identifiers are used
/// only to match counters across polls and never leave this object.
struct GuestAudioReceptionDiagnostics {
    private struct Receiver {
        var number = 0
        let track: String
        let timestamp: Double
        let packets: Int64
        let lost: Int64?
        let concealed: Int64?
        let concealmentEvents: Int64?
        let jitter: Double?
        let speaking: Bool

        init?(_ row: [String: Any], audibleTracks: Set<String>, speakingTracks: Set<String>) {
            guard row["type"] as? String == "inbound-rtp", row["kind"] as? String == "audio",
                  let track = row["trackIdentifier"] as? String, audibleTracks.contains(track),
                  let time = row["nativeTimestampUS"] as? NSNumber,
                  let received = row["packetsReceived"] as? NSNumber else { return nil }
            self.track = track
            speaking = speakingTracks.contains(track)
            timestamp = time.doubleValue
            packets = received.int64Value
            lost = (row["packetsLost"] as? NSNumber)?.int64Value
            concealed = (row["concealedSamples"] as? NSNumber)?.int64Value
            concealmentEvents = (row["concealmentEvents"] as? NSNumber)?.int64Value
            jitter = (row["jitter"] as? NSNumber)?.doubleValue
        }
    }

    private var receivers: [String: Receiver] = [:]
    private var nextNumber = 1
    private var previousPoll: TimeInterval?
    private var previousDecoded = GuestAudioSnapshot()
    private var previousOutput: GuestStartupAudioCallback?
    private var previousOutputNonSilent: Int?
    private var lastStates: [String] = []
    private var lastLog = -Double.infinity

    func due(at now: TimeInterval) -> Bool { previousPoll.map { now - $0 >= 2 } ?? true }

    mutating func observe(at now: TimeInterval, rows: [[String: Any]]?, audibleTracks: Set<String>,
                          connected: Bool, soundOn: Bool, gateOpen: Bool, expectsAudio: Bool, speakingTracks: Set<String>,
                          decoded: GuestAudioSnapshot, output: GuestStartupAudioCallback, outputNonSilent: Int?) -> [String: Any]? {
        let interval = previousPoll.map { now - $0 }
        // Following sleep, reconnect or an unavailable sample, establish fresh baselines.
        let continuous = interval.map { $0 > 0 && $0 <= 6 } == true
        var current: [String: Receiver] = [:]
        var compared = 0, advancing = 0, lossy = 0, concealedStreams = 0, speakingWithoutPackets = 0
        var packets: Int64 = 0, lost: Int64 = 0, concealed: Int64 = 0, concealmentEvents: Int64 = 0
        var lossCoverage = 0, concealmentCoverage = 0, eventCoverage = 0
        var maxJitter: Double?
        var affected: [[String: Int64]] = []
        for row in rows ?? [] {
            guard let id = row["id"] as? String, var receiver = Receiver(row, audibleTracks: audibleTracks, speakingTracks: speakingTracks) else { continue }
            if let old = receivers[id], old.track == receiver.track {
                receiver.number = old.number
            } else {
                receiver.number = nextNumber
                nextNumber += 1
            }
            current[id] = receiver
            guard continuous, let old = receivers[id], old.track == receiver.track,
                  receiver.timestamp > old.timestamp, receiver.packets >= old.packets else { continue }
            compared += 1
            var symptoms: [String: Int64] = [:]
            if let jitter = receiver.jitter, jitter.isFinite && jitter >= 0 {
                maxJitter = max(maxJitter ?? 0, jitter)
            }
            packets += receiver.packets - old.packets
            if receiver.packets > old.packets { advancing += 1 }
            else if old.speaking && receiver.speaking {
                speakingWithoutPackets += 1
                symptoms["speakingWithoutPackets"] = 1
            }
            if let a = old.lost, let b = receiver.lost {
                lossCoverage += 1
                if b > a { lost += b - a; lossy += 1; symptoms["packetsLostIncrease"] = b - a }
            }
            if let a = old.concealed, let b = receiver.concealed, b >= a {
                concealmentCoverage += 1
                concealed += b - a
                if b > a { concealedStreams += 1; symptoms["concealedSamples"] = b - a }
            }
            if let a = old.concealmentEvents, let b = receiver.concealmentEvents, b >= a {
                eventCoverage += 1
                concealmentEvents += b - a
            }
            if !symptoms.isEmpty {
                symptoms["stream"] = Int64(receiver.number)
                symptoms["packetsReceived"] = receiver.packets - old.packets
                affected.append(symptoms)
            }
        }

        let rtp: String
        if !connected { rtp = "transport-disconnected" }
        else if !soundOn { rtp = "sound-off" }
        else if !gateOpen { rtp = "playout-gated" }
        else if !expectsAudio { rtp = "no-audible-publication" }
        else if rows == nil { rtp = "stats-unavailable" }
        else if audibleTracks.isEmpty { rtp = "awaiting-receiver" }
        else if compared == 0 { rtp = current.isEmpty ? "no-matching-stats" : "baseline" }
        else if lossy > 0 { rtp = "packet-loss" }
        else if concealedStreams > 0 { rtp = "concealment" }
        else if advancing == 0 { rtp = "no-packet-progress" }
        else { rtp = "receiving" }

        let listening = connected && soundOn && gateOpen && expectsAudio
        let outputState: String
        if !listening { outputState = "not-expected" }
        else if output.uptime <= 0 { outputState = "unobserved" }
        else if now - output.uptime > output.freshness { outputState = "callback-stale" }
        else if continuous, let previousPoll, output.lastGapEnd > previousPoll { outputState = "callback-gap" }
        else { outputState = "callbacks-current" }

        let oldOutput = previousOutput
        let oldOutputNonSilent = previousOutputNonSilent
        let pcm = decoded.since(previousDecoded)
        let mixed: Int? = if continuous, let oldOutputNonSilent, let outputNonSilent, outputNonSilent >= oldOutputNonSilent {
            outputNonSilent - oldOutputNonSilent
        } else { nil }
        previousDecoded = decoded
        previousOutput = output
        previousOutputNonSilent = outputNonSilent
        receivers = current
        previousPoll = now
        let pcmState: String
        if !listening || !continuous { pcmState = "unobserved" }
        else if pcm.callbacks == 0 { pcmState = "no-decoded-callbacks" }
        else if pcm.nonSilentCallbacks == 0 { pcmState = "decoded-quiet" }
        else if mixed == 0 { pcmState = "decoded-energy-with-quiet-output" }
        else { pcmState = "decoded-energy" }
        let states = [rtp, pcmState, outputState]
        let anomaly = listening && (lossy > 0 || concealedStreams > 0 || outputState == "callback-gap" ||
            speakingWithoutPackets > 0)
        guard anomaly || states != lastStates || now - lastLog >= 30 else { return nil }
        lastStates = states
        lastLog = now
        var fields: [String: Any] = [
            "rtp": rtp, "decodedPCM": pcmState, "outputTap": outputState, "transportConnected": connected,
            "soundOn": soundOn, "gateOpen": gateOpen, "expectsAudio": expectsAudio,
            "speakingReceiverTracks": speakingTracks.count, "speakingStreamsWithoutPackets": speakingWithoutPackets,
            "audibleReceiverTracks": audibleTracks.count,
            "matchedStreams": current.count, "comparedStreams": compared, "advancingStreams": advancing
        ]
        if continuous, let interval {
            fields["windowSeconds"] = interval
            fields["decodedCallbacks"] = pcm.callbacks
            fields["decodedNonSilentCallbacks"] = pcm.nonSilentCallbacks
            if let oldOutput, output.count >= oldOutput.count { fields["outputCallbacks"] = output.count - oldOutput.count }
            fields["outputNonSilentCallbacks"] = mixed
        }
        if output.uptime > 0 { fields["outputCallbackAgeMs"] = max(0, now - output.uptime) * 1000 }
        if outputState == "callback-gap" { fields["outputCallbackGapMs"] = output.lastGapSeconds * 1000 }
        if compared > 0 { fields["packetsReceived"] = packets }
        if lossCoverage > 0 { fields["packetsLostIncrease"] = lost; fields["lossyStreams"] = lossy }
        if concealmentCoverage > 0 { fields["concealedSamples"] = concealed; fields["concealedStreams"] = concealedStreams }
        if eventCoverage > 0 { fields["concealmentEvents"] = concealmentEvents }
        if let maxJitter { fields["maxJitterMs"] = maxJitter * 1000 }
        if !affected.isEmpty {
            fields["affectedStreams"] = affected.count
            fields["streamDetails"] = Array(affected.sorted { ($0["stream"] ?? 0) < ($1["stream"] ?? 0) }.prefix(8))
        }
        return fields
    }
}
