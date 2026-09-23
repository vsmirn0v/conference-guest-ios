import AVFoundation
import CallKit
import Foundation

/// Reports only a real, user-requested conference to the system call UI.
final class SystemCallCoordinator: NSObject, CXProviderDelegate, CXCallObserverDelegate {
    var onActivated: (() -> Void)?
    var onEnded: (() -> Void)?
    var onMuteChanged: ((Bool) -> Void)?
    var onHoldChanged: ((Bool) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let provider: CXProvider
    private let controller = CXCallController()
    private var callID: UUID?
    private var isConnected = false
    private var isMuted = true
    private var isHeld = false
    private var heldForAnotherCall = false
    private var holdStartedAt: Date?
    private var resumeRequested = false

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.includesCallsInRecents = false
        configuration.supportedHandleTypes = [.generic]
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: .main)
        controller.callObserver.setDelegate(self, queue: .main)
    }

    func start() {
        guard callID == nil else { return }
        #if DEBUG
        print("System call: requesting start")
        #endif
        let id = UUID()
        callID = id
        isConnected = false
        isMuted = true
        isHeld = false
        heldForAnotherCall = false
        holdStartedAt = nil
        resumeRequested = false
        let handle = CXHandle(type: .generic, value: "Meeting")
        let action = CXStartCallAction(call: id, handle: handle)
        action.isVideo = true
        controller.request(CXTransaction(action: action)) { [weak self] error in
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
        guard isConnected, changed || force else { return }
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: callID, muted: muted))) { error in
            guard let error else { return }
            #if DEBUG
            print("System call: mute update failed: \(error.localizedDescription)")
            #endif
        }
    }

    func end() {
        guard let callID else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: callID))) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                #if DEBUG
                print("System call: end failed: \(error.localizedDescription)")
                #endif
                self?.markEnded(reason: .failed)
                self?.onEnded?()
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
        provider.reportCall(with: callID, endedAt: nil, reason: reason)
    }

    func providerDidReset(_ provider: CXProvider) {
        #if DEBUG
        print("System call: provider reset")
        #endif
        callID = nil
        isConnected = false
        isHeld = false
        heldForAnotherCall = false
        holdStartedAt = nil
        resumeRequested = false
        onEnded?()
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
        callID = nil
        isConnected = false
        action.fulfill()
        onEnded?()
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
        action.fulfill()
        resumeIfPossible()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        #if DEBUG
        print("System call: audio deactivated")
        #endif
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
        guard let callID, isHeld, heldForAnotherCall,
              !hasAnotherActiveCall, !resumeRequested else { return }
        resumeRequested = true
        #if DEBUG
        print("System call: requesting resume after other call")
        #endif
        controller.request(CXTransaction(action: CXSetHeldCallAction(call: callID, onHold: false))) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.resumeRequested = false
                #if DEBUG
                print("System call: resume failed: \(error.localizedDescription)")
                #endif
            }
        }
    }

    private var hasAnotherActiveCall: Bool {
        guard let callID else { return false }
        return controller.callObserver.calls.contains { $0.uuid != callID && !$0.hasEnded }
    }
}
