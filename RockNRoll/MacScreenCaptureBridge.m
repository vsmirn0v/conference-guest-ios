#import "MacScreenCaptureBridge.h"
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <math.h>
#import <TargetConditionals.h>

static NSErrorDomain CaptureErrorDomain;
static NSString *ContentRectKey, *ScaleFactorKey, *ContentScaleKey, *FrameStatusKey;

// Signatures copied from Apple's public macOS ScreenCaptureKit headers. None
// of these selectors depends on an API introduced in macOS/iOS 27.
@interface NSObject (RockMacScreenCaptureABI)
+ (id)sharedPicker;
- (BOOL)isActive;
- (void)setActive:(BOOL)active;
- (void)addObserver:(id)observer;
- (void)removeObserver:(id)observer;
- (void)present;
- (NSInteger)style;
- (CGRect)contentRect;
- (float)pointPixelScale;
- (NSUInteger)width;
- (NSUInteger)height;
- (void)setWidth:(NSUInteger)width;
- (void)setHeight:(NSUInteger)height;
- (void)setCapturesAudio:(BOOL)capturesAudio;
- (void)setPixelFormat:(OSType)format;
- (void)setMinimumFrameInterval:(CMTime)interval;
- (void)setQueueDepth:(NSInteger)depth;
- (id)initWithFilter:(id)filter configuration:(id)configuration delegate:(id)delegate;
- (BOOL)addStreamOutput:(id)output type:(NSInteger)type sampleHandlerQueue:(dispatch_queue_t)queue error:(NSError **)error;
- (BOOL)removeStreamOutput:(id)output type:(NSInteger)type error:(NSError **)error;
- (void)startCaptureWithCompletionHandler:(void (^)(NSError *))completion;
- (void)stopCaptureWithCompletionHandler:(void (^)(NSError *))completion;
- (void)updateConfiguration:(id)configuration completionHandler:(void (^)(NSError *))completion;
@end

@implementation MacScreenCaptureBridge {
    NSObject *_picker;
    NSObject *_stream;
    BOOL _registered, _picking, _stopping;
    NSUInteger _generation, _selection;
    NSMutableArray *_stopCompletions;
    __weak NSObject *_resizingStream;
    NSObject *_resizeConfiguration;
    CGSize _outputSize, _pendingSize;
    NSUInteger _resizeGeneration;
    BOOL _resizeScheduled, _resizeInFlight;
}

static NSError *CaptureError(NSString *message) {
    return [NSError errorWithDomain:@"RockMacScreenCapture" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

+ (BOOL)isSupported {
    #if !TARGET_OS_OSX
    if (!NSProcessInfo.processInfo.isiOSAppOnMac) return NO;
    #endif
    // Keep the system framework resident: instances/callback protocols may
    // outlive an individual capture. dlopen is reference-counted once only.
    static BOOL supported;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *framework = dlopen("/System/Library/Frameworks/ScreenCaptureKit.framework/ScreenCaptureKit", RTLD_LAZY | RTLD_LOCAL);
        if (!framework) return;
        NSString *const __unsafe_unretained *domain = (NSString *const __unsafe_unretained *)dlsym(framework, "SCStreamErrorDomain");
        if (domain) CaptureErrorDomain = *domain;
        NSString *const __unsafe_unretained *rect = (NSString *const __unsafe_unretained *)dlsym(framework, "SCStreamFrameInfoContentRect");
        NSString *const __unsafe_unretained *scale = (NSString *const __unsafe_unretained *)dlsym(framework, "SCStreamFrameInfoScaleFactor");
        NSString *const __unsafe_unretained *contentScale = (NSString *const __unsafe_unretained *)dlsym(framework, "SCStreamFrameInfoContentScale");
        NSString *const __unsafe_unretained *status = (NSString *const __unsafe_unretained *)dlsym(framework, "SCStreamFrameInfoStatus");
        if (rect) ContentRectKey = *rect;
        if (scale) ScaleFactorKey = *scale;
        if (contentScale) ContentScaleKey = *contentScale;
        if (status) FrameStatusKey = *status;
        Class picker = NSClassFromString(@"SCContentSharingPicker");
        Class stream = NSClassFromString(@"SCStream");
        Class config = NSClassFromString(@"SCStreamConfiguration");
        Class filter = NSClassFromString(@"SCContentFilter");
        supported = [picker respondsToSelector:@selector(sharedPicker)] &&
            [picker instancesRespondToSelector:@selector(present)] &&
            [picker instancesRespondToSelector:@selector(isActive)] &&
            [picker instancesRespondToSelector:@selector(setActive:)] &&
            [picker instancesRespondToSelector:@selector(addObserver:)] &&
            [picker instancesRespondToSelector:@selector(removeObserver:)] &&
            [stream instancesRespondToSelector:@selector(initWithFilter:configuration:delegate:)] &&
            [stream instancesRespondToSelector:@selector(addStreamOutput:type:sampleHandlerQueue:error:)] &&
            [stream instancesRespondToSelector:@selector(removeStreamOutput:type:error:)] &&
            [stream instancesRespondToSelector:@selector(startCaptureWithCompletionHandler:)] &&
            [stream instancesRespondToSelector:@selector(stopCaptureWithCompletionHandler:)] &&
            [stream instancesRespondToSelector:@selector(updateConfiguration:completionHandler:)] &&
            [config instancesRespondToSelector:@selector(setWidth:)] &&
            [config instancesRespondToSelector:@selector(setHeight:)] &&
            [config instancesRespondToSelector:@selector(setCapturesAudio:)] &&
            [config instancesRespondToSelector:@selector(setPixelFormat:)] &&
            [config instancesRespondToSelector:@selector(setMinimumFrameInterval:)] &&
            [config instancesRespondToSelector:@selector(setQueueDepth:)] &&
            [filter instancesRespondToSelector:@selector(style)] &&
            [filter instancesRespondToSelector:@selector(contentRect)];
        for (NSString *name in @[@"SCContentSharingPickerObserver", @"SCStreamOutput", @"SCStreamDelegate"]) {
            Protocol *protocol = NSProtocolFromString(name);
            if (!protocol) { supported = NO; break; }
            class_addProtocol(self, protocol);
        }
    });
    return supported;
}

+ (CGSize)outputSizeForContent:(CGSize)content {
    if (!isfinite(content.width) || !isfinite(content.height) || content.width < 2 || content.height < 2) return CGSizeZero;
    double scale = MIN(1, MIN(1920 / content.width, 1080 / content.height));
    return CGSizeMake(MAX(2, floor(content.width * scale / 2) * 2),
                      MAX(2, floor(content.height * scale / 2) * 2));
}

- (void)prepareWindowResizeForStream:(NSObject *)stream configuration:(NSObject *)configuration {
    NSAssert(NSThread.isMainThread, @"Capture lifecycle belongs to the main thread");
    [self invalidateWindowResize];
    [self.class isSupported];
    if (![stream respondsToSelector:@selector(updateConfiguration:completionHandler:)]) return;
    _resizingStream = stream; _resizeConfiguration = configuration;
    _outputSize = CGSizeMake([configuration width], [configuration height]);
    _pendingSize = _outputSize;
}

- (void)invalidateWindowResize {
    NSAssert(NSThread.isMainThread, @"Capture lifecycle belongs to the main thread");
    ++_resizeGeneration;
    _resizingStream = nil; _resizeConfiguration = nil;
    _pendingSize = CGSizeZero; _resizeScheduled = NO; _resizeInFlight = NO;
}

- (void)observeWindowSample:(CMSampleBufferRef)sample {
    if (!_resizingStream || !ContentRectKey || !ScaleFactorKey || !ContentScaleKey || !FrameStatusKey) return;
    NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sample, NO);
    NSDictionary *info = [attachments.firstObject isKindOfClass:NSDictionary.class] ? attachments.firstObject : nil;
    NSNumber *status = info[FrameStatusKey], *scale = info[ScaleFactorKey], *contentScale = info[ContentScaleKey];
    NSDictionary *rectInfo = info[ContentRectKey];
    CGRect rect;
    // Ignore idle/blank/minimized frames; never replace a valid size with zero.
    if (![status isKindOfClass:NSNumber.class] || status.integerValue != 0 ||
        ![scale isKindOfClass:NSNumber.class] || ![contentScale isKindOfClass:NSNumber.class] ||
        ![rectInfo isKindOfClass:NSDictionary.class] ||
        !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)rectInfo, &rect)) return;
    [self observeWindowContentRect:rect scaleFactor:scale.doubleValue contentScale:contentScale.doubleValue];
}

- (void)observeWindowContentRect:(CGRect)rect scaleFactor:(double)scaleFactor contentScale:(double)contentScale {
    NSAssert(NSThread.isMainThread, @"Capture lifecycle belongs to the main thread");
    if (!_resizingStream || !isfinite(scaleFactor) || scaleFactor <= 0 ||
        !isfinite(contentScale) || contentScale <= 0) return;
    // Apple reports contentRect in surface points. Undo both backing scale and
    // hardware content scaling to recover the window's native pixel dimensions.
    CGSize size = [self.class outputSizeForContent:CGSizeMake(rect.size.width * scaleFactor / contentScale,
                                                             rect.size.height * scaleFactor / contentScale)];
    if (CGSizeEqualToSize(size, CGSizeZero)) return;
    _pendingSize = size;
    [self scheduleWindowResize];
}

- (void)scheduleWindowResize {
    if (!_resizingStream || _resizeScheduled || _resizeInFlight || CGSizeEqualToSize(_pendingSize, _outputSize)) return;
    _resizeScheduled = YES;
    NSUInteger attempt = _resizeGeneration;
    // One newest size, at most three updates per second. Updating on every frame
    // during a drag would repeatedly reallocate capture/encoder surfaces.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (attempt != self->_resizeGeneration) return;
        self->_resizeScheduled = NO;
        NSObject *stream = self->_resizingStream;
        CGSize requested = self->_pendingSize;
        if (!stream || self->_resizeInFlight || CGSizeEqualToSize(requested, self->_outputSize)) return;
        self->_resizeInFlight = YES;
        [self->_resizeConfiguration setWidth:(NSUInteger)requested.width];
        [self->_resizeConfiguration setHeight:(NSUInteger)requested.height];
        [stream updateConfiguration:self->_resizeConfiguration completionHandler:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (attempt != self->_resizeGeneration || stream != self->_resizingStream) return;
                self->_resizeInFlight = NO;
                if (!error) self->_outputSize = requested;
                else {
                    // Keep the working stream. Retry only on new frame evidence,
                    // rather than looping forever against a retired/error stream.
                    self->_pendingSize = self->_outputSize;
                }
                [self scheduleWindowResize];
            });
        }];
    });
}

- (BOOL)presentWithError:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Capture lifecycle belongs to the main thread");
    if (![self.class isSupported]) {
        if (error) *error = CaptureError(@"Screen capture is unavailable on this Mac.");
        return NO;
    }
    if (_stopping) {
        if (error) *error = CaptureError(@"The previous screen capture is still stopping.");
        return NO;
    }
    if (_picking) return YES;
    if (!_picker) _picker = [NSClassFromString(@"SCContentSharingPicker") sharedPicker];
    if ([_picker isActive] && !_registered) {
        if (error) *error = CaptureError(@"Another screen-sharing chooser is open.");
        return NO;
    }
    if (!_stream) ++_generation;
    _picking = YES;
    if (!_registered) { [_picker addObserver:self]; _registered = YES; }
    [_picker setActive:YES]; [_picker present];
    return YES;
}

- (void)releasePicker {
    _picking = NO;
    if (_stream || !_registered) return;
    _registered = NO;
    [_picker removeObserver:self]; [_picker setActive:NO];
}

- (void)stopWithCompletionHandler:(void (^)(NSError *))completion {
    NSAssert(NSThread.isMainThread, @"Capture lifecycle belongs to the main thread");
    if (!_stopCompletions) _stopCompletions = [NSMutableArray array];
    [_stopCompletions addObject:[completion copy]];
    if (_stopping) return;
    _stopping = YES;
    [self invalidateWindowResize];
    ++_generation; ++_selection;
    NSObject *retired = _stream; _stream = nil;
    [self releasePicker];
    if (!retired) { [self finishStop:nil]; return; }
    [retired stopCaptureWithCompletionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [retired removeStreamOutput:self type:0 error:nil];
            [self finishStop:error];
        });
    }];
}

- (void)finishStop:(NSError *)error {
    _stopping = NO;
    NSArray *callbacks = [_stopCompletions copy]; [_stopCompletions removeAllObjects];
    for (void (^callback)(NSError *) in callbacks) callback(error);
}

- (void)contentSharingPicker:(id)picker didUpdateWithFilter:(NSObject *)filter forStream:(id)oldStream {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (picker != self->_picker || (!self->_picking && !self->_stream)) return;
        NSUInteger generation = self->_generation, selection = ++self->_selection;
        [self invalidateWindowResize];
        NSObject *retired = self->_stream; self->_stream = nil;
        void (^start)(void) = ^{
            if (generation != self->_generation || selection != self->_selection) return;
            [self captureFilter:filter generation:generation selection:selection];
        };
        if (retired) {
            [retired stopCaptureWithCompletionHandler:^(NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [retired removeStreamOutput:self type:0 error:nil];
                    if (self.onEffect) self.onEffect(NO);
                    start();
                });
            }];
        } else start();
    });
}

- (void)captureFilter:(NSObject *)filter generation:(NSUInteger)generation selection:(NSUInteger)selection {
    _sourceStyle = [filter style];
    NSObject *config = [[NSClassFromString(@"SCStreamConfiguration") alloc] init];
    CGSize content = [filter contentRect].size;
    double scale = [filter respondsToSelector:@selector(pointPixelScale)] ? [filter pointPixelScale] : 1;
    CGSize size = [self.class outputSizeForContent:CGSizeMake(content.width * scale, content.height * scale)];
    if (CGSizeEqualToSize(size, CGSizeZero)) size = CGSizeMake(1920, 1080);
    [config setWidth:(NSUInteger)size.width]; [config setHeight:(NSUInteger)size.height];
    [config setCapturesAudio:NO]; [config setPixelFormat:kCVPixelFormatType_32BGRA];
    [config setMinimumFrameInterval:CMTimeMake(1, 30)]; [config setQueueDepth:3];
    NSObject *capture = [[NSClassFromString(@"SCStream") alloc] initWithFilter:filter configuration:config delegate:self];
    _stream = capture;
    if (_sourceStyle == 1) [self prepareWindowResizeForStream:capture configuration:config];
    NSError *error;
    if (![capture addStreamOutput:self type:0 sampleHandlerQueue:dispatch_get_main_queue() error:&error]) {
        [self fail:error ?: CaptureError(@"Could not attach screen capture output.")]; return;
    }
    [capture startCaptureWithCompletionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_generation || selection != self->_selection) {
                [capture stopCaptureWithCompletionHandler:^(NSError *ignored) {
                    dispatch_async(dispatch_get_main_queue(), ^{ [capture removeStreamOutput:self type:0 error:nil]; });
                }]; return;
            }
            if (error) { [self fail:error]; return; }
            [self releasePicker];
            if (self.onSelection) self.onSelection([filter style]);
        });
    }];
}

- (void)fail:(NSError *)error {
    [self stopWithCompletionHandler:^(NSError *ignored) { if (self.onEnd) self.onEnd(error); }];
}
- (void)contentSharingPicker:(id)picker didCancelForStream:(id)stream {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (picker != self->_picker || !self->_registered) return;
        [self releasePicker];
        if (self.onSelection) self.onSelection(-1);
        if (!self->_stream && self.onEnd) self.onEnd(nil);
    });
}
- (void)contentSharingPickerStartDidFailWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{ if (self->_picking) [self fail:error]; });
}
- (void)stream:(id)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(NSInteger)type {
    // The stream's output queue is main. Forward immediately, without copying
    // frame pixels or scheduling an unbounded queue of per-frame blocks.
    if (stream != _stream || type != 0 || !CMSampleBufferIsValid(sample) || !CMSampleBufferGetImageBuffer(sample)) return;
    [self observeWindowSample:sample];
    if (self.onFrame) self.onFrame(sample);
}
- (void)stream:(id)stream didStopWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (stream != self->_stream) return;
        [self invalidateWindowResize];
        self->_stream = nil; ++self->_generation; ++self->_selection;
        [stream removeStreamOutput:self type:0 error:nil];
        [self releasePicker];
        // SCStreamErrorUserStopped has been public since macOS 12.3.
        if (self.onEnd) self.onEnd([error.domain isEqualToString:CaptureErrorDomain] && error.code == -3817 ? nil : error);
    });
}
- (void)outputVideoEffectDidStartForStream:(id)stream {
    dispatch_async(dispatch_get_main_queue(), ^{ if (stream == self->_stream && self.onEffect) self.onEffect(YES); });
}
- (void)outputVideoEffectDidStopForStream:(id)stream {
    dispatch_async(dispatch_get_main_queue(), ^{ if (stream == self->_stream && self.onEffect) self.onEffect(NO); });
}
@end
