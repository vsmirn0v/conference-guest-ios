import AVFoundation
import AVKit
import Combine
import SwiftUI
import UIKit

struct StudioPanel: View {
    @ObservedObject var model: StudioModel
    @ObservedObject private var soundCheck: PrivateSoundCheck
    var onDismiss: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var compact = false
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(model: StudioModel, onDismiss: (() -> Void)? = nil) {
        self.model = model; self.soundCheck = model.soundCheck; self.onDismiss = onDismiss
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(L("Camera & sound"), selection: $model.pane) {
                    Text(L("Camera")).tag(StudioModel.Pane.camera)
                    Text(L("Sound")).tag(StudioModel.Pane.sound)
                    if model.presenter.available { Text(L("Presenter")).tag(StudioModel.Pane.presenter) }
                }
                .pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 8)
                .accessibilityIdentifier("studio.panes")
                Form {
                    switch model.pane {
                    case .camera: cameraControls
                    case .sound: soundControls
                    case .presenter: PresenterControls(model: model.presenter)
                    }
                    if model.held || !model.active {
                        Section { Text(model.active ? L("Sound controls are paused while the meeting is on hold.") : L("The meeting has ended.")) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.active && !model.held {
                    VStack(spacing: 8) {
                        if model.pane == .camera && !model.cameraOn && !model.presenter.running && model.enableCamera != nil {
                            Text(L("Nothing is sent until you start video."))
                                .font(.footnote).foregroundStyle(.secondary)
                            Button {
                                Task { _ = await model.startVideo() }
                            } label: {
                                HStack {
                                    if model.startingVideo { ProgressView() }
                                    Text(L("Start video"))
                                }.frame(maxWidth: .infinity, minHeight: 36)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.startingVideo || model.previewLoading)
                            .accessibilityIdentifier("studio.start-video")
                        } else if model.pane == .sound && !model.microphoneOn && model.enableMicrophone != nil {
                            Button {
                                guard model.active, !model.held else { return }
                                model.releasePrivateMicrophone(); model.enableMicrophone?(); model.close()
                            } label: { Text(L("Unmute microphone")).frame(maxWidth: .infinity, minHeight: 36) }
                            .buttonStyle(.borderedProminent).disabled(model.applying)
                            .accessibilityIdentifier("studio.unmute")
                        } else if model.pane == .presenter {
                            PresenterShareControl(model: model.presenter)
                        }
                    }.padding(.horizontal).padding(.vertical, 10).background(.regularMaterial)
                }
            }
            .navigationTitle(model.pane == .presenter ? L("Share") : L("Camera & sound"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(L("Done")) { model.close() }.accessibilityIdentifier("studio.done")
            } }
            .onAppear { model.refreshSystemSelection() }
            .onChange(of: model.presented) { if !$0 { if let onDismiss { onDismiss() } else { dismiss() } } }
            .onReceive(refresh) { _ in model.refreshSystemSelection() }
            .background(GeometryReader { size in
                Color.clear.onAppear { compact = size.size.height < 500 }
                    .onChange(of: size.size) { compact = $0.height < 500 }
            })
        }.tint(Color(red: 1, green: 0.60, blue: 0.33))
    }

    private var cameraControls: some View {
        Group {
            if model.presenter.running {
                Section {
                    Text(L("Your camera is controlled by Presenter while the canvas is shared."))
                    Button(L("Open Presenter")) { model.pane = .presenter }
                    Button(L("Camera effects")) { model.showSystemSettings(.videoEffects) }
                        .disabled(!model.systemSettingsAvailable || model.presenter.cameraDevice == nil)
                    ForEach(model.cameraEffects.filter { $0.state != .unavailable }) { effect in
                        LabeledContent(effect.title, value: effect.value).font(.footnote)
                    }
                }
            } else {
            Section {
                ZStack(alignment: .topLeading) {
                    Color.black
                    if let view = model.previewView { StudioPreviewSurface(view: view) }
                    if model.previewLoading { ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    if let error = model.previewError {
                        VStack(spacing: 12) {
                            Image(systemName: "video.slash").font(.title)
                            Text(error).multilineTextAlignment(.center)
                            Button(L("Try again")) { model.open(.camera) }
                        }.foregroundStyle(.white).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Label(model.cameraOn ? L("Live · Visible to jam") : L("Preview · Only you"),
                          systemImage: model.cameraOn ? "video.fill" : "lock.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(8).background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                        .padding(8)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(model.cameraOn ? L("Live · Visible to jam") : L("Preview · Only you"))
                        .accessibilityIdentifier("studio.preview-status")
                }
                .frame(height: compact ? 88 : 180).clipShape(RoundedRectangle(cornerRadius: 12))
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                if model.cameraOn && model.flipLiveCamera != nil {
                    Button { model.flipCamera() } label: { Label(L("Flip camera"), systemImage: "camera.rotate") }
                        .disabled(model.held).accessibilityIdentifier("studio.flip-camera")
                }
                Button { model.showSystemSettings(.videoEffects) } label: {
                    Label(L("Camera effects"), systemImage: "camera.filters")
                }
                .accessibilityIdentifier("studio.camera-effects")
                .disabled(!model.systemSettingsAvailable || !(model.cameraOn || model.previewRunning))
                ForEach(model.cameraEffects.filter { $0.state != .unavailable }) { effect in
                    LabeledContent(effect.title, value: effect.value).font(.footnote)
                }
                if !compact {
                    Text(L("Use system controls for background blur, lighting and framing supported by your camera."))
                        .font(.footnote).foregroundStyle(.secondary)
                    if !model.cameraOn {
                        Text(L("Closing this preview keeps video off."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            }
        }
    }

    private var soundControls: some View {
        Group {
        SoundCheckControls(model: model, compact: compact)
        Section {
            Label(model.microphoneOn ? L("Microphone is live") : L("Muted in jam"),
                  systemImage: model.microphoneOn ? "mic.fill" : "mic.slash.fill")
            Picker(L("Sound profile"), selection: Binding(get: { model.profile }, set: { model.select($0) })) {
                ForEach(StudioAudioProfile.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).accessibilityIdentifier("studio.sound-profile")
            .disabled(!model.active || model.held || model.applying || model.applyProfile == nil)
            HStack {
                Label(L("Audio devices"), systemImage: "headphones")
                Spacer()
                StudioAudioRouteControl().frame(width: 44, height: 44)
            }
            Text(compact ? L("Conversation reduces noise. Music keeps more detail.") : model.audioExplanation)
                .font(.footnote).foregroundStyle(.secondary)
            if let suppression = model.observedNoiseSuppression {
                LabeledContent(L("Noise suppression"), value: suppression ? L("On") : L("Off")).font(.footnote)
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
            .disabled(!model.systemSettingsAvailable || !(model.microphoneOn || model.soundCheck.capturing))
            if model.microphoneOn || model.soundCheck.capturing {
                LabeledContent(L("System microphone mode"), value: model.systemMicrophoneMode).font(.footnote)
            }
            if model.profile == .music {
                Text(L("For music, choose Standard or Wide Spectrum in system microphone settings when available."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        }
    }
}

struct StudioPreviewSurface: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ host: UIView, context: Context) {
        if view.superview !== host {
            host.subviews.forEach { $0.removeFromSuperview() }
            host.addSubview(view)
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        view.frame = host.bounds
    }
}

private struct StudioAudioRouteControl: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        if ProcessInfo.processInfo.isiOSAppOnMac { return MacAudioRouteButton() }
        let picker = AVRoutePickerView()
        picker.tintColor = UIColor(red: 1, green: 0.60, blue: 0.33, alpha: 1)
        picker.accessibilityLabel = L("Choose audio output")
        return picker
    }
    func updateUIView(_ view: UIView, context: Context) {}
}

@MainActor
private final class StudioHostingController: UIHostingController<StudioPanel>, UIViewControllerTransitioningDelegate {
    private let model: StudioModel
    init(model: StudioModel) {
        self.model = model
        super.init(rootView: StudioPanel(model: model))
        rootView = StudioPanel(model: model, onDismiss: { [weak self] in self?.dismiss(animated: true) })
        modalPresentationStyle = .custom
        transitioningDelegate = self
    }
    @MainActor required dynamic init?(coder: NSCoder) { nil }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { model.close() }
    }
    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
        StudioSheet(presentedViewController: presented, presenting: presenting)
    }
    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        StudioTransition(presenting: true)
    }
    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        StudioTransition(presenting: false)
    }
}

private final class StudioTransition: NSObject, UIViewControllerAnimatedTransitioning {
    private let presenting: Bool
    init(presenting: Bool) { self.presenting = presenting }
    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval { 0.18 }
    func animateTransition(using context: UIViewControllerContextTransitioning) {
        guard let controller = context.viewController(forKey: presenting ? .to : .from),
              let view = context.view(forKey: presenting ? .to : .from) else {
            context.completeTransition(false); return
        }
        if presenting {
            view.frame = context.finalFrame(for: controller)
            view.alpha = 0
            context.containerView.addSubview(view)
        }
        UIView.animate(withDuration: transitionDuration(using: context), animations: {
            view.alpha = self.presenting ? 1 : 0
        }) { _ in context.completeTransition(!context.transitionWasCancelled) }
    }
}

private final class StudioSheet: UIPresentationController {
    private let dim = UIView()
    override var frameOfPresentedViewInContainerView: CGRect {
        guard let bounds = containerView?.bounds else { return .zero }
        let side = bounds.width > bounds.height && bounds.width >= 600
        if side {
            let width = min(400, bounds.width * 0.48)
            return CGRect(x: bounds.maxX - width, y: 0, width: width, height: bounds.height)
        }
        let width = min(bounds.width, 520)
        let height = min(bounds.height * 0.9, 740)
        return CGRect(x: (bounds.width - width) / 2, y: bounds.maxY - height, width: width, height: height)
    }
    override func presentationTransitionWillBegin() {
        guard let containerView else { return }
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(close)))
        containerView.insertSubview(dim, at: 0)
        dim.frame = containerView.bounds
        presentedView?.layer.cornerRadius = 18
        presentedView?.clipsToBounds = true
        presentedView?.accessibilityViewIsModal = true
    }
    override func containerViewWillLayoutSubviews() {
        dim.frame = containerView?.bounds ?? .zero
        presentedView?.frame = frameOfPresentedViewInContainerView
    }
    @objc private func close() { presentedViewController.dismiss(animated: true) }
}

@MainActor
enum StudioPresentation {
    static func show(_ model: StudioModel, from view: UIView, pane: StudioModel.Pane = .camera) {
        var responder: UIResponder? = view
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard var presenter = responder as? UIViewController else { return }
        while let parent = presenter.parent { presenter = parent }
        guard presenter.presentedViewController == nil else { return }
        model.open(pane)
        presenter.present(StudioHostingController(model: model), animated: true)
    }
}
