#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN
/// Test target only: captures one generated window belonging to this process.
@interface OwnedWindowCaptureFixture : NSObject
@property(nonatomic, copy, nullable) void (^onFrame)(CMSampleBufferRef sample);
@property(nonatomic, copy, nullable) void (^onSelected)(void);
@property(nonatomic, copy, nullable) void (^onStarting)(void);
@property(nonatomic, copy, nullable) void (^onEnd)(NSError *error);
@property(nonatomic, readonly) NSUInteger frames;
@property(nonatomic, readonly) NSUInteger changes;
@property(nonatomic, readonly) BOOL starting;
- (void)start;
- (void)stopWithCompletion:(void (^)(void))completion NS_SWIFT_NAME(stop(completion:));
@end
NS_ASSUME_NONNULL_END
