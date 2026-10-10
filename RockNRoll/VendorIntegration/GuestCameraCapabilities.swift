import JazzSDK

/// Use the pinned SDK's public multitasking-camera initializer. Its system PiP
/// stays disabled because the app owns the single floating-video controller.
enum GuestCameraCapabilities {
    static var flags: JazzFeatureFlags {
        let base = JazzFeatureFlags.allDisabled
        return JazzFeatureFlags(conferenceNewAsrOn: base.conferenceNewAsrOn,
            arePollsEnabled: base.arePollsEnabled, isVideoCallCloudRecordingEnabled: base.isVideoCallCloudRecordingEnabled,
            isCallKitSupported: base.isCallKitSupported, isSessionGroupsEnabled: base.isSessionGroupsEnabled,
            isSessionGroupsAdminEnabled: base.isSessionGroupsAdminEnabled,
            isSystemPiPEnabled: base.isSystemPiPEnabled, canSystemPiPUseCamera: true,
            isRestreamEnabled: base.isRestreamEnabled, conferenceOverlayHidingStrategy: base.conferenceOverlayHidingStrategy,
            isJazzNextViewerWebinarEnabled: base.isJazzNextViewerWebinarEnabled,
            isJazzNextSpeakerWebinarEnabled: base.isJazzNextSpeakerWebinarEnabled, isCoOwnerEnabled: base.isCoOwnerEnabled,
            isMaxTilesEnabled: base.isMaxTilesEnabled, isSipEnabled: base.isSipEnabled, isMediaStatsVisible: base.isMediaStatsVisible,
            isShareInvitationEnabled: base.isShareInvitationEnabled, enablingModeratorsInConferencesOn: base.enablingModeratorsInConferencesOn,
            isQRTransferEnabled: base.isQRTransferEnabled, isChatMenuAvailable: base.isChatMenuAvailable,
            isSoundNormalizationEnabled: base.isSoundNormalizationEnabled, isMicPowerObserverEnabled: base.isMicPowerObserverEnabled)
    }
}
