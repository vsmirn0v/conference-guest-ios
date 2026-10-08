#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

/// Public macOS 14 ScreenCaptureKit ABI, loaded only inside the Mac host.
/// Deliberately independent of the iOS 27 ScreenCaptureKit declarations.
@interface MacScreenCaptureBridge : NSObject
+ (BOOL)isSupported;
@property(nonatomic, readonly) NSInteger sourceStyle;
@property(nonatomic, copy, nullable) void (^onFrame)(CMSampleBufferRef sample);
@property(nonatomic, copy, nullable) void (^onSelection)(NSInteger sourceStyle);
@property(nonatomic, copy, nullable) void (^onEffect)(BOOL enabled);
@property(nonatomic, copy, nullable) void (^onEnd)(NSError * _Nullable error);
- (BOOL)presentWithError:(NSError **)error NS_SWIFT_NAME(present());
- (void)stopWithCompletionHandler:(void (^)(NSError * _Nullable))completion NS_SWIFT_NAME(stop(completion:));
@end

NS_ASSUME_NONNULL_END
