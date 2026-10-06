import AVFoundation
import SwiftUI
import UIKit

struct StudioPanel: View {
    @ObservedObject var model: StudioModel
    @Environment(\.dismiss) private var dismiss
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { model.showSystemSettings(.videoEffects) } label: {
                        Label(L("Camera effects"), systemImage: "camera.filters")
                    }
                    .accessibilityIdentifier("studio.camera-effects")
                    .disabled(!model.systemSettingsAvailable || !model.cameraOn)
                    if model.cameraOn {
                        Text(L("Use system controls for background blur, lighting and framing supported by your camera."))
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text(L("Turn on video in the meeting to use camera effects."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text(L("Appearance")) }
                Section {
                    Picker(L("Sound profile"), selection: Binding(get: { model.profile }, set: { model.select($0) })) {
                        ForEach(StudioAudioProfile.allCases, id: \.self) { profile in
                            Text(profile.title).tag(profile)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("studio.sound-profile")
                    .disabled(!model.active || model.held || model.applying || model.applyProfile == nil)
                    Text(model.audioExplanation).font(.footnote).foregroundStyle(.secondary)
                    if let suppression = model.observedNoiseSuppression {
                        LabeledContent(L("Noise suppression"), value: suppression ? L("On") : L("Off"))
                            .font(.footnote)
                    }
                    if !model.microphoneOn {
                        Text(L("Your microphone stays muted. The profile is used when you unmute."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if model.applying { ProgressView(L("Updating sound…")) }
                    if let error = model.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("studio.error") }
                    Button { model.showSystemSettings(.microphoneModes) } label: {
                        Label(L("System microphone settings"), systemImage: "mic.badge.plus")
                    }
                    .accessibilityIdentifier("studio.microphone-settings")
                    .disabled(!model.systemSettingsAvailable || !model.microphoneOn)
                    if model.microphoneOn {
                        LabeledContent(L("System microphone mode"), value: model.systemMicrophoneMode).font(.footnote)
                    }
                    if model.profile == .music {
                        Text(L("For music, choose Standard or Wide Spectrum in system microphone settings when available."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text(L("Sound")) }
                if model.held || !model.active {
                    Section { Text(model.active ? L("Sound controls are paused while the meeting is on hold.") : L("The meeting has ended.")) }
                }
            }
            .navigationTitle(L("Studio"))
            .navigationBarTitleDisplayMode(.inline)
            .tint(Color(red: 1, green: 0.60, blue: 0.33))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() }.accessibilityIdentifier("studio.done") } }
            .onAppear { model.refreshSystemSelection() }
            .onReceive(refresh) { _ in model.refreshSystemSelection() }
        }
    }
}

@MainActor
enum StudioPresentation {
    static func show(_ model: StudioModel, from view: UIView) {
        var responder: UIResponder? = view
        while let current = responder, !(current is UIViewController) { responder = current.next }
        // SDK overlays may live in a zero-sized child: present from the visible call host.
        guard var presenter = responder as? UIViewController else { return }
        while let parent = presenter.parent { presenter = parent }
        guard presenter.presentedViewController == nil else { return }
        let panel = UIHostingController(rootView: StudioPanel(model: model))
        panel.modalPresentationStyle = .pageSheet
        panel.sheetPresentationController?.detents = [.medium(), .large()]
        panel.sheetPresentationController?.prefersGrabberVisible = true
        presenter.present(panel, animated: true)
    }
}
