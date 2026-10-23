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
        case .invite: return L("Invite people")
        case .meeting: return L("Meeting details")
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
    var detail: String? {
        switch self {
        case .cameraSound: return L("Private preview and effects")
        case .sharePresenter: return L("Screen, slides and camera")
        case .invite: return L("Link and sharing options")
        case .meeting: return L("Information and meeting controls")
        default: return nil
        }
    }
    func menu(_ children: [UIMenuElement]) -> UIMenu {
        UIMenu(title: title, image: UIImage(systemName: symbol), identifier: identifier, children: children)
    }
    static func make(cameraSound: [UIMenuElement], sharePresenter: [UIMenuElement],
                     view: [UIMenuElement], invite: [UIMenuElement], meeting: [UIMenuElement]) -> UIMenu {
        UIMenu(children: [Self.cameraSound.menu(cameraSound), Self.sharePresenter.menu(sharePresenter),
            Self.invite.menu(invite), Self.meeting.menu(meeting + view)])
    }
}

struct MeetingActionRows: View {
    let elements: [UIMenuElement]
    let perform: (UIAction) -> Void
    var body: some View {
        ForEach(Array(elements.enumerated()), id: \.offset) { _, element in
            if let action = element as? UIAction, !action.attributes.contains(.hidden) {
                Button { perform(action) } label: {
                    HStack(spacing: 12) {
                        if let image = action.image {
                            Image(uiImage: image).renderingMode(.template).foregroundStyle(Color.primary)
                                .frame(width: 24).accessibilityHidden(true)
                        }
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
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(menu.title)
                                if let detail = MeetingActionGroup.allCases.first(where: { $0.identifier == menu.identifier })?.detail {
                                    Text(detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            if let image = menu.image {
                                Image(uiImage: image).renderingMode(.template).foregroundStyle(Color.primary)
                                    .accessibilityHidden(true)
                            }
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
                    if let menu { MeetingActionRows(elements: menu.children, perform: perform) }
                } else {
                    Section { ReactionPalette(model: model, select: select) }
                    if let openChat {
                        Button(action: openChat) { Label(L("Open chat"), systemImage: "text.bubble").frame(minHeight: 44) }
                            .accessibilityIdentifier("reactions.chat")
                    }
                    Button { changePage(more: true) } label: {
                        Label(L("More"), systemImage: "ellipsis.circle").frame(minHeight: 44)
                    }.accessibilityIdentifier("meeting.actions.more")
                }
            }.listStyle(.insetGrouped).navigationTitle(showsMore ? L("More") : L("Reactions"))
                .accessibilityIdentifier("meeting.actions.list")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
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
    private var isCurrent: () -> Bool = { true }
    private weak var invokingAnchor: UIView?
    private weak var panelOwner: MeetingPanelOwner?
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
                guard let self, let model else { return }
                let generation = model.generation
                self.dismissAndPerform {
                    guard model.generation == generation else { return }
                    // Execute an existing public UIAction through its native control.
                    let button = UIButton(primaryAction: action)
                    button.sendActions(for: .touchUpInside)
                }
            }, openChat: openChat.map { callback in
                { [weak self, weak model] in
                    guard let self, let model else { return }
                    let generation = model.generation
                    self.dismissAndPerform {
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
    func dismissAndPerform(_ action: @escaping () -> Void) {
        let isCurrent = isCurrent
        guard isCurrent() else { return }
        dismiss(animated: true) {
            guard isCurrent() else { return }; action()
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onVisibilityChanged?(false)
        onVisibilityChanged = nil
        if panelOwner?.controller === self { panelOwner?.controller = nil }
        if let invokingAnchor, invokingAnchor.window != nil {
            UIAccessibility.post(notification: .layoutChanged, argument: invokingAnchor)
        }
    }
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }

    static func show(model: MeetingReactionsModel?, menu: UIMenu?, from anchor: UIView, startsWithMore: Bool = false, openChat: (() -> Void)? = nil, owner: MeetingPanelOwner? = nil, onVisibilityChanged: ((Bool) -> Void)? = nil) {
        let controller = MeetingActionsController(model: model, menu: menu, startsWithMore: startsWithMore, openChat: openChat)
        present(controller, from: anchor, owner: owner, onVisibilityChanged: onVisibilityChanged)
    }

    static func showView(state: MeetingViewState, from anchor: UIView, owner: MeetingPanelOwner,
                         companionActions: [UIMenuElement] = [],
                         chooseLayout: @escaping (MeetingLayoutMode) -> Void,
                         chooseDisplay: @escaping (ConferenceDisplayMode) -> Void,
                         followSpeaker: @escaping () -> Void, onVisibilityChanged: @escaping (Bool) -> Void) {
        let controller = MeetingActionsController(model: nil, menu: nil)
        let perform: (@escaping () -> Void) -> Void = { [weak controller] action in
            guard let controller else { return }
            controller.dismissAndPerform(action)
        }
        controller.rootView = AnyView(MeetingViewContent(state: state,
            companionActions: companionActions, performAction: { action in perform { UIButton(primaryAction: action).sendActions(for: .touchUpInside) } },
            close: { [weak controller] in controller?.dismiss(animated: true) },
            chooseLayout: { mode in guard state.permitsLayout else { return }; perform { chooseLayout(mode) } },
            chooseDisplay: { mode in perform { chooseDisplay(mode) } }, followSpeaker: { perform(followSpeaker) }))
        controller.preferredContentSize = CGSize(width: 380, height: state.manualFocus ? 680 : 600)
        present(controller, from: anchor, owner: owner, onVisibilityChanged: onVisibilityChanged)
    }

    private static func present(_ controller: MeetingActionsController, from anchor: UIView,
                                owner: MeetingPanelOwner?, onVisibilityChanged: ((Bool) -> Void)?) {
        var responder: UIResponder? = anchor
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard var host = responder as? UIViewController else { return }
        while let parent = host.parent { host = parent }
        guard host.presentedViewController == nil else { return }
        guard anchor.window != nil, owner?.controller == nil, owner?.retired != true else { return }
        controller.invokingAnchor = anchor
        if let owner {
            controller.isCurrent = owner.validity(from: anchor)
            controller.panelOwner = owner; owner.controller = controller
        }
        let wide = host.view.bounds.width >= 600 && !host.traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        if wide {
            controller.modalPresentationStyle = .popover
            controller.popoverPresentationController?.sourceView = anchor
            controller.popoverPresentationController?.sourceRect = anchor.bounds
            controller.popoverPresentationController?.delegate = controller
            controller.popoverPresentationController?.passthroughViews = nil
        } else {
            controller.modalPresentationStyle = .pageSheet
            let compact = UISheetPresentationController.Detent.Identifier("reactions.compact")
            let height = max(520, controller.preferredContentSize.height)
            controller.sheetPresentationController?.detents = [.custom(identifier: compact) { min($0.maximumDetentValue, height) }, .large()]
            controller.sheetPresentationController?.selectedDetentIdentifier = host.traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .large : compact
            controller.sheetPresentationController?.prefersGrabberVisible = true
            controller.sheetPresentationController?.prefersEdgeAttachedInCompactHeight = true
        }
        controller.onVisibilityChanged = onVisibilityChanged
        onVisibilityChanged?(true)
        host.present(controller, animated: true)
    }
}
