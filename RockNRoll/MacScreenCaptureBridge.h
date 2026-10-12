#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

/// Public macOS 14 ScreenCaptureKit ABI, loaded only inside the Mac host.
/// Deliberately independent of the iOS 27 ScreenCaptureKit declarations.
@interface MacScreenCaptureBridge : NSObject
+ (BOOL)isSupported;
/// Native source pixels, fit within 1920x1080 without upscaling.
+ (CGSize)outputSizeForContent:(CGSize)content NS_SWIFT_NAME(outputSize(for:));
/// Public Mac timing properties missing from UIKit's ScreenCaptureKit surface.
+ (void)configureTiming:(NSObject *)configuration fps:(NSInteger)fps queueDepth:(NSInteger)depth;
/// Shared by the macOS compatibility and UIKit capture paths on the Mac host.
- (void)prepareWindowResizeForStream:(NSObject *)stream configuration:(NSObject *)configuration;
- (void)observeWindowSample:(CMSampleBufferRef)sample;
- (void)observeWindowContentRect:(CGRect)rect scaleFactor:(double)scaleFactor contentScale:(double)contentScale;
- (void)invalidateWindowResize;
@property(nonatomic, readonly) NSInteger sourceStyle;
@property(nonatomic, copy, nullable) void (^onFrame)(CMSampleBufferRef sample);
@property(nonatomic, copy, nullable) void (^onSelection)(NSInteger sourceStyle);
@property(nonatomic, copy, nullable) void (^onEffect)(BOOL enabled);
@property(nonatomic, copy, nullable) void (^onEnd)(NSError * _Nullable error);
- (BOOL)presentWithError:(NSError **)error NS_SWIFT_NAME(present());
- (void)stopWithCompletionHandler:(void (^)(NSError * _Nullable))completion NS_SWIFT_NAME(stop(completion:));
@end

NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN
/// Main-thread ownership of asynchronous starts/stops, shared by both adapters.
@interface ScreenCaptureLifecycle : NSObject
- (void)startStream:(NSObject *)stream output:(NSObject *)output completion:(void (^)(NSError * _Nullable))completion;
- (void)retireStream:(NSObject *)stream output:(NSObject *)output completion:(void (^)(NSError * _Nullable))completion;
- (void)drain:(void (^)(void))completion;
@end

@class ScreenCapturePickerSession;
/// One observer routes a system selection only to the requesting capture.
@interface ScreenCapturePickerCoordinator : NSObject
+ (instancetype)sharedCoordinator;
- (instancetype)initWithPicker:(NSObject *)picker;
- (void)contentSharingPicker:(NSObject *)picker didUpdateWithFilter:(NSObject *)filter forStream:(nullable NSObject *)stream;
- (void)contentSharingPicker:(NSObject *)picker didCancelForStream:(nullable NSObject *)stream;
- (void)contentSharingPickerStartDidFailWithError:(NSError *)error;
@end
@interface ScreenCapturePickerSession : NSObject
@property(atomic, weak, nullable) NSObject *stream;
@property(nonatomic, copy, nullable) void (^onFilter)(NSObject *filter);
@property(nonatomic, copy, nullable) void (^onCancel)(void);
@property(nonatomic, copy, nullable) void (^onError)(NSError *error);
- (instancetype)initWithCoordinator:(ScreenCapturePickerCoordinator *)coordinator;
- (BOOL)presentWithError:(NSError **)error NS_SWIFT_NAME(present());
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
