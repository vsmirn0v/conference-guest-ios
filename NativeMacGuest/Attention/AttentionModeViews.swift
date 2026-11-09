import SwiftUI

extension AttentionMode {
    var title: String {
        switch self { case .off: L("Off"); case .mentions: L("Mentions"); case .watch: L("Watch") }
    }
    /// What the mode means, in your words.
    var detail: String {
        switch self {
        case .off: L("Leave me alone here")
        case .mentions: L("Only when I'm called or it's urgent")
        case .watch: L("Also when it concerns me")
        }
    }
    var symbol: String {
        switch self { case .off: "bell.slash"; case .mentions: "at"; case .watch: "eye" }
    }
    var tint: Color {
        switch self { case .off: .secondary; case .mentions: .blue; case .watch: .teal }
    }
}

extension AttentionSituation {
    var title: String {
        switch self { case .onScreen: L("On screen"); case .background: L("In the background"); case .silenced: L("Silenced") }
    }
    var detail: String {
        switch self {
        case .onScreen: L("You are looking at it")
        case .background: L("Sound on, another meeting or app in front")
        case .silenced: L("Sound off; you rely on the assistant to hear it")
        }
    }
}

/// A meeting's attention mode as a small tinted button; click to change it.
struct AttentionModeChip: View {
    @ObservedObject var attention: AttentionCoordinator
    @ObservedObject var model: NativeDesktopMeetingModel
    /// Icon only, for tight rows.
    var compact = true
    @State private var open = false

    var body: some View {
        let resolved = attention.resolvedMode(model)
        Button { open.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: resolved.mode.symbol).font(.system(size: 10, weight: .semibold))
                if !compact { Text(resolved.mode.title).font(.caption2.weight(.semibold)) }
            }
            .foregroundStyle(resolved.mode.tint)
            .padding(.horizontal, compact ? 4 : 6).frame(minWidth: 20, minHeight: 18)
            .background(resolved.mode.tint.opacity(resolved.mode == .off ? 0.12 : 0.16), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L("Attention: %@. %@", resolved.mode.title, AttentionModePicker.explanation(resolved)))
        .accessibilityLabel(L("Attention: %@", resolved.mode.title))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            AttentionModePicker(attention: attention, model: model) { open = false }
        }
    }
}

/// Choose how closely the assistant follows this meeting, and for how long.
struct AttentionModePicker: View {
    @ObservedObject var attention: AttentionCoordinator
    @ObservedObject private var store: AttentionStore
    @ObservedObject var model: NativeDesktopMeetingModel
    var close: () -> Void = {}

    init(attention: AttentionCoordinator, model: NativeDesktopMeetingModel, close: @escaping () -> Void = {}) {
        self.attention = attention
        self.model = model
        self.close = close
        _store = ObservedObject(wrappedValue: attention.store)
    }

    var body: some View {
        let resolved = attention.resolvedMode(model)
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Attention for “%@”", model.title)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            VStack(spacing: 2) {
                ForEach(AttentionMode.allCases, id: \.self) { mode in
                    Button { attention.setMode(mode, for: model, scope: currentScope(resolved)) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: mode.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(mode.tint)
                                .frame(width: 26, height: 26).background(mode.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(mode.title).fontWeight(.semibold)
                                Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if mode == resolved.mode { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(mode.tint) }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                        .background(mode == resolved.mode ? mode.tint.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(mode == resolved.mode ? .isSelected : [])
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Keep this")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    scopeButton(L("Until I leave"), .untilLeave, resolved)
                    scopeButton(L("30 min"), .minutes(30), resolved)
                    scopeButton(L("Every time"), .series, resolved)
                        .help(model.calendarSeriesID == nil ? L("Every time you join this room") : L("Every meeting in this calendar series and room"))
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(Self.explanation(resolved)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if resolved.source != .situation(attention.situation(model)) {
                    Button(L("Use default")) { attention.resetMode(for: model, series: resolved.source == .series) }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
            if !store.enabled {
                Text(L("Attention is off in Settings → Assistant.")).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12).frame(width: 290)
    }

    private func currentScope(_ resolved: AttentionCoordinator.ResolvedMode) -> AttentionCoordinator.ModeScope {
        switch resolved.source {
        case .meeting(let until): until == nil ? .untilLeave : .minutes(30)
        case .series: .series
        case .situation: .untilLeave
        }
    }

    private func scopeButton(_ title: String, _ scope: AttentionCoordinator.ModeScope, _ resolved: AttentionCoordinator.ResolvedMode) -> some View {
        let selected: Bool = {
            switch (scope, resolved.source) {
            case (.untilLeave, .meeting(nil)), (.series, .series): true
            case (.minutes, .meeting(let until)): until != nil
            default: false
            }
        }()
        return Button(title) { attention.setMode(resolved.mode, for: model, scope: scope) }
            .buttonStyle(.plain).font(.caption.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.accentColor : .clear))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Why the meeting has its current mode, in one line.
    static func explanation(_ resolved: AttentionCoordinator.ResolvedMode) -> String {
        switch resolved.source {
        case .meeting(nil): L("You chose this until you leave.")
        case .meeting(let until?): L("You chose this until %@.", until.formatted(date: .omitted, time: .shortened))
        case .series: L("Every occurrence of this meeting starts this way.")
        case .situation(.onScreen): L("The default while you look at it.")
        case .situation(.background): L("The default for meetings in the background.")
        case .situation(.silenced): L("The default for silenced meetings.")
        }
    }
}

/// The meeting control bar's Assistant button: the mode's symbol, opening the switch (⌃⌥A).
struct AttentionControlButton: View {
    @ObservedObject var attention: AttentionCoordinator
    @ObservedObject var model: NativeDesktopMeetingModel
    @State private var open = false

    var body: some View {
        let mode = attention.resolvedMode(model).mode
        Button { open.toggle() } label: {
            VStack(spacing: 5) {
                Image(systemName: mode.symbol).font(.title3)
                Text(L("Assistant")).font(.caption)
            }
            .foregroundStyle(mode == .off ? Color.primary : mode.tint).frame(width: 66, height: 48).contentShape(Rectangle())
            .overlay(alignment: .topTrailing) {
                if let card = attention.card(for: model.sessionID) {
                    Circle().fill(card.verdict.level.color).frame(width: 8, height: 8).padding(.top, 6).padding(.trailing, 14)
                }
            }
        }
        .buttonStyle(.plain)
        .keyboardShortcut("a", modifiers: [.control, .option])
        .help(L("Attention: %@. %@ (⌃⌥A)", mode.title, AttentionModePicker.explanation(attention.resolvedMode(model))))
        .accessibilityLabel(L("Assistant")).accessibilityValue(mode.title)
        .popover(isPresented: $open, arrowEdge: .top) {
            AttentionModePicker(attention: attention, model: model) { open = false }
        }
    }
}

/// Shows the mode chip only while Attention is on, without making the sidebar observe the store.
struct AttentionModeChipGate: View {
    @ObservedObject var attention: AttentionCoordinator
    @ObservedObject private var store: AttentionStore
    @ObservedObject var model: NativeDesktopMeetingModel

    init(attention: AttentionCoordinator, model: NativeDesktopMeetingModel) {
        self.attention = attention
        self.model = model
        _store = ObservedObject(wrappedValue: attention.store)
    }

    var body: some View {
        if store.enabled { AttentionModeChip(attention: attention, model: model) }
    }
}

/// The meeting control bar's Assistant button, present only while Attention is on.
struct AttentionControlButtonGate: View {
    @ObservedObject var attention: AttentionCoordinator
    @ObservedObject private var store: AttentionStore
    @ObservedObject var model: NativeDesktopMeetingModel

    init(attention: AttentionCoordinator, model: NativeDesktopMeetingModel) {
        self.attention = attention
        self.model = model
        _store = ObservedObject(wrappedValue: attention.store)
    }

    var body: some View {
        if store.enabled { AttentionControlButton(attention: attention, model: model) }
    }
}

/// The sidebar count of unread Moments. Observes the store so a seen-mark does not redraw the workspace.
struct AssistantUnreadBadge: View {
    @ObservedObject var store: AttentionStore
    var body: some View {
        if store.momentHistory.unreadCount > 0 {
            Spacer()
            Text(store.momentHistory.unreadCount, format: .number)
                .font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color.orange, in: Capsule())
        }
    }
}

/// Settings: the mode of meetings without their own, by situation.
struct AttentionSituationDefaults: View {
    @ObservedObject var store: AttentionStore

    var body: some View {
        ForEach(AttentionSituation.allCases, id: \.self) { situation in
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center) {
                    description(situation)
                    Spacer(minLength: 12)
                    segmentedPicker(situation).layoutPriority(1)
                }
                VStack(alignment: .leading, spacing: 8) {
                    description(situation)
                    segmentedPicker(situation)
                }
                VStack(alignment: .leading, spacing: 8) {
                    description(situation)
                    menuPicker(situation)
                }
            }
            .accessibilityIdentifier("attention.situation.\(situation.rawValue)")
        }
    }

    private func description(_ situation: AttentionSituation) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(situation.title)
            Text(situation.detail).font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func segmentedPicker(_ situation: AttentionSituation) -> some View {
        Picker(situation.title, selection: modeBinding(situation)) {
            ForEach(AttentionMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier("attention.mode.\(situation.rawValue)")
    }

    @ViewBuilder private func menuPicker(_ situation: AttentionSituation) -> some View {
        Picker(situation.title, selection: modeBinding(situation)) {
            ForEach(AttentionMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("attention.mode.\(situation.rawValue)")
    }

    private func modeBinding(_ situation: AttentionSituation) -> Binding<AttentionMode> {
        Binding(get: { store.mode(for: situation) },
                set: { store.situationModes[situation] = $0 })
    }
}
