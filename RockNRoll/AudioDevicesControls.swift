import AVFoundation
import AVKit
import Combine
import SwiftUI

@MainActor
final class AudioDeviceSelection: ObservableObject {
    @Published private(set) var inputName = ""
    @Published private(set) var outputName = ""
    @Published private(set) var inputs: [AVAudioSessionPortDescription] = []
    @Published private(set) var mac = MacAudioSnapshot()
    @Published private(set) var error: String?
    private var subscriptions = Set<AnyCancellable>()
    private var observations: [NSObjectProtocol] = []
    let isMac = ProcessInfo.processInfo.isiOSAppOnMac
    init() {
        if isMac {
            MacAudioDevices.shared.$snapshot.sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        }
        for name in [AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }
    deinit { observations.forEach(NotificationCenter.default.removeObserver) }
    func refresh() {
        let session = AVAudioSession.sharedInstance()
        inputs = session.availableInputs ?? []
        if isMac {
            mac = MacAudioDevices.shared.snapshot
            inputName = mac.devices.first { $0.id == mac.inputID }?.name ?? L("No microphones available")
            outputName = mac.outputName ?? L("No output devices available")
        } else {
            inputName = session.currentRoute.inputs.first?.portName ?? L("Automatic")
            outputName = session.currentRoute.outputs.first?.portName ?? L("Automatic")
        }
    }
    func selectInput(_ uid: String?) {
        let session = AVAudioSession.sharedInstance()
        do {
            let port = uid.flatMap { id in session.availableInputs?.first { $0.uid == id } }
            guard uid == nil || port != nil else { refresh(); return }
            try session.setPreferredInput(port)
            error = nil; refresh()
        } catch { self.error = L("Could not change audio device. Please try again.") }
    }
    func selectMac(_ id: UInt32, _ direction: MacAudioDirection) {
        do { try MacAudioDevices.shared.select(id, for: direction); error = nil; refresh() }
        catch { self.error = L("Could not change audio device. Please try again.") }
    }
}

struct AudioDevicesControls: View {
    @ObservedObject var studio: StudioModel
    @StateObject private var devices = AudioDeviceSelection()
    @StateObject private var speaker = SpeakerCheck()
    var body: some View {
        Section(L("Output")) {
            Text(devices.outputName).accessibilityIdentifier("studio.output-device")
            if devices.isMac {
                Menu(L("Change output")) {
                    ForEach(devices.mac.devices(for: .output), id: \.id) { device in
                        Button(device.name) { devices.selectMac(device.id, .output) }
                    }
                }
            } else {
                HStack {
                    Text(L("Change output"))
                    Spacer()
                    AudioOutputPicker().frame(width: 44, height: 44)
                }
            }
            Button { studio.releasePrivateMicrophone(); speaker.play(standalone: studio.enableMicrophone == nil) } label: {
                Label(speaker.playing ? L("Playing test sound…") : L("Test speaker"), systemImage: "speaker.wave.2")
            }.disabled(speaker.playing).accessibilityIdentifier("studio.test-speaker")
            if let error = speaker.error { Text(error).foregroundStyle(.red) }
        }
        Section(L("Microphone")) {
            Text(devices.inputName).accessibilityIdentifier("studio.input-device")
            if devices.isMac {
                Menu(L("Change microphone")) {
                    ForEach(devices.mac.devices(for: .input), id: \.id) { device in
                        Button(device.name) { devices.selectMac(device.id, .input) }
                    }
                }
            } else {
                Menu(L("Change microphone")) {
                    Button(L("Automatic")) { devices.selectInput(nil) }
                    ForEach(devices.inputs, id: \.uid) { port in
                        Button(port.portName) { devices.selectInput(port.uid) }
                    }
                }.disabled(devices.inputs.isEmpty)
                Text(L("Bluetooth call headsets can link microphone and output selection. iOS chooses the supported combination."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if studio.microphoneOn { MicrophoneLevelStrip(activity: studio.microphoneActivity) }
            Button(L("Microphone levels and effects")) { studio.audioSection = .sound }
        }
        Section {
            if devices.isMac {
                Text(L("Selections change your Mac’s system audio devices for other apps too."))
            } else {
                Text(L("For compatible headphone Audio Sharing, use the system output controls in Control Center. Availability depends on the active call route."))
            }
            if let error = devices.error { Text(error).foregroundStyle(.red) }
        }.font(.footnote).foregroundStyle(.secondary)
        .disabled(studio.held || !studio.active)
        .onChange(of: studio.held) { if $0 { speaker.stop() } }
        .onChange(of: studio.active) { if !$0 { speaker.stop() } }
        .onDisappear { speaker.stop() }
    }
}

private struct AudioOutputPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(); view.tintColor = .systemOrange
        view.accessibilityLabel = L("Choose audio output"); return view
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

/// A brief generated sound; never captures microphone or stores media.
@MainActor
final class SpeakerCheck: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playing = false
    @Published private(set) var error: String?
    private var player: AVAudioPlayer?
    private var standalone = false
    func play(standalone: Bool) {
        stop(); error = nil
        do {
            if standalone {
                try AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
                try AVAudioSession.sharedInstance().setActive(true)
                self.standalone = true
            }
            let player = try AVAudioPlayer(data: Self.tone())
            self.player = player; player.delegate = self
            guard player.play() else { throw SoundCheckError.input }
            playing = true
        } catch { stop(); self.error = L("Cannot play the test sound. Check your output device.") }
    }
    func stop() {
        player?.stop(); player = nil; playing = false
        if standalone {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            standalone = false
        }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in guard self?.player === player else { return }; self?.stop() }
    }
    static func tone() -> Data {
        let rate = 16_000, count = 6_400
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); word(UInt32(36 + count * 2)); data.append(contentsOf: "WAVEfmt ".utf8)
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(rate)); word(UInt32(rate * 2))
        word(UInt16(2)); word(UInt16(16)); data.append(contentsOf: "data".utf8); word(UInt32(count * 2))
        for i in 0..<count {
            let envelope = min(1, Double(min(i, count - i)) / 320)
            word(Int16(sin(Double(i) * 2 * .pi * 660 / Double(rate)) * envelope * 5_000))
        }
        return data
    }
}
