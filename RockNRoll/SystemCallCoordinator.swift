import AVFoundation
import CallKit
import Foundation

/// Reports only a real, user-requested conference to the system call UI.
final class SystemCallCoordinator: NSObject, CXProviderDelegate, CXCallObserverDelegate {
    var onActivated: (() -> Void)?
    var onDeactivated: (() -> Void)?
    /// True when the user or app deliberately ended the system call.
    var onEnded: ((Bool) -> Void)?
    var onMuteChanged: ((Bool) -> Void)?
    var onHoldChanged: ((Bool) -> Void)?
    var onFailure: ((Error) -> Void)?

    private lazy var provider: CXProvider = {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.includesCallsInRecents = false
        configuration.supportedHandleTypes = [.generic]
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        return CXProvider(configuration: configuration)
    }()
    private lazy var controller = CXCallController()
    private let usesSystemCall: Bool
    private let transactionRequester: ((CXTransaction, @escaping (Error?) -> Void) -> Void)?
    private(set) var callID: UUID?
    private var isConnected = false
    private var isMuted = true
    private var isHeld = false
    private var heldForAnotherCall = false
    private var holdStartedAt: Date?
    private var resumeRequested = false
    private var isAudioSessionActive = false
    private(set) var transferHolding = false
    private var transferHoldCompletion: ((Error?) -> Void)?
    private var transferHoldGeneration = UUID()
    private var transferHoldActionID: UUID?

    var canRestoreAudio: Bool {
        callID != nil && isAudioSessionActive && !isHeld && !hasAnotherActiveCall
    }

    init(transactionRequester: ((CXTransaction, @escaping (Error?) -> Void) -> Void)? = nil) {
        self.transactionRequester = transactionRequester
        usesSystemCall = transactionRequester != nil || !ProcessInfo.processInfo.isiOSAppOnMac
        super.init()
        if usesSystemCall && transactionRequester == nil {
            provider.setDelegate(self, queue: .main)
            controller.callObserver.setDelegate(self, queue: .main)
        }
    }

    private func request(_ transaction: CXTransaction, completion: @escaping (Error?) -> Void) {
        if let transactionRequester { transactionRequester(transaction, completion) }
        else { controller.request(transaction, completion: completion) }
    }

    func start() {
        guard callID == nil else { return }
        finishPendingTransferHold()
        let id = UUID()
        callID = id
        isConnected = false
        isMuted = true
        isHeld = false
        heldForAnotherCall = false
        holdStartedAt = nil
        resumeRequested = false
        isAudioSessionActive = false
        transferHolding = false
        if !usesSystemCall {
            // iOS apps running on Mac don't receive the CallKit audio activation
            // callback reliably; the app owns this session until the jam ends.
            #if DEBUG
            print("Mac meeting audio: activating")
            #endif
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                isAudioSessionActive = true
                onActivated?()
            } catch {
                callID = nil
                onFailure?(error)
            }
            return
        }
        #if DEBUG
        print("System call: requesting start")
        #endif
        let handle = CXHandle(type: .generic, value: L("Jam"))
        let action = CXStartCallAction(call: id, handle: handle)
        action.isVideo = true
        request(CXTransaction(action: action)) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                guard self?.callID == id else { return }
                #if DEBUG
                print("System call: request failed: \(error.localizedDescription)")
                #endif
                self?.callID = nil
                self?.onFailure?(error)
            }
        }
    }

    func markConnected() {
        guard let callID, !isConnected else { return }
        isConnected = true
        guard usesSystemCall else { return }
        provider.reportOutgoingCall(with: callID, connectedAt: nil)
        setMuted(isMuted, force: true)
    }

    func setMuted(_ muted: Bool) {
        setMuted(muted, force: false)
    }

    private func setMuted(_ muted: Bool, force: Bool) {
        guard let callID else { return }
        let changed = isMuted != muted
        isMuted = muted
        guard usesSystemCall else { return }
        guard isConnected, changed || force else { return }
        request(CXTransaction(action: CXSetMutedCallAction(call: callID, muted: muted))) { error in
            guard let error else { return }
            #if DEBUG
            print("System call: mute update failed: \(error.localizedDescription)")
            #endif
        }
    }

    func end() {
        guard let callID else { return }
        if !usesSystemCall {
            finishPendingTransferHold()
            self.callID = nil
            isConnected = false
            isAudioSessionActive = false
            try? AVAudioSession.sharedInstance().setActive(false,
                options: .notifyOthersOnDeactivation)
            onEnded?(true)
            return
        }
        request(CXTransaction(action: CXEndCallAction(call: callID))) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                #if DEBUG
                print("System call: end failed: \(error.localizedDescription)")
                #endif
                guard self?.callID == callID else { return }
                self?.markEnded(reason: .failed)
                self?.onEnded?(true)
            }
        }
    }

    func markEnded(reason: CXCallEndedReason) {
        guard let callID else { return }
        self.callID = nil
        isConnected = false
        isHeld = false
        heldForAnotherCall = false
        holdStartedAt = nil
        resumeRequested = false
        isAudioSessionActive = false
        transferHolding = false
        finishPendingTransferHold()
        if usesSystemCall && transactionRequester == nil { provider.reportCall(with: callID, endedAt: nil, reason: reason) }
    }

    func providerDidReset(_ provider: CXProvider) {
        guard usesSystemCall else { return }
        finishPendingTransferHold()
        #if DEBUG
        print("System call: provider reset")
        #endif
        callID = nil
        isConnected = false
        isHeld = false
        heldForAnotherCall = false
        holdStartedAt = nil
        resumeRequested = false
        isAudioSessionActive = false
        onEnded?(false)
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        #if DEBUG
        print("System call: start action")
        #endif
        guard callID == action.callUUID else {
            action.fail()
            return
        }
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        #if DEBUG
        print("System call: audio activated")
        #endif
        guard callID != nil else { return }
        isAudioSessionActive = true
        onActivated?()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        #if DEBUG
        print("System call: end action")
        #endif
        guard callID == action.callUUID else {
            action.fail()
            return
        }
        finishPendingTransferHold()
        callID = nil
        isConnected = false
        isAudioSessionActive = false
        action.fulfill()
        onEnded?(true)
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard callID == action.callUUID else {
            action.fail()
            return
        }
        isMuted = action.isMuted
        onMuteChanged?(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        guard callID == action.callUUID else {
            action.fail()
            return
        }
        #if DEBUG
        print("System call: hold changed: \(action.isOnHold)")
        #endif
        isHeld = action.isOnHold
        resumeRequested = false
        if isHeld {
            holdStartedAt = Date()
            heldForAnotherCall = hasAnotherActiveCall
        } else {
            heldForAnotherCall = false
            holdStartedAt = nil
        }
        onHoldChanged?(isHeld)
        if transferHoldActionID == action.uuid {
            let transferCompletion = transferHoldCompletion
            transferHoldCompletion = nil; transferHoldActionID = nil
            DispatchQueue.main.async { transferCompletion?(nil) }
        }
        action.fulfill()
        resumeIfPossible()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        #if DEBUG
        print("System call: audio deactivated")
        #endif
        guard callID != nil else { return }
        isAudioSessionActive = false
        onDeactivated?()
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        guard let callID, call.uuid != callID else { return }
        #if DEBUG
        print("System call: another call changed, connected=\(call.hasConnected), ended=\(call.hasEnded)")
        #endif
        if !call.hasEnded {
            if isHeld, let holdStartedAt,
               Date().timeIntervalSince(holdStartedAt) <= 3 {
                heldForAnotherCall = true
            }
        }
        resumeIfPossible()
    }

    func resumeIfPossible() {
        guard usesSystemCall, !transferHolding else { return }
        guard let callID, isHeld, heldForAnotherCall,
              !hasAnotherActiveCall, !resumeRequested else { return }
        resumeRequested = true
        #if DEBUG
        print("System call: requesting resume after other call")
        #endif
        request(CXTransaction(action: CXSetHeldCallAction(call: callID, onHold: false))) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                guard self?.callID == callID else { return }
                self?.resumeRequested = false
                #if DEBUG
                print("System call: resume failed: \(error.localizedDescription)")
                #endif
            }
        }
    }

    #if DEBUG
    func requestHoldForTesting(_ held: Bool) {
        guard let callID else { return }
        request(CXTransaction(action: CXSetHeldCallAction(call: callID, onHold: held))) { error in
            if let error { print("Test hold request failed: \(error.localizedDescription)") }
        }
    }
    #endif

    /// Use the established conference hold path instead of competing with the
    /// provider's WebRTC audio session. The Mac runtime owns its AVAudioSession.
    func setTransferHeld(_ held: Bool) async throws {
        guard let id = callID, transferHoldCompletion == nil else { throw NSError(domain: "JamTransfer", code: 1) }
        transferHolding = held
        let generation = UUID(); transferHoldGeneration = generation
        if !usesSystemCall {
            isHeld = held
            onHoldChanged?(held)
            if held {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                isAudioSessionActive = false
                onDeactivated?()
            } else {
                try AVAudioSession.sharedInstance().setActive(true)
                isAudioSessionActive = true
                onActivated?()
            }
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
            return
        }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let action = CXSetHeldCallAction(call: id, onHold: held)
            transferHoldActionID = action.uuid
            transferHoldCompletion = { error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            }
            request(CXTransaction(action: action)) { [weak self] error in
                guard let error else { return }
                DispatchQueue.main.async {
                    guard self?.callID == id, self?.transferHoldGeneration == generation else { return }
                    let completion = self?.transferHoldCompletion
                    self?.transferHoldCompletion = nil; self?.transferHoldActionID = nil
                    completion?(error)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard self?.callID == id, self?.transferHoldGeneration == generation,
                      let completion = self?.transferHoldCompletion else { return }
                self?.transferHoldCompletion = nil; self?.transferHoldActionID = nil
                completion(NSError(domain: "JamTransfer", code: 3))
            }
        }
    }
    private func finishPendingTransferHold() {
        transferHoldCompletion?(NSError(domain: "JamTransfer", code: 2))
        transferHoldCompletion = nil
        transferHoldActionID = nil
        transferHolding = false; transferHoldGeneration = UUID()
    }

    private var hasAnotherActiveCall: Bool {
        guard usesSystemCall else { return false }
        guard let callID else { return false }
        return controller.callObserver.calls.contains { $0.uuid != callID && !$0.hasEnded }
    }
}
