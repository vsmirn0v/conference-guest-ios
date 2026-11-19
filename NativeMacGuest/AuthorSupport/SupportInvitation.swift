#if NATIVE_DIRECT_UPDATES
import AppKit
import SwiftUI

@MainActor struct SupportInvitation: View {
    let visit: UUID?
    let safe: Bool
    let open: () -> Void
    @ObservedObject private var service = AuthorSupportService.shared
    @State private var offered: UUID?
    @State private var consumed: UUID?
    @State private var interrupted: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let visit, offered == visit, safe, !service.hasActiveSubscription(at: Date()) {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    Label(SupportCopy.text("Finding Rock’n’Roll useful?"), systemImage: "heart")
                        .font(.headline).accessibilityAddTraits(.isHeader)
                    Button(SupportCopy.text("Support the author"), action: open)
                        .buttonStyle(.link).accessibilityIdentifier("home.author-support")
                }
                .background(SupportViewportProbe {
                    guard offered == visit, consumed != visit else { return }
                    if SupportReminder.shared.claimVisible(active: service.hasActiveSubscription(at: Date())) {
                        consumed = visit
                    } else {
                        offered = nil
                    }
                })
            }
        }
        .task(id: visit) { await consider(visit) }
        .onChange(of: safe) { if !$0 { interrupted = visit; offered = nil } }
    }

    private func consider(_ visit: UUID?) async {
        offered = nil
        guard let visit, safe, SupportReminder.shared.eligible(active: false) else { return }
        // The provider may already have verified a renewal while the Mac was
        // offline. Check enrolled accounts before deciding to show an invitation.
        try? await service.refreshClaim()
        guard !Task.isCancelled, interrupted != visit,
              SupportReminder.shared.eligible(active: service.hasActiveSubscription(at: Date())) else { return }
        offered = visit
    }
}

/// SwiftUI eagerly constructs the Home VStack. AppKit's visibleRect tells us
/// when scrolling has actually brought the invitation into the key window.
private struct SupportViewportProbe: NSViewRepresentable {
    var visible: () -> Void
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.visible = visible; view.scheduleCheck() }
    @MainActor final class Probe: NSView {
        var visible: (() -> Void)?
        private var observers: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window else { return }
            if let clip = enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                observe(NSView.boundsDidChangeNotification, object: clip)
            }
            observe(NSWindow.didBecomeKeyNotification, object: window)
            observe(NSWindow.didChangeOcclusionStateNotification, object: window)
            scheduleCheck()
        }
        private func observe(_ name: NSNotification.Name, object: AnyObject) {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleCheck() }
            })
        }
        override func layout() { super.layout(); scheduleCheck() }
        func scheduleCheck() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, NSApp.isActive, window.isKeyWindow,
                      window.occlusionState.contains(.visible), !self.isHiddenOrHasHiddenAncestor,
                      self.bounds.height > 0, self.visibleRect.height >= self.bounds.height * 0.8 else { return }
                self.visible?()
            }
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
#endif
