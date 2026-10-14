#import "MacInputMuteBridge.h"
#import <AVFAudio/AVFAudio.h>
#import <dlfcn.h>

@protocol RockMacAudioApplication <NSObject>
- (BOOL)setInputMuteStateChangeHandler:(BOOL (^ _Nullable)(BOOL))handler error:(NSError **)error;
@end

static void (*captureSet)(int);
static int (*captureGet)(void);
static void ResolveCaptureGate(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        captureSet = dlsym(RTLD_DEFAULT, "RTCSetApplicationCaptureMuted");
        captureGet = dlsym(RTLD_DEFAULT, "RTCApplicationCaptureMuted");
    });
}
BOOL RockMacInputMuteAvailable(void) {
    ResolveCaptureGate();
    if (@available(iOS 17.0, *)) {
        return NSProcessInfo.processInfo.isiOSAppOnMac && captureSet && captureGet &&
            [AVAudioApplication.sharedInstance respondsToSelector:@selector(setInputMuteStateChangeHandler:error:)];
    }
    return NO;
}
BOOL RockMacInputMuteSet(BOOL muted) {
    ResolveCaptureGate();
    if (!captureSet) return NO;
    captureSet(muted ? 1 : 0);
    return YES;
}
BOOL RockMacInputMuteIsMuted(void) {
    ResolveCaptureGate();
    return captureGet && captureGet() != 0;
}
BOOL RockMacInputMuteRegister(BOOL enabled) {
    if (!RockMacInputMuteAvailable()) return NO;
    if (@available(iOS 17.0, *)) {
        BOOL (^handler)(BOOL) = enabled ? ^BOOL(BOOL muted) {
            // This callback may run off-main. Gate PCM before acknowledging it;
            // UIKit and the SDK's network state follow through the notification.
            // Never open capture from an unvalidated/stale callback. The
            // notification must first pass the current meeting/private owner's
            // checks. A programmatic unmute has already opened the gate.
            if (muted) return RockMacInputMuteSet(YES);
            return captureSet != NULL;
        } : nil;
        NSError *error = nil;
        BOOL success = [(id<RockMacAudioApplication>)AVAudioApplication.sharedInstance
            setInputMuteStateChangeHandler:handler error:&error];
        if (!success) NSLog(@"Mac input mute registration failed: %@", error);
        return success;
    }
    return NO;
}
