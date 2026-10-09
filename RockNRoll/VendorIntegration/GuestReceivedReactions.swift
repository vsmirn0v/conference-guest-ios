import ConferenceCore
import JazzCore
import ObjectiveC
import UIKit

/// The public JazzCore delegate contract, normalized before crossing queues.
/// The pinned SDK's decoder uses participantId and string ConferenceEmoji values;
/// its public header also documents participantFromId and numeric JitsiReaction.
struct GuestReceivedReaction: Equatable, Sendable {
    let kind: MeetingReaction
    let participantID: String

    init(kind: MeetingReaction, participantID: String) { self.kind = kind; self.participantID = participantID }

    init?(payload: NSDictionary) {
        let current = payload["participantId"] as? String
        let documented = payload["participantFromId"] as? String
        guard payload["participantId"] == nil || current != nil,
              payload["participantFromId"] == nil || documented != nil,
              current == nil || documented == nil || current == documented,
              let participantID = current ?? documented,
              !participantID.isEmpty, participantID.utf8.count <= 1024 else { return nil }
        let kind: MeetingReaction?
        if let value = payload["value"] as? String {
            let candidate = MeetingReaction(rawValue: value)
            kind = candidate.flatMap { GuestReactionCode.legacy.contains($0) ? $0 : nil }
        } else if let value = payload["value"] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue >= 0,
                  value.doubleValue <= Double(JitsiReaction.surprise.rawValue),
                  value.doubleValue.rounded(.towardZero) == value.doubleValue {
            switch value.uintValue {
            case JitsiReaction.applause.rawValue: kind = .applause
            case JitsiReaction.like.rawValue: kind = .like
            case JitsiReaction.dislike.rawValue: kind = .dislike
            case JitsiReaction.smile.rawValue: kind = .smile
            case JitsiReaction.surprise.rawValue: kind = .surprise
            default: kind = nil
            }
        } else { kind = nil }
        guard let kind else { return nil }
        self.kind = kind; self.participantID = participantID
    }
}

/// Observe a documented Objective-C delegate callback without replacing the
/// delegate or intercepting other methods. Always call its original implementation.
/// Only explicitly registered delegate instances deliver events to this app.
final class GuestReactionDelegateTap: @unchecked Sendable {
    private static let lock = NSLock()
    private static let selector = NSSelectorFromString("reactionReceived:")
    private static let observers = NSMapTable<NSObject, NSHashTable<GuestReactionDelegateTap>>(
        keyOptions: .weakMemory, valueOptions: .strongMemory)
    private static var implementations = Set<UInt>()
    private weak var delegate: NSObject?
    private let onCallback: ((Bool, String?, [String]) -> Void)?
    private let onReaction: (GuestReceivedReaction) -> Void

    init?(delegate: NSObject, onCallback: ((Bool, String?, [String]) -> Void)? = nil,
          onReaction: @escaping (GuestReceivedReaction) -> Void) {
        self.delegate = delegate; self.onCallback = onCallback; self.onReaction = onReaction
        Self.lock.lock()
        guard Self.install(on: delegate) else { Self.lock.unlock(); return nil }
        let subscriptions = Self.observers.object(forKey: delegate) ?? NSHashTable(options: .weakMemory)
        subscriptions.add(self)
        Self.observers.setObject(subscriptions, forKey: delegate)
        Self.lock.unlock()
    }

    private static func install(on delegate: NSObject) -> Bool {
        guard let type = object_getClass(delegate),
              let method = class_getInstanceMethod(type, selector),
              let encoding = method_getTypeEncoding(method) else { return false }
        let implementation = method_getImplementation(method)
        // An inherited wrapper already dispatches by concrete object identity.
        // Wrapping it again would duplicate a callback when a subclass is used.
        if implementations.contains(unsafeBitCast(implementation, to: UInt.self)) { return true }
        typealias Callback = @convention(c) (AnyObject, Selector, NSDictionary?) -> Void
        let original = unsafeBitCast(implementation, to: Callback.self)
        let forward: @convention(block) (NSObject, NSDictionary?) -> Void = { delegate, payload in
            let reaction = payload.flatMap(GuestReceivedReaction.init(payload:))
            original(delegate, selector, payload)
            lock.lock()
            let subscriptions = observers.object(forKey: delegate)?.allObjects ?? []
            lock.unlock()
            #if DEBUG
            let wireValue = (payload?["value"] as? String).map { String($0.prefix(64)) } ??
                (payload?["value"] as? NSNumber)?.stringValue
            let keys = Array((payload?.allKeys.compactMap { $0 as? String }.sorted() ?? []).prefix(32))
            #else
            let wireValue: String? = nil
            let keys: [String] = []
            #endif
            subscriptions.forEach {
                $0.onCallback?(reaction != nil, wireValue, keys)
                if let reaction { $0.onReaction(reaction) }
            }
        }
        let replacement = imp_implementationWithBlock(forward)
        if !class_addMethod(type, selector, replacement, encoding) {
            class_replaceMethod(type, selector, replacement, encoding)
        }
        implementations.insert(unsafeBitCast(replacement, to: UInt.self))
        return true
    }

    func invalidate() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if let delegate, let subscriptions = Self.observers.object(forKey: delegate) {
            subscriptions.remove(self)
            if subscriptions.allObjects.isEmpty { Self.observers.removeObject(forKey: delegate) }
        }
        delegate = nil
    }
    deinit { invalidate() }
}

/// Shared, session-scoped presentation for the public Jitsi delegate and the
/// validated modern transport. No internal SDK publisher or model is inspected.
@MainActor
final class GuestReceivedReactions {
    struct Participant {
        let name: String
        let isLocal: Bool
    }
    private weak var root: UIView?
    private weak var delegate: NSObject?
    private var tap: GuestReactionDelegateTap?
    private var refreshTask: Task<Void, Never>?
    private var generation = UUID()
    private let valid: () -> Bool
    private let participant: (String) -> Participant?
    private let onReaction: (MeetingReaction, String) -> Void
    private(set) var isObserving = false
    private var transportObserving = false
    private(set) var receivedCount = 0
    private(set) var lastReceived: GuestReceivedReaction?
    private(set) var receivedByKind: [MeetingReaction: Int] = [:]
    var onCapabilityChanged: ((Bool) -> Void)?
    #if DEBUG
    static weak var currentForTesting: GuestReceivedReactions?
    func knowsRemoteParticipantForTesting(_ id: String) -> Bool { participant(id)?.isLocal == false }
    private var publicViewCount = 0
    private var callbackCount = 0
    private var unrecognizedCount = 0
    private var unknownParticipantCount = 0
    private var localCount = 0
    private var lastWireValue: String?
    private var lastPayloadKeys: [String] = []
    private var diagnosticLabel: UILabel?
    #endif

    init(valid: @escaping () -> Bool, participant: @escaping (String) -> Participant?,
         onReaction: @escaping (MeetingReaction, String) -> Void) {
        self.valid = valid; self.participant = participant; self.onReaction = onReaction
    }
    func start(in root: UIView) {
        stop(); self.root = root
        #if DEBUG
        Self.currentForTesting = self
        #endif
        refresh()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.valid(), self.root != nil else { return }
                if UIApplication.shared.applicationState == .active { self.refresh() }
            }
        }
    }
    func refresh() {
        guard valid(), let root else { detach(); return }
        var matches: [ObjectIdentifier: NSObject] = [:]
        #if DEBUG
        publicViewCount = 0
        defer { writeTrace() }
        #endif
        func inspect(_ view: UIView) {
            if let conference = view as? JitsiMeetView {
                #if DEBUG
                publicViewCount += 1
                #endif
                if let delegate = conference.delegate as? NSObject { matches[ObjectIdentifier(delegate)] = delegate }
            }
            view.subviews.forEach(inspect)
        }
        inspect(root.window ?? root)
        // Do not guess which of two simultaneous transports owns an event.
        guard matches.count == 1, let selected = matches.values.first else { detach(); return }
        if delegate === selected, tap != nil { return }
        detach(); delegate = selected
        let expected = generation
        tap = GuestReactionDelegateTap(delegate: selected, onCallback: { [weak self] recognized, wireValue, keys in
            #if DEBUG
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected, self.valid() else { return }
                self.callbackCount += 1
                self.lastWireValue = wireValue; self.lastPayloadKeys = keys
                if !recognized { self.unrecognizedCount += 1 }
                self.writeTrace()
            }
            #endif
        }) { [weak self] reaction in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected else { return }
                self.receive(reaction)
            }
        }
        setObserving(tap != nil || transportObserving)
    }
    func setTransportObserving(_ observing: Bool) {
        transportObserving = observing; setObserving(observing || tap != nil)
        #if DEBUG
        writeTrace()
        #endif
    }
    func receive(_ reaction: GuestReceivedReaction) {
        guard valid(), root != nil, UIApplication.shared.applicationState != .background else { return }
        guard let sender = participant(reaction.participantID) else {
            #if DEBUG
            unknownParticipantCount += 1; writeTrace()
            #endif
            return
        }
        guard !sender.isLocal else {
            #if DEBUG
            localCount += 1; writeTrace()
            #endif
            return
        }
        receivedCount += 1; lastReceived = reaction
        receivedByKind[reaction.kind, default: 0] += 1
        onReaction(reaction.kind, sender.name)
        #if DEBUG
        writeTrace()
        #endif
    }
    private func setObserving(_ value: Bool) {
        guard isObserving != value else { return }
        isObserving = value; onCapabilityChanged?(value)
    }
    private func detach() {
        generation = UUID(); tap?.invalidate(); tap = nil; delegate = nil; setObserving(transportObserving)
    }
    func stop() {
        refreshTask?.cancel(); refreshTask = nil; root = nil; transportObserving = false; detach()
        #if DEBUG
        diagnosticLabel?.removeFromSuperview(); diagnosticLabel = nil
        #endif
    }
    #if DEBUG
    private func writeTrace() {
        guard let path = ProcessInfo.processInfo.environment["CONFERENCE_TEST_REACTIONS_RECEIVE_TRACE"] else { return }
        let snapshot: [String: Any] = ["observing": isObserving, "publicJitsiViews": publicViewCount,
            "callbacks": callbackCount, "unrecognized": unrecognizedCount, "unknownParticipant": unknownParticipantCount,
            "local": localCount, "delivered": receivedCount,
            "byKind": Dictionary(uniqueKeysWithValues: receivedByKind.map { ($0.key.rawValue, $0.value) }),
            "foreground": UIApplication.shared.applicationState == .active, "valid": valid(),
            "lastWireValue": lastWireValue ?? "", "payloadKeys": lastPayloadKeys]
        if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        // Public, opt-in diagnostics also work when macOS protects the app's
        // container from the test runner. Only counters and capability are shown.
        guard let host = root?.window ?? root else { return }
        let label: UILabel
        if let diagnosticLabel { label = diagnosticLabel }
        else {
            label = UILabel()
            label.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
            label.textColor = .white; label.backgroundColor = UIColor.black.withAlphaComponent(0.9)
            label.numberOfLines = 3; label.isUserInteractionEnabled = false
            label.isAccessibilityElement = true
            label.accessibilityIdentifier = "reactions.receiveDiagnostics"
            label.accessibilityLabel = "Reaction receive diagnostics"
            diagnosticLabel = label
        }
        if label.superview !== host { host.addSubview(label) }
        host.bringSubviewToFront(label)
        label.frame = CGRect(x: max(8, host.bounds.width - 408), y: host.safeAreaInsets.top + 62,
                             width: min(400, max(0, host.bounds.width - 16)), height: 44)
        let state = "views=\(publicViewCount) observing=\(isObserving) callbacks=\(callbackCount) delivered=\(receivedCount)"
        let rejected = "unknown=\(unknownParticipantCount) local=\(localCount) unrecognized=\(unrecognizedCount)"
        let lifecycle = "active=\(UIApplication.shared.applicationState == .active) valid=\(valid())"
        label.text = state + "\n" + rejected + "\n" + lifecycle
        label.accessibilityValue = label.text
    }
    #endif
    deinit { refreshTask?.cancel(); tap?.invalidate() }
}

/// Transient receive feedback only. No history, replay, taps, or queued events.
@MainActor
final class ReceivedReactionOverlay: UIView {
    private let stack = UIStackView()
    private var rows: [(id: UUID, view: UIView, expiry: Task<Void, Never>)] = []
    private var observer: NSObjectProtocol?
    var suppressed = false { didSet { if suppressed { clear() } } }
    var contentInsets = UIEdgeInsets(top: 92, left: 16, bottom: 96, right: 16) { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; accessibilityElementsHidden = true
        stack.axis = .vertical; stack.spacing = 6; stack.alignment = .leading
        addSubview(stack)
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.clear() } }
    }
    required init?(coder: NSCoder) { nil }

    func show(_ reaction: MeetingReaction, from name: String) {
        guard !suppressed, window != nil, UIApplication.shared.applicationState != .background else { return }
        while rows.count >= 3 { remove(rows[0].id) }
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white; label.numberOfLines = 2; label.lineBreakMode = .byTruncatingTail
        label.text = reaction.emoji + "  " + name
        label.accessibilityIdentifier = "reactions.received." + reaction.rawValue
        let card = UIView()
        card.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        card.layer.cornerRadius = 12; card.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(label)
        stack.addArrangedSubview(card)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -9),
            card.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor)
        ])
        let id = UUID()
        let expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.remove(id)
        }
        rows.append((id, card, expiry)); setNeedsLayout()
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: L("%@ reacted %@", name, reaction.title))
        }
    }
    private func remove(_ id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let row = rows.remove(at: index); row.expiry.cancel(); row.view.removeFromSuperview(); setNeedsLayout()
    }
    func clear() { while let row = rows.first { remove(row.id) } }
    override func layoutSubviews() {
        super.layoutSubviews()
        let area = bounds.inset(by: contentInsets)
        let width = min(320, max(0, area.width))
        let height = stack.systemLayoutSizeFitting(CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        stack.frame = CGRect(x: area.minX, y: area.minY, width: width, height: min(max(0, area.height), height))
        stack.clipsToBounds = true
    }
    deinit { observer.map(NotificationCenter.default.removeObserver); rows.forEach { $0.expiry.cancel() } }
}
