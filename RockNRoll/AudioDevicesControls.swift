import AVFoundation
import AVKit
import Combine
import SwiftUI

@MainActor
final class AudioDeviceSelection: ObservableObject {
    @Published private(set) var inputName = ""
    @Published private(set) var outputName = ""
    @Published private(set) var inputs: [AVAudioSessionPortDescription] = []
    @Published private(set) var error: String?
    private let worker: AudioSessionWorker
    private var selectionLease: AudioSessionLease?
    private var observations: [NSObjectProtocol] = []
    init(worker: AudioSessionWorker = .shared) {
        self.worker = worker
        for name in [AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }
    deinit { selectionLease?.invalidate(); observations.forEach(NotificationCenter.default.removeObserver) }
    func refresh() {
        let session = AVAudioSession.sharedInstance()
        inputs = session.availableInputs ?? []
        inputName = session.currentRoute.inputs.first?.portName ?? L("Automatic")
        outputName = session.currentRoute.outputs.first?.portName ?? L("Automatic")
    }
    func cancelSelection() { selectionLease?.invalidate(); selectionLease = nil }
    func selectInput(_ uid: String?) {
        cancelSelection()
        let lease = AudioSessionLease(); selectionLease = lease
        worker.enqueue(lease: lease, operation: {
            let session = AVAudioSession.sharedInstance()
            let port = uid.flatMap { id in session.availableInputs?.first { $0.uid == id } }
            guard uid == nil || port != nil else { throw SoundCheckError.input }
            try session.setPreferredInput(port)
        }) { [weak self] result in
            Task { @MainActor in
                guard let self, self.selectionLease === lease, lease.isActive else { return }
                self.selectionLease = nil
                switch result {
                case .success: self.error = nil
                case .failure: self.error = L("Could not change audio device. Please try again.")
                }
                self.refresh()
            }
        }
    }
}

struct AudioDevicesControls: View {
    @ObservedObject var studio: StudioModel
    @StateObject private var devices = AudioDeviceSelection()
    @StateObject private var speaker = SpeakerCheck()
    var body: some View {
        Section(L("Output")) {
            Text(devices.outputName).accessibilityIdentifier("studio.output-device")
            HStack {
                Text(L("Change output"))
                Spacer()
                AudioOutputPicker().frame(width: 44, height: 44)
            }
            Button { studio.releasePrivateMicrophone(); speaker.play(standalone: studio.enableMicrophone == nil) } label: {
                Label(speaker.playing ? L("Playing test sound…") : L("Test speaker"), systemImage: "speaker.wave.2")
            }.disabled(speaker.playing).accessibilityIdentifier("studio.test-speaker")
            if let error = speaker.error { Text(error).foregroundStyle(.red) }
        }
        Section(L("Microphone")) {
            Text(devices.inputName).accessibilityIdentifier("studio.input-device")
            Menu(L("Change microphone")) {
                Button(L("Automatic")) { devices.selectInput(nil) }
                ForEach(devices.inputs, id: \.uid) { port in
                    Button(port.portName) { devices.selectInput(port.uid) }
                }
            }.disabled(devices.inputs.isEmpty)
            Text(L("Bluetooth call headsets can link microphone and output selection. iOS chooses the supported combination."))
                .font(.footnote).foregroundStyle(.secondary)
            if studio.microphoneOn { MicrophoneLevelStrip(activity: studio.microphoneActivity) }
            Button(L("Microphone levels and effects")) { studio.audioSection = .sound }
        }
        Section {
            Text(L("For compatible headphone Audio Sharing, use the system output controls in Control Center. Availability depends on the active call route."))
            if let error = devices.error { Text(error).foregroundStyle(.red) }
        }.font(.footnote).foregroundStyle(.secondary)
        .disabled(studio.held || !studio.active)
        .onChange(of: studio.held) { if $0 { speaker.stop(); devices.cancelSelection() } }
        .onChange(of: studio.active) { if !$0 { speaker.stop(); devices.cancelSelection() } }
        .onDisappear { speaker.stop(); devices.cancelSelection() }
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
    private let worker: AudioSessionWorker
    private var lease: AudioSessionLease?
    private var operation: Task<Void, Never>?
    init(worker: AudioSessionWorker = .shared) { self.worker = worker; super.init() }
    func play(standalone: Bool) {
        stop(); error = nil
        let expected = AudioSessionLease(); lease = expected
        self.standalone = standalone; playing = true
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                if standalone {
                    try await self.worker.perform(lease: expected) {
                        let session = AVAudioSession.sharedInstance()
                        try session.setCategory(.playback, options: .mixWithOthers)
                        try expected.check(); try session.setActive(true)
                    }
                }
                try Task.checkCancellation(); try expected.check()
                let player = try AVAudioPlayer(data: Self.tone())
                self.player = player; player.delegate = self
                guard player.play() else { throw SoundCheckError.input }
            } catch is CancellationError { }
            catch {
                guard self.lease === expected else { return }
                self.stop(); self.error = L("Cannot play the test sound. Check your output device.")
            }
        }
    }
    func stop() {
        lease?.invalidate(); lease = nil; operation?.cancel(); operation = nil
        player?.stop(); player = nil; playing = false
        if standalone { standalone = false; worker.deactivate() }
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
