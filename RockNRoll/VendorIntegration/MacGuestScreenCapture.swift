import UIKit
import CoreMedia

enum GuestCaptureRoute: Equatable {
    case native, macCompatibility, broadcastExtension, unavailable
    static func select(isMac: Bool, native: Bool, compatibility: Bool, preferCompatibility: Bool = false) -> Self {
        if isMac && preferCompatibility { return compatibility ? .macCompatibility : .unavailable }
        if native { return .native }
        if isMac { return compatibility ? .macCompatibility : .unavailable }
        return .broadcastExtension
    }
}

@MainActor
enum GuestScreenCaptureFactory {
    static var route: GuestCaptureRoute {
        let isMac = ProcessInfo.processInfo.isiOSAppOnMac
        var native = false
        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, *) { native = true }
        #endif
        var force = false
        #if DEBUG
        force = isMac && ProcessInfo.processInfo.environment["ROCKNROLL_TEST_MAC_CAPTURE_COMPAT"] == "1"
        #endif
        let compatible = isMac && (!native || force) && MacScreenCaptureBridge.isSupported()
        return .select(isMac: isMac, native: native, compatibility: compatible, preferCompatibility: force)
    }
    static var isAvailable: Bool { route == .native || route == .macCompatibility }
    static func make(preview: LocalSharePreview, onFrame: ((CMSampleBuffer) -> Void)? = nil,
                     onEffect: @escaping (Bool) -> Void = { _ in }, onSelection: @escaping () -> Void = {},
                     onEnd: @escaping (String?) -> Void = { _ in }, onError: @escaping (String) -> Void) -> GuestScreenCapture & PresenterScreenSource {
        #if canImport(ScreenCaptureKit)
        if route == .native, #available(iOS 27.0, *) {
            return NativeGuestScreenCapture(preview: preview, onFrame: onFrame, onEffect: onEffect,
                onSelection: onSelection, onEnd: onEnd, onError: onError)
        }
        #endif
        return MacGuestScreenCapture(preview: preview, onFrame: onFrame, onEffect: onEffect,
            onSelection: onSelection, onEnd: onEnd, onError: onError)
    }
}

/// Compatibility capture has the same sender and lifecycle contracts as the
/// native path. Apple-owned pixels stay in their original sample buffer.
@MainActor
final class MacGuestScreenCapture: GuestScreenCapture, PresenterScreenSource {
    private let bridge: MacScreenCaptureBridge
    private let preview: LocalSharePreview
    private let onFrame: ((CMSampleBuffer) -> Void)?
    private let onError: (String) -> Void
    private let onEnd: (String?) -> Void
    private var sender: GuestPresenterSender?
    private var stopped = true
    private var generation = 0
    private var retirement: Task<Void, Never>?

    init(preview: LocalSharePreview, onFrame: ((CMSampleBuffer) -> Void)? = nil,
         onEffect: @escaping (Bool) -> Void = { _ in }, onSelection: @escaping () -> Void = {},
         onEnd: @escaping (String?) -> Void = { _ in }, onError: @escaping (String) -> Void,
         bridge: MacScreenCaptureBridge = MacScreenCaptureBridge()) {
        self.preview = preview; self.onFrame = onFrame; self.onError = onError; self.onEnd = onEnd
        self.bridge = bridge
        bridge.onSelection = { _ in MainActor.assumeIsolated { onSelection() } }
        bridge.onEffect = { enabled in MainActor.assumeIsolated { onEffect(enabled) } }
        bridge.onFrame = { [weak self] sample in MainActor.assumeIsolated { self?.receive(sample) } }
        bridge.onEnd = { [weak self] error in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                let attempt = self.generation
                Task { @MainActor [weak self] in
                    guard let self, !self.stopped, self.generation == attempt else { return }
                    await self.stop()
                    let message = error.map { L("Screen sharing stopped: %@", $0.localizedDescription) }
                    if let message { self.onError(message) }
                    self.onEnd(message)
                }
            }
        }
    }
    func start() {
        guard retirement == nil else { return }
        if stopped { generation += 1 }
        stopped = false
        do { try bridge.present() }
        catch {
            stopped = true
            let message = L("Could not open screen sharing: %@", error.localizedDescription)
            onError(message); onEnd(message)
        }
    }
    private func receive(_ sample: CMSampleBuffer) {
        guard !stopped else { return }
        if let onFrame { onFrame(sample); return }
        if sender == nil {
            let attempt = generation
            sender = GuestPresenterSender(preview: preview) { [weak self] message in
                Task { @MainActor in
                    guard let self, !self.stopped, self.generation == attempt else { return }
                    await self.stop(); self.onError(message); self.onEnd(message)
                }
            }
            let source: LocalSharePreview.Source = bridge.sourceStyle == 1 ? .window : bridge.sourceStyle == 3 ? .application : .screen
            sender?.start(source: source)
        }
        sender?.send(sample)
    }
    func stop() async {
        if let retirement { await retirement.value; return }
        generation += 1
        stopped = true
        let sender = self.sender; self.sender = nil
        retirement = Task {
            await sender?.stop()
            await withCheckedContinuation { continuation in
                bridge.stop { _ in continuation.resume() }
            }
        }
        await retirement?.value; retirement = nil
    }
}
