import AVFoundation
import SwiftUI

struct SoundCheckControls: View {
    @ObservedObject var model: StudioModel
    @ObservedObject private var check: PrivateSoundCheck
    var compact = false
    init(model: StudioModel, compact: Bool = false) {
        self.model = model; self.check = model.soundCheck; self.compact = compact
    }
    var body: some View {
        Section(L("Microphone input")) {
            VStack(alignment: .leading, spacing: 8) {
            MicrophoneLevelStrip(activity: model.microphoneOn ? model.microphoneActivity : check.activity)
            Text(AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? L("Microphone"))
                .font(.caption).foregroundStyle(.secondary)
            if model.microphoneOn {
                Label(L("Microphone is live"), systemImage: "mic.fill")
            } else {
                Label(L("Private check · Only you"), systemImage: "lock.fill")
                    .accessibilityIdentifier("studio.sound-check-status")
                if check.state == .starting { ProgressView(L("Preparing microphone…")) }
                Button(check.capturing ? L("Stop private check") : L("Test microphone")) {
                    if check.capturing { check.stop() } else { model.testMicrophone() }
                }.buttonStyle(.borderless).accessibilityIdentifier(check.capturing ? "studio.stop-sound-check" : "studio.test-microphone")
                if !compact {
                    Text(L("Your meeting microphone stays muted. Nothing from this check is sent to the jam."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !compact {
                Text(L("Input activity shows your microphone capture, not confirmation that others can hear you."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error = check.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("studio.sound-check-error") }
            }
        }.disabled(model.held || !model.active)
        .onAppear {
            // An already-authorized muted input can be previewed privately. Never
            // mute a live meeting merely because its settings were opened.
            if !model.microphoneOn && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { model.testMicrophone() }
        }
    }
}

struct MicrophoneLevelStrip: View {
    @ObservedObject var activity: MicrophoneActivity
    var body: some View {
        HStack(spacing: 10) {
            MicrophoneGlyph(activity: activity).frame(width: 22, height: 30)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(LinearGradient(colors: [.orange, Color(red: 1, green: 0.93, blue: 0.74)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geometry.size.width * activity.level)
                }
            }.frame(height: 8)
        }.frame(height: 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Microphone input"))
        .accessibilityValue(activity.hasSignal ? (activity.level > 0.12 ? L("Input detected") : L("Quiet")) : L("Waiting for input"))
        .accessibilityIdentifier("studio.microphone-meter")
    }
}
private struct MicrophoneGlyph: UIViewRepresentable {
    let activity: MicrophoneActivity
    func makeUIView(context: Context) -> MicrophoneActivityView { let view = MicrophoneActivityView(); view.bind(activity); return view }
    func updateUIView(_ uiView: MicrophoneActivityView, context: Context) {}
}
