import ConferenceCore
import SwiftUI
import UIKit
import ObjectiveC

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
        if model.available {
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
        }
        if !model.canSend {
            Text(model.available ? L("Reactions will be ready when the meeting reconnects.") : L("Reactions are unavailable in this meeting."))
                .font(.footnote).foregroundStyle(.secondary)
        } else if let feedback = model.feedback {
            Text(feedback.title).font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("reactions.confirmation")
        }
    }
}

/// Actions launched from an inspector may originate on the call toolbar while
/// Chat remains presented above it. Resolve its current visible host at execution
/// time, after the transient sender has dismissed, without recreating Chat.
@MainActor
extension UIView {
    var callActionPresenter: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard var host = responder as? UIViewController else { return nil }
        while let parent = host.parent { host = parent }
        while let presented = host.presentedViewController, !presented.isBeingDismissed { host = presented }
        return host
    }
    var callActionPresentationAnchor: UIView {
        guard let host = callActionPresenter else { return self }
        return isDescendant(of: host.view) ? self : host.view
    }
}

/// The same fixed hierarchy is used by both call renderers. Transport-specific
/// actions remain owned by the call that creates them.
enum MeetingActionGroup: String, CaseIterable {
    case reactions, cameraSound, sharePresenter, view, invite, meeting
    var title: String {
        switch self {
        case .reactions: return L("Reactions")
        case .cameraSound: return L("Camera & sound")
        case .sharePresenter: return L("Share & Presenter")
        case .view: return L("View")
        case .invite: return L("Invite")
        case .meeting: return L("Meeting")
        }
    }
    var symbol: String {
        switch self {
        case .reactions: return "face.smiling"
        case .cameraSound: return "slider.horizontal.3"
        case .sharePresenter: return "rectangle.on.rectangle"
        case .view: return "rectangle.grid.2x2"
        case .invite: return "square.and.arrow.up"
        case .meeting: return "info.circle"
        }
    }
    var identifier: UIMenu.Identifier { UIMenu.Identifier("call.group.\(rawValue)") }
    func menu(_ children: [UIMenuElement]) -> UIMenu {
        UIMenu(title: title, image: UIImage(systemName: symbol), identifier: identifier, children: children)
    }
    static func make(cameraSound: [UIMenuElement], sharePresenter: [UIMenuElement],
                     view: [UIMenuElement], invite: [UIMenuElement], meeting: [UIMenuElement]) -> UIMenu {
        UIMenu(children: [Self.cameraSound.menu(cameraSound), Self.sharePresenter.menu(sharePresenter),
            Self.view.menu(view), Self.invite.menu(invite), Self.meeting.menu(meeting)])
    }
}

private struct MeetingActionRows: View {
    let elements: [UIMenuElement]
    let perform: (UIAction) -> Void
    var body: some View {
        ForEach(Array(elements.enumerated()), id: \.offset) { _, element in
            if let action = element as? UIAction, !action.attributes.contains(.hidden) {
                Button { perform(action) } label: {
                    HStack(spacing: 12) {
                        if let image = action.image { Image(uiImage: image).frame(width: 24) }
                        Text(action.title).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        if action.state == .on { Image(systemName: "checkmark") }
                    }.frame(minHeight: 44)
                }.disabled(action.attributes.contains(.disabled))
            } else if let menu = element as? UIMenu {
                if menu.options.contains(.displayInline) {
                    Section(menu.title) { MeetingActionRows(elements: menu.children, perform: perform) }
                } else {
                    NavigationLink {
                        List { MeetingActionRows(elements: menu.children, perform: perform) }
                            .listStyle(.insetGrouped).navigationTitle(menu.title)
                            .accessibilityIdentifier("meeting.actions.list")
                    } label: {
                        Label { Text(menu.title) } icon: {
                            if let image = menu.image { Image(uiImage: image) }
                        }.frame(minHeight: 44)
                    }.accessibilityIdentifier("meeting.menu.\(menu.identifier.rawValue)")
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
    let openChat: (() -> Void)?
    @State private var showsMore: Bool
    @State private var navigationID = UUID()
    init(model: MeetingReactionsModel, menu: UIMenu?, startsWithMore: Bool,
         close: @escaping () -> Void, select: @escaping (MeetingReaction) -> Void,
         perform: @escaping (UIAction) -> Void, openChat: (() -> Void)?) {
        self.model = model; self.menu = menu; self.close = close; self.select = select
        self.perform = perform; self.openChat = openChat
        _showsMore = State(initialValue: startsWithMore)
    }
    var body: some View {
        NavigationStack {
            List {
                if showsMore {
                    Button { changePage(more: false) } label: {
                        Label(L("Reactions"), systemImage: MeetingActionGroup.reactions.symbol).frame(minHeight: 44)
                    }.accessibilityIdentifier("meeting.more.reactions")
                    if let menu { MeetingActionRows(elements: menu.children, perform: perform) }
                } else {
                    Section { ReactionPalette(model: model, select: select) }
                    if let openChat {
                        Button(action: openChat) { Label(L("Open chat"), systemImage: "text.bubble").frame(minHeight: 44) }
                            .accessibilityIdentifier("reactions.chat")
                    }
                    Button { changePage(more: true) } label: {
                        Label(L("More"), systemImage: "ellipsis.circle").frame(minHeight: 44)
                    }.accessibilityIdentifier("call.more")
                }
            }.listStyle(.insetGrouped).navigationTitle(showsMore ? L("More") : L("Reactions"))
                .accessibilityIdentifier("meeting.actions.list")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if showsMore {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button { changePage(more: false) } label: { Image(systemName: "chevron.left") }
                                .accessibilityLabel(L("Reactions"))
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("Done"), action: close).accessibilityIdentifier("reactions.done")
                    }
                }
        }.id(navigationID).tint(Color(red: 1, green: 0.60, blue: 0.33))
            .onChange(of: model.generation) { _ in close() }
    }
    private func changePage(more: Bool) {
        showsMore = more
        // Replace the root rather than pushing another copy of the sender.
        navigationID = UUID()
    }
}

/// Holding the dock button consumes its release, just like the Studio shortcuts.
/// The visible More row remains the discoverable route for touch and VoiceOver.
@MainActor
final class MeetingActionsShortcut: NSObject {
    private static var association: UInt8 = 0
    private let show: () -> Void
    private init(show: @escaping () -> Void) { self.show = show }
    static func install(on button: UIButton, show: @escaping () -> Void) {
        let shortcut = MeetingActionsShortcut(show: show)
        objc_setAssociatedObject(button, &association, shortcut, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let hold = UILongPressGestureRecognizer(target: shortcut, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.45
        hold.cancelsTouchesInView = true
        hold.allowableMovement = 12
        button.addGestureRecognizer(hold)
        let secondary = UITapGestureRecognizer(target: shortcut, action: #selector(open))
        secondary.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        secondary.buttonMaskRequired = .secondary
        button.addGestureRecognizer(secondary)
        button.showsLargeContentViewer = false
        button.accessibilityHint = L("Touch and hold for more call options.")
        button.accessibilityCustomActions = [UIAccessibilityCustomAction(name: L("Open More options"), target: shortcut, selector: #selector(open))]
    }
    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        #if DEBUG
        if [.began, .ended, .cancelled].contains(gesture.state) {
            NSLog("MEETING_ACTIONS_HOLD state=%ld", gesture.state.rawValue)
        }
        #endif
        guard gesture.state == .began else { return }
        if !ProcessInfo.processInfo.isiOSAppOnMac { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        show()
    }
    @objc private func open() -> Bool { show(); return true }
}

@MainActor
final class MeetingActionsController: UIHostingController<AnyView>, UIPopoverPresentationControllerDelegate {
    private let model: MeetingReactionsModel
    private var onVisibilityChanged: ((Bool) -> Void)?
    init(model: MeetingReactionsModel?, menu: UIMenu?, startsWithMore: Bool = false, openChat: (() -> Void)? = nil) {
        let model = model ?? MeetingReactionsModel()
        self.model = model
        super.init(rootView: AnyView(EmptyView()))
        rootView = AnyView(MeetingActionsContent(model: model, menu: menu, startsWithMore: startsWithMore,
            close: { [weak self] in self?.dismiss(animated: true) },
            select: { [weak model] kind in
                guard model?.send(kind) == true else { return }
                UIAccessibility.post(notification: .announcement, argument: L("You, %@", kind.title))
                if !ProcessInfo.processInfo.isiOSAppOnMac { UISelectionFeedbackGenerator().selectionChanged() }
            }, perform: { [weak self, weak model] action in
                guard let model else { return }
                let generation = model.generation
                self?.dismiss(animated: true) {
                    guard model.generation == generation else { return }
                    // Execute an existing public UIAction through its native control.
                    let button = UIButton(primaryAction: action)
                    button.sendActions(for: .touchUpInside)
                }
            }, openChat: openChat.map { callback in
                { [weak self, weak model] in
                    guard let model else { return }
                    let generation = model.generation
                    self?.dismiss(animated: true) {
                        guard model.generation == generation else { return }
                        callback()
                    }
                }
            }))
        #if DEBUG
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_REACTIONS_COMPACT_WIDTH"] == "320" {
            rootView = AnyView(rootView.frame(width: 320).accessibilityElement(children: .contain)
                .accessibilityIdentifier("reactions.compact-content"))
        }
        #endif
        preferredContentSize = CGSize(width: 420, height: 480)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closePanel))]
    }
    @objc private func closePanel() { dismiss(animated: true) }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onVisibilityChanged?(false)
        onVisibilityChanged = nil
    }
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }

    static func show(model: MeetingReactionsModel?, menu: UIMenu?, from anchor: UIView, startsWithMore: Bool = false, openChat: (() -> Void)? = nil, onVisibilityChanged: ((Bool) -> Void)? = nil) {
        var responder: UIResponder? = anchor
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard var host = responder as? UIViewController else { return }
        while let parent = host.parent { host = parent }
        guard host.presentedViewController == nil else { return }
        let controller = MeetingActionsController(model: model, menu: menu, startsWithMore: startsWithMore, openChat: openChat)
        let wide = host.view.bounds.width > host.view.bounds.height || host.traitCollection.userInterfaceIdiom == .pad
        if wide {
            controller.modalPresentationStyle = .popover
            controller.popoverPresentationController?.sourceView = anchor
            controller.popoverPresentationController?.sourceRect = anchor.bounds
            controller.popoverPresentationController?.delegate = controller
        } else {
            controller.modalPresentationStyle = .pageSheet
            let compact = UISheetPresentationController.Detent.Identifier("reactions.compact")
            controller.sheetPresentationController?.detents = [.custom(identifier: compact) { min($0.maximumDetentValue, 520) }, .large()]
            controller.sheetPresentationController?.selectedDetentIdentifier = host.traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .large : compact
            controller.sheetPresentationController?.prefersGrabberVisible = true
        }
        controller.onVisibilityChanged = onVisibilityChanged
        onVisibilityChanged?(true)
        host.present(controller, animated: true)
    }
}
