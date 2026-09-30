import ConferenceCore
import Foundation
import UIKit

extension ConferenceModel {
    func makeContinuationCoordinator(preferences: UserDefaults = .standard) -> MeetingContinuationCoordinator {
        let device = ProcessInfo.processInfo.isiOSAppOnMac ? "Mac" :
            (UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")
        let coordinator = MeetingContinuationCoordinator(deviceID: sync.deviceID, deviceLabel: device, preferences: preferences)
        coordinator.onPrepareSource = { [weak self] id in
            guard let self else { throw ContinuationError.expired }
            try await self.holdForContinuation(id, held: true, restoreSending: true)
        }
        coordinator.onResumeSource = { [weak self] id, restore in
            try? await self?.holdForContinuation(id, held: false, restoreSending: restore)
        }
        coordinator.onLeaveSource = { [weak self] id, label in
            guard let self else { return false }
            let left = await self.leaveForContinuation(id)
            if left { self.updateContinuationActivity() }
            return left
        }
        coordinator.onJoinTarget = { [weak self] jam, quiet in self?.joinFromContinuation(jam, quiet: quiet) }
        coordinator.onCancelTarget = { [weak self] url, id in await self?.cancelContinuationTarget(url, sessionID: id) ?? true }
        coordinator.onSnapshot = { [weak self] in self?.continuationSnapshot() }
        coordinator.onActivityChanged = { [weak self] in
            Task { @MainActor [weak self] in self?.updateContinuationActivity() }
        }
        coordinator.onStatus = { [weak self] _, _ in self?.refreshContinuationBanner() }
        sync.onCloudAccessChanged = { [weak coordinator] account in coordinator?.setCloudAccount(account) }
        sync.beforeDeleteSyncedData = { [weak coordinator] in try await coordinator?.deleteCloudData() }
        coordinator.setCloudAccount(sync.cloudAccount)
        return coordinator
    }
    func refreshContinuationBanner() {
        guard isInConference || isJoining else {
            continuationBanner.show(nil, in: nil); return
        }
        let text = continuation.status
        if companionAudioPaused && isInConference {
            continuationBanner.show("Joined alongside the other device. Audio, microphone and camera are off.",
                                    in: continuationHostView, button: "Enable audio here") { [weak self] in self?.enableCompanionAudio() }
        } else if continuation.needsManualResume {
            continuationBanner.show(text, in: continuationHostView, button: "Resume here") { [weak self] in self?.continuation.resumeHere() }
        } else if continuation.moving {
            continuationBanner.show(text, in: continuationHostView, button: continuation.moveActionTitle) { [weak self] in self?.continuation.cancel() }
        } else {
            continuationBanner.show(isInConference ? text : nil, in: continuationHostView,
                                    autoDismiss: !continuation.waitingForMove)
        }
    }
    func updateContinuationActivity() {
        guard continuation.isAvailable, let jam = continuationSnapshot() else {
            currentContinuationActivity?.invalidate(); currentContinuationActivity = nil; return
        }
        let activity = currentContinuationActivity ?? NSUserActivity(activityType: "dev.vsmirn0v.conferenceguest.continue-jam")
        activity.title = "Continue jam"
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false; activity.isEligibleForPublicIndexing = false
        activity.expirationDate = Date().addingTimeInterval(180)
        // Only opaque IDs enter Handoff. The complete invitation comes from private CloudKit.
        activity.userInfo = ["device": jam.deviceID, "session": jam.sessionID.uuidString]
        activity.requiredUserInfoKeys = ["device", "session"]
        activity.becomeCurrent(); currentContinuationActivity = activity
    }
    func receiveContinuationActivity(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == "dev.vsmirn0v.conferenceguest.continue-jam" else { return false }
        continuation.setForeground(true)
        // Present a continuation choice; system discovery never starts a call automatically.
        return true
    }
}
