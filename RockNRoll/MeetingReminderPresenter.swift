import ConferenceCore
import UIKit

/// One nonmodal surface; the call's stage and toolbar geometry are never changed.
@MainActor final class MeetingReminderPresenter {
    private weak var host: MeetingReminderHost?
    private let overlay = ReminderPassthroughView()
    private let card = UIStackView()
    private let surface = MeetingChromeSurface(cornerRadius: 20)
    private let title = UILabel()
    private let time = UILabel()
    private let open = UIButton(type: .system)
    private let chip = UIButton(type: .system)
    private var events: [ReminderForegroundEvent] = []
    private var expandedID: String?
    private var expanded = false
    private var collapseTask: Task<Void, Never>?
    private var observations: [NSObjectProtocol] = []
    private weak var coordinator: CalendarReminderCoordinator?

    init() {
        overlay.overrideUserInterfaceStyle = .dark
        overlay.backgroundColor = .clear
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.accessibilityIdentifier = "reminders.overlay"
        overlay.addSubview(card); card.addSubview(surface); card.sendSubviewToBack(surface)
        card.axis = .vertical; card.spacing = 4
        card.isLayoutMarginsRelativeArrangement = true
        card.layoutMargins = .init(top: 8, left: 16, bottom: 8, right: 16)
        let heading = UILabel(); heading.text = L("Next meeting")
        heading.font = .preferredFont(forTextStyle: .caption1); heading.textColor = .secondaryLabel
        let collapse = button("chevron.down", L("Collapse reminder"), "reminders.collapse") { [weak self] in self?.setExpanded(false) }
        let skip = button("xmark", L("Dismiss reminders for this meeting"), "reminders.skip") { [weak self] in
            guard let self, let event = events.first else { return }
            Task { await self.coordinator?.action(reference: event.plan.reference, snooze: false) }
        }
        let top = UIStackView(arrangedSubviews: [heading, collapse, skip]); top.spacing = 4
        collapse.widthAnchor.constraint(equalToConstant: 44).isActive = true
        skip.widthAnchor.constraint(equalToConstant: 44).isActive = true
        top.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        title.font = .preferredFont(forTextStyle: .headline); title.numberOfLines = 0
        time.font = .preferredFont(forTextStyle: .footnote); time.numberOfLines = 0; time.textColor = .secondaryLabel
        [title, time, heading].forEach { $0.adjustsFontForContentSizeCategory = true }
        open.configuration = .plain(); open.configuration?.title = L("View meeting")
        open.accessibilityIdentifier = "reminders.view"
        open.addAction(UIAction { [weak self] _ in self?.openMeetings() }, for: .touchUpInside)
        let snooze = UIButton(type: .system); snooze.configuration = .plain(); snooze.configuration?.title = L("In 2 min")
        snooze.accessibilityIdentifier = "reminders.snooze"
        snooze.addAction(UIAction { [weak self] _ in
            guard let self, let event = events.first else { return }
            Task { await self.coordinator?.action(reference: event.plan.reference, snooze: true, scope: event.scope) }
        }, for: .touchUpInside)
        let actions = UIStackView(arrangedSubviews: [open, snooze]); actions.distribution = .fillEqually
        actions.accessibilityIdentifier = "reminders.actions"
        [open, snooze].forEach {
            $0.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            $0.titleLabel?.adjustsFontForContentSizeCategory = true
            $0.configuration?.titleLineBreakMode = .byWordWrapping
        }
        [top, title, time, actions].forEach(card.addArrangedSubview)
        chip.configuration = .plain(); chip.configuration?.image = UIImage(systemName: "calendar")
        chip.configuration?.imagePadding = 6
        chip.backgroundColor = MeetingChromeSurface.toolbarFallbackColor
        chip.layer.cornerRadius = 22; chip.accessibilityIdentifier = "reminders.chip"
        chip.addAction(UIAction { [weak self] _ in self?.setExpanded(true) }, for: .touchUpInside)
        overlay.addSubview(chip)
        overlay.onLayout = { [weak self] in self?.layout() }
        overlay.onEscape = { [weak self] in self?.setExpanded(false) }
        for name in [UIAccessibility.voiceOverStatusDidChangeNotification, UIContentSizeCategory.didChangeNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.layout(); self?.scheduleCollapse() }
            })
        }
    }
    deinit { collapseTask?.cancel(); observations.forEach(NotificationCenter.default.removeObserver) }

    private func button(_ symbol: String, _ label: String, _ id: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.accessibilityLabel = label; button.accessibilityIdentifier = id
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }
    @discardableResult func render(_ incoming: [ReminderForegroundEvent], host next: MeetingReminderHost?,
                                   coordinator: CalendarReminderCoordinator) -> Set<String> {
        self.coordinator = coordinator
        if host !== next {
            if host != nil { expanded = false }
            host?.onChange = nil; host?.collapseReminder = nil; host?.access?.setReminderBadge(0); host?.access?.reminderActions = []
            overlay.removeFromSuperview(); host = next
            next?.onChange = { [weak coordinator] in coordinator?.refreshPresentation() }
            next?.collapseReminder = { [weak self] in
                guard let self, self.expanded, !self.events.isEmpty else { return false }
                self.setExpanded(false); return true
            }
        }
        guard let next, let parent = next.surface, parent.window != nil, !incoming.isEmpty else {
            overlay.removeFromSuperview(); cancelCollapse(); events = []
            host?.access?.setReminderBadge(0); host?.access?.reminderActions = []
            return []
        }
        if next.interacting { cancelCollapse(); return [] }
        guard next.usable else { overlay.isHidden = true; cancelCollapse(); return [] }
        let first = incoming[0]
        let fresh = expandedID != first.id
        events = incoming
        if fresh {
            expandedID = first.id; expanded = !coordinator.wasPresented(first)
        }
        let privateCopy = !coordinator.profile.details || next.privateContent()
        let occurrence = coordinator.occurrence(for: first)
        title.text = privateCopy ? L("Meeting reminder") : occurrence.map { ReminderFormatting.safeTitle($0.title) }
        let scheduled = occurrence?.start.formatted(date: .omitted, time: .shortened) ?? ""
        let minutes = max(0, Int(Date().timeIntervalSince(occurrence?.start ?? Date()) / 60))
        time.text = L("Scheduled %@", scheduled) + (minutes > 0 ? " · " + L("%d min ago", minutes) : "")
        open.configuration?.title = incoming.count > 1 ? L("View meetings") + " (+\(incoming.count - 1))" : L("View meeting")
        chip.configuration?.title = scheduled + (incoming.count > 1 ? " +\(incoming.count - 1)" : "")
        chip.accessibilityLabel = L("Meeting reminder") + " · " + scheduled
        next.access?.reminderActions = [UIAction(title: L("View meetings"), image: UIImage(systemName: "calendar")) { [weak self] _ in self?.openMeetings() }]
        if overlay.superview !== parent { parent.addSubview(overlay) }
        overlay.isHidden = false
        if overlay.frame != parent.bounds { overlay.frame = parent.bounds }
        if parent.subviews.last !== overlay { parent.bringSubviewToFront(overlay) }
        let mounted = layout()
        if fresh, expanded, mounted {
            UIAccessibility.post(notification: .announcement, argument: [title.text, time.text].compactMap { $0 }.joined(separator: ". "))
        }
        scheduleCollapse()
        return mounted ? Set(incoming.map(\.id)) : []
    }
    @discardableResult private func layout() -> Bool {
        guard let host, let parent = host.surface else { return false }
        let access = host.access, toolbar = host.toolbar
        let safe = parent.bounds.inset(by: parent.safeAreaInsets).insetBy(dx: 12, dy: 8)
        guard safe.width > 0, safe.height > 0 else { return false }
        let controls = access.map { parent.convert($0.bounds, from: $0) } ?? CGRect(x: safe.maxX, y: safe.maxY - 48, width: 0, height: 48)
        let primary = toolbar.map { parent.convert($0.bounds, from: $0) } ?? controls
        let large = parent.traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let areas = MeetingReminderGeometry.freeAreas(in: safe, controls: [controls, primary])
        var placement: CGRect?
        for area in areas where area.width >= min(280, safe.width) {
            let width = min(420, area.width)
            (card.arrangedSubviews.last as? UIStackView)?.axis = large || width < 330 ? .vertical : .horizontal
            let height = card.systemLayoutSizeFitting(CGSize(width: width, height: 0),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
            if height <= area.height {
                placement = CGRect(x: area.minX, y: area.maxY - height, width: width, height: height); break
            }
        }
        if let placement { card.frame = placement; surface.frame = card.bounds }
        else { expanded = false }
        let chipSize = chip.sizeThatFits(CGSize(width: safe.width, height: 48))
        let chipWidth = max(100, chipSize.width + 12)
        let candidate = CGRect(x: safe.minX, y: controls.midY - 24, width: chipWidth, height: 48)
        let fits = safe.contains(candidate) && !large && !candidate.intersects(controls) &&
            (toolbar == nil || !candidate.intersects(primary))
        chip.frame = candidate
        card.isHidden = !expanded || placement == nil
        chip.isHidden = expanded || !fits || access?.isHidden == true
        let badge = !expanded && !fits && !events.isEmpty ? events.count : 0
        access?.setReminderBadge(badge)
        return !card.isHidden || !chip.isHidden || (badge > 0 && access?.isHidden == false)
    }
    func backgrounded() { expanded = false; cancelCollapse() }
    private func cancelCollapse() { collapseTask?.cancel(); collapseTask = nil }
    private func setExpanded(_ value: Bool) { expanded = value; layout(); scheduleCollapse() }
    private func scheduleCollapse() {
        guard collapseTask == nil, expanded, !UIAccessibility.isVoiceOverRunning else { return }
        collapseTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            collapseTask = nil
            if !UIAccessibility.isVoiceOverRunning, host?.interacting != true, !card.containsFocusedControl {
                setExpanded(false)
            }
        }
    }
    private func openMeetings() {
        guard let coordinator else { return }
        if events.count == 1, let event = events.first { coordinator.open(reference: event.plan.reference, join: false); return }
        guard let presenter = host?.surface?.callActionPresenter, presenter.presentedViewController == nil else { return }
        let chooser = UIAlertController(title: L("View meetings"), message: nil, preferredStyle: .actionSheet)
        for event in events {
            guard let occurrence = coordinator.occurrence(for: event) else { continue }
            chooser.addAction(UIAlertAction(title: ReminderFormatting.safeTitle(occurrence.title) + " · " + occurrence.start.formatted(date: .omitted, time: .shortened), style: .default) { [weak coordinator] _ in
                coordinator?.open(reference: event.plan.reference, join: false)
            })
        }
        chooser.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        chooser.popoverPresentationController?.sourceView = open
        presenter.present(chooser, animated: true)
    }
}

private final class ReminderPassthroughView: UIView {
    var onLayout: (() -> Void)?
    var onEscape: (() -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        return result === self ? nil : result
    }
    override func accessibilityPerformEscape() -> Bool { onEscape?(); return true }
}

private extension UIView {
    var containsFocusedControl: Bool { isFocused || isFirstResponder || subviews.contains { $0.containsFocusedControl } }
}

/// Largest useful regions outside both retained control groups, in preference order.
enum MeetingReminderGeometry {
    static func freeAreas(in safe: CGRect, controls: [CGRect]) -> [CGRect] {
        let frames = controls.filter { !$0.isEmpty }
        let top = frames.map(\.minY).min() ?? safe.maxY
        let left = frames.map(\.minX).min() ?? safe.maxX
        let right = frames.map(\.maxX).max() ?? safe.maxX
        return [
            CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: max(0, top - safe.minY - 8)),
            CGRect(x: safe.minX, y: safe.minY, width: max(0, left - safe.minX - 8), height: safe.height),
            CGRect(x: right + 8, y: safe.minY, width: max(0, safe.maxX - right - 8), height: safe.height)
        ]
    }
}
