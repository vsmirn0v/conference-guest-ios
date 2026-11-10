// Both sender getters are extracted verbatim; SDK objects below are instrumented inputs.
import Foundation
private final class Track {
    let kind: String; var isEnabled: Bool
    init(_ kind: String, _ enabled: Bool) { self.kind = kind; isEnabled = enabled }
}
private struct Encoding { let isActive: Bool }
private struct Parameters { let encodings: [Encoding] }
private final class Sender {
    var track: Track?; var parameterReads = 0; let active: [Bool]
    init(_ track: Track?, _ active: [Bool]) { self.track = track; self.active = active }
    var parameters: Parameters { parameterReads += 1; return Parameters(encodings: active.map { Encoding(isActive: $0) }) }
}
private final class Connection { var senders: [Sender] = [] }
private struct Publisher { let connection: Connection }
private final class NativeGuestEngine {
    var publisher: Publisher?
    var maximumAudioSenderTrackQueryForTesting: [String: Any] = [:]
// @production senderTrackFlags
// @production senderFullInventory
}
@main private struct Tests {
    static func main() {
        let engine = NativeGuestEngine()
        precondition(engine.audioSenderTrackEnabledForTesting.isEmpty)
        let connection = Connection(); engine.publisher = Publisher(connection: connection)
        precondition(engine.audioSenderTrackEnabledForTesting.isEmpty)
        let audio = Sender(Track("audio", false), [true, false])
        let video = Sender(Track("video", true), [true])
        let noTrack = Sender(nil, [true])
        let enabledAudio = Sender(Track("audio", true), [false, true])
        connection.senders = [video, audio, noTrack, enabledAudio]
        precondition(engine.audioSenderTrackEnabledForTesting == [false, true])
        precondition(connection.senders.allSatisfy { $0.parameterReads == 0 })
        let full = engine.audioSendersForTesting
        precondition(full.map { $0.trackEnabled } == [false, true])
        precondition(full.map { $0.encodingActive } == [[true, false], [false, true]])
        precondition(audio.parameterReads == 1 && enabledAudio.parameterReads == 1)
        precondition(video.parameterReads == 0 && noTrack.parameterReads == 0)
        audio.track?.isEnabled = true; connection.senders = [audio]
        precondition(engine.audioSenderTrackEnabledForTesting == [true])
        connection.senders = [Sender(Track("audio", false), [])]
        precondition(engine.audioSenderTrackEnabledForTesting == [false])
        precondition(connection.senders[0].parameterReads == 0)
        precondition(engine.maximumAudioSenderTrackQueryForTesting["encodingParametersQueried"] as? Bool == false)
        print("PASS actual sender getters: nil/empty/mixed/live inventory; track flags equivalent; new query never reads parameters; full encoding flags retained")
    }
}
