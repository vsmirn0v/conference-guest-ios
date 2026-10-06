import SwiftUI

struct SoundCheckControls: View {
    @ObservedObject var model: StudioModel
    var compact = false
    var body: some View {
        SoundCheckContent(check: model.soundCheck, live: model.microphoneActivity,
                          microphoneOn: model.microphoneOn, compact: compact, held: model.held || !model.active,
                          start: { model.testMicrophone() })
    }
}
private struct SoundCheckContent: View {
    @ObservedObject var check: PrivateSoundCheck
    @ObservedObject var live: MicrophoneActivity
    let microphoneOn: Bool
    let compact: Bool
    let held: Bool
    let start: () -> Void
    var body: some View {
        Section {
            if check.state == .idle || check.state == .failed {
                if microphoneOn {
                    MicrophoneLevelStrip(activity: live)
                    Text(L("Input activity shows your microphone capture, not confirmation that others can hear you."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button(action: start) {
                    Label(microphoneOn ? L("Mute and test microphone") : L("Test microphone"), systemImage: "waveform")
                }.accessibilityIdentifier("studio.test-microphone").disabled(held)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label(L("Private check · Only you"), systemImage: "lock.fill").font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("studio.sound-check-status")
                    if !compact {
                        Text(L("Your meeting microphone stays muted. Nothing from this check is sent to the jam."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if check.state == .starting { ProgressView(L("Preparing microphone…")) }
                    if check.state == .listening || check.state == .recording {
                        MicrophoneLevelStrip(activity: check.activity)
                        Text(AVAudioRouteName.input).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        if check.state == .recording {
                            ProgressView(L("Recording a 5-second sample…"))
                        } else if check.state == .listening {
                            Button(L("Record 5 seconds")) { check.record() }.accessibilityIdentifier("studio.record-sample")
                        } else if check.state == .sampleReady {
                            Button { check.play() } label: { Label(L("Play my sample"), systemImage: "play.fill") }
                                .accessibilityIdentifier("studio.play-sample")
                        } else if check.state == .playing {
                            ProgressView(L("Playing your sample…"))
                        }
                        Spacer(minLength: 0)
                        Button(L("Stop private check")) { check.stop() }.accessibilityIdentifier("studio.stop-sound-check")
                    }.buttonStyle(.borderless)
                    if !compact && check.state == .listening {
                        Text(L("This checks your input. Meeting sound processing may differ.")).font(.footnote).foregroundStyle(.secondary)
                    }
                    if check.state == .sampleReady {
                        if !compact {
                            Text(L("The sample is kept only in memory and removed when you close this panel."))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Button(L("Test again"), action: start).buttonStyle(.borderless)
                    }
                }.padding(.vertical, 4)
            }
            if let error = check.error { Text(error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("studio.sound-check-error") }
        }.disabled(held)
    }
}
private struct MicrophoneLevelStrip: View {
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

import AVFoundation
private enum AVAudioRouteName {
    static var input: String { AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? L("Microphone") }
}
