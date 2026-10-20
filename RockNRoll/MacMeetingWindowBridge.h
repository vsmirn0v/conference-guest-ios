#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
/// Public AppKit selectors, resolved only in the Designed-for-iPad Mac runtime.
@interface RockMacMeetingWindowBridge : NSObject
- (instancetype)initWithWindow:(nullable UIWindow *)window action:(void (^)(NSString *action))action;
- (BOOL)bindMainWindow;
- (void)updateActive:(BOOL)active title:(NSString *)title microphoneOn:(BOOL)microphoneOn
              menu:(NSArray<NSDictionary *> *)items;
- (void)showMeeting;
- (BOOL)hideMeeting;
- (void)closeMeetingWindow;
- (void)markVisible;
- (void)invalidate;
@property(nonatomic, readonly) BOOL hiddenForMeeting;
@property(nonatomic, readonly) BOOL visibleForReminders;
#if DEBUG
- (void)closeForTesting;
- (void)closeThroughDelegateForTesting;
- (NSDictionary *)stateForTesting;
- (BOOL)invokeMenuActionForTesting:(NSString *)action NS_SWIFT_NAME(invokeMenuActionForTesting(_:));
#endif
@end

#if DEBUG
FOUNDATION_EXPORT NSDictionary *RockMacMeetingBridgeDiagnostics(void);
FOUNDATION_EXPORT BOOL RockMacMeetingProxyQualification(void);
FOUNDATION_EXPORT BOOL RockMacMeetingCloseButtonQualification(void);
FOUNDATION_EXPORT BOOL RockMacMeetingVisibilityQualification(void);
#endif
NS_ASSUME_NONNULL_END
