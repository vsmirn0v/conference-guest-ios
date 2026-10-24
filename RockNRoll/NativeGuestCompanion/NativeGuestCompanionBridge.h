#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Public AppKit and Security APIs loaded only for an iOS app running on Mac.
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
