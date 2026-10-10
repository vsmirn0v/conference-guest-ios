import ConferenceCore
import SwiftUI
import UIKit

struct CameraReactionSettings: View {
    @ObservedObject var model: MeetingReactionsModel
    var body: some View {
        Toggle(L("Share camera reactions"), isOn: Binding(get: { model.shareCameraReactions }, set: model.setForwarding))
            .accessibilityIdentifier("reactions.camera-sharing")
        Text(model.cameraStatus.title).font(.footnote).foregroundStyle(.secondary)
            .accessibilityIdentifier("reactions.camera-status")
        Text(L("When your camera is shared, heart and thumbs effects send matching reactions. Confetti and fireworks send Celebrate. Other effects remain in your video."))
            .font(.footnote).foregroundStyle(.secondary)
    }
}

private struct ReactionPalette: View {
    @ObservedObject var model: MeetingReactionsModel
    @Environment(\.sizeCategory) private var sizeCategory
    let select: (MeetingReaction) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeCategory.isAccessibilityCategory ? 120 : 64), spacing: 4)], spacing: 12) {
            ForEach(model.supportedReactions, id: \.self) { kind in
                Button { select(kind) } label: {
                    VStack(spacing: 6) {
                        Text(kind.emoji).font(.system(size: 28))
                        Text(kind.title).font(.caption).multilineTextAlignment(.center)
                            .lineLimit(sizeCategory.isAccessibilityCategory ? nil : 2)
                    }.frame(minWidth: 44, maxWidth: .infinity, minHeight: 66).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!model.canSend)
                    .accessibilityLabel(kind.title).accessibilityHint(L("Send reaction"))
                    .accessibilityIdentifier("reactions.send.\(kind.rawValue)")
            }
        }
        if !model.canSend {
            Text(model.available ? L("Reactions will be ready when the meeting reconnects.") : L("Reactions are unavailable in this meeting."))
                .font(.footnote).foregroundStyle(.secondary)
        } else if let submitted = model.submitted {
            Text(L("Sent %@", submitted.title)).font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("reactions.confirmation")
        }
    }
}

private struct MeetingActionRows: View {
    let elements: [UIMenuElement]
    let perform: (UIAction) -> Void
    var body: some View {
        ForEach(Array(elements.enumerated()), id: \.offset) { _, element in
            if let action = element as? UIAction, !action.attributes.contains(.hidden) {
                Button { perform(action) } label: {
                    HStack {
                        if let image = action.image { Image(uiImage: image).frame(width: 24) }
                        Text(action.title)
                        Spacer()
                        if action.state == .on { Image(systemName: "checkmark") }
                    }
                }.disabled(action.attributes.contains(.disabled))
            } else if let menu = element as? UIMenu {
                if menu.options.contains(.displayInline) {
                    MeetingActionRows(elements: menu.children, perform: perform)
                } else {
                    DisclosureGroup(menu.title) { MeetingActionRows(elements: menu.children, perform: perform) }
                        .accessibilityIdentifier("meeting.menu.\(menu.identifier.rawValue)")
                }
            }
        }
    }
}

private struct MeetingActionsContent: View {
    @ObservedObject var model: MeetingReactionsModel
    let menu: UIMenu?
    let close: () -> Void
    let select: (MeetingReaction) -> Void
    let perform: (UIAction) -> Void
    let viewHistory: () -> Void
    var body: some View {
        NavigationStack {
            List {
                Section(L("Reactions")) {
                    ReactionPalette(model: model, select: select)
                    if model.onViewHistory != nil {
                        Button(L("View reaction history"), action: viewHistory)
                            .accessibilityIdentifier("reactions.history")
                    }
                }
                if model.available { Section { CameraReactionSettings(model: model) } }
                if let menu { Section(L("Meeting actions")) { MeetingActionRows(elements: menu.children, perform: perform) } }
            }.listStyle(.insetGrouped).navigationTitle(menu == nil ? L("Reactions") : L("More"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done"), action: close).accessibilityIdentifier("reactions.done") } }
        }.tint(Color(red: 1, green: 0.60, blue: 0.33))
            .onChange(of: model.generation) { _ in close() }
    }
}

@MainActor
final class MeetingActionsController: UIHostingController<AnyView>, UIPopoverPresentationControllerDelegate {
    private let model: MeetingReactionsModel
    init(model: MeetingReactionsModel, menu: UIMenu?) {
        self.model = model
        super.init(rootView: AnyView(EmptyView()))
        rootView = AnyView(MeetingActionsContent(model: model, menu: menu,
            close: { [weak self] in self?.dismiss(animated: true) },
            select: { [weak model] kind in
                guard model?.send(kind) == true else { return }
                UIAccessibility.post(notification: .announcement, argument: L("You, %@", kind.title))
                if !ProcessInfo.processInfo.isiOSAppOnMac { UISelectionFeedbackGenerator().selectionChanged() }
            }, perform: { [weak self] action in
                self?.dismiss(animated: true) {
                    // Execute an existing public UIAction through its native control.
                    let button = UIButton(primaryAction: action)
                    button.sendActions(for: .touchUpInside)
                }
            }, viewHistory: { [weak self, weak model] in
                guard let model else { return }
                let generation = model.generation
                self?.dismiss(animated: true) {
                    guard model.generation == generation else { return }
                    model.onViewHistory?()
                }
            }))
        #if DEBUG
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_REACTIONS_COMPACT_WIDTH"] == "320" {
            rootView = AnyView(rootView.frame(width: 320).accessibilityElement(children: .contain)
                .accessibilityIdentifier("reactions.compact-content"))
        }
        #endif
        preferredContentSize = CGSize(width: 480, height: menu == nil ? 480 : 600)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closePanel))]
    }
    @objc private func closePanel() { dismiss(animated: true) }
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }

    static func show(model: MeetingReactionsModel, menu: UIMenu?, from anchor: UIView) {
        var responder: UIResponder? = anchor
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard var host = responder as? UIViewController else { return }
        while let parent = host.parent { host = parent }
        guard host.presentedViewController == nil else { return }
        let controller = MeetingActionsController(model: model, menu: menu)
        let wide = host.view.bounds.width > host.view.bounds.height || host.traitCollection.userInterfaceIdiom == .pad
        if wide {
            controller.modalPresentationStyle = .popover
            controller.popoverPresentationController?.sourceView = anchor
            controller.popoverPresentationController?.sourceRect = anchor.bounds
            controller.popoverPresentationController?.delegate = controller
        } else {
            controller.modalPresentationStyle = .pageSheet
            controller.sheetPresentationController?.detents = [.medium(), .large()]
            controller.sheetPresentationController?.selectedDetentIdentifier = model.supportedReactions.count > 5 ? .large : .medium
            controller.sheetPresentationController?.prefersGrabberVisible = true
        }
        host.present(controller, animated: true)
    }
}
