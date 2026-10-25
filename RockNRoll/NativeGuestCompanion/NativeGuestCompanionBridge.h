#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Internal Mac-host adapter; unavailable unless ROCK_NATIVE_GUEST_COMPANION=1.
@interface NativeGuestCompanionBridge : NSObject
+ (BOOL)isSupported;
+ (nullable NSURL *)validatedApplicationURLWithError:(NSError **)error NS_SWIFT_NAME(validatedApplicationURL());
- (void)launchSession:(NSUUID *)sessionID completion:(void (^)(int32_t processIdentifier, NSError * _Nullable error))completion;
- (void)show;
/// Targets only the process instance returned by this object's launch request.
- (BOOL)terminateLaunchedApplication;
@property(nonatomic, readonly) int32_t processIdentifier;
@property(nonatomic, readonly) BOOL launchedApplicationTerminated;
@end

NS_ASSUME_NONNULL_END
