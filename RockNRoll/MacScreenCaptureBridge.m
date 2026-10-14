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
- (void)presentPickerForStream:(NSObject *)stream;
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
- (void)setScalesToFit:(BOOL)enabled;
- (void)setPreservesAspectRatio:(BOOL)enabled;
- (void)setIgnoreShadowsSingleWindow:(BOOL)enabled;
- (void)setIgnoreGlobalClipSingleWindow:(BOOL)enabled;
- (id)initWithFilter:(id)filter configuration:(id)configuration delegate:(id)delegate;
- (BOOL)addStreamOutput:(id)output type:(NSInteger)type sampleHandlerQueue:(dispatch_queue_t)queue error:(NSError **)error;
- (BOOL)removeStreamOutput:(id)output type:(NSInteger)type error:(NSError **)error;
- (void)startCaptureWithCompletionHandler:(void (^)(NSError *))completion;
- (void)stopCaptureWithCompletionHandler:(void (^)(NSError *))completion;
- (void)updateConfiguration:(id)configuration completionHandler:(void (^)(NSError *))completion;
@end


@interface CaptureOperation : NSObject
@property NSObject *stream, *output;
@property BOOL starting, retiring, stopping;
@property NSMutableArray *completions;
@end
@implementation CaptureOperation
@end
@implementation ScreenCaptureLifecycle {
    NSMapTable<NSObject *, CaptureOperation *> *_operations;
    NSMutableArray *_waiters;
}
- (instancetype)init {
    if ((self = [super init])) {
        _operations = [NSMapTable strongToStrongObjectsMapTable]; _waiters = [NSMutableArray array];
    }
    return self;
}
- (CaptureOperation *)operation:(NSObject *)stream output:(NSObject *)output {
    NSAssert(NSThread.isMainThread, @"Capture lifecycle belongs to the main thread");
    CaptureOperation *operation = [_operations objectForKey:stream];
    if (!operation) {
        operation = [CaptureOperation new]; operation.stream = stream; operation.output = output;
        operation.completions = [NSMutableArray array]; [_operations setObject:operation forKey:stream];
    }
    return operation;
}
- (void)startStream:(NSObject *)stream output:(NSObject *)output completion:(void (^)(NSError *))completion {
    CaptureOperation *operation = [self operation:stream output:output]; operation.starting = YES;
    [stream startCaptureWithCompletionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            operation.starting = NO;
            completion(error);
            if (operation.retiring) [self stopOperation:operation];
        });
    }];
}
- (void)retireStream:(NSObject *)stream output:(NSObject *)output completion:(void (^)(NSError *))completion {
    CaptureOperation *operation = [self operation:stream output:output];
    [operation.completions addObject:[completion copy]]; operation.retiring = YES;
    [self stopOperation:operation];
}
- (void)stopOperation:(CaptureOperation *)operation {
    if (operation.starting || operation.stopping) return;
    operation.stopping = YES;
    [operation.stream stopCaptureWithCompletionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [operation.stream removeStreamOutput:operation.output type:0 error:nil];
            [self->_operations removeObjectForKey:operation.stream];
            NSArray *callbacks = [operation.completions copy]; [operation.completions removeAllObjects];
            for (void (^callback)(NSError *) in callbacks) callback(error);
            if (self->_operations.count == 0) {
                NSArray *waiters = [self->_waiters copy]; [self->_waiters removeAllObjects];
                for (void (^waiter)(void) in waiters) waiter();
            }
        });
    }];
}
- (void)drain:(void (^)(void))completion {
    NSAssert(NSThread.isMainThread, @"Capture lifecycle belongs to the main thread");
    if (_operations.count == 0) completion(); else [_waiters addObject:[completion copy]];
}
@end

@interface ScreenCapturePickerCoordinator ()
- (BOOL)present:(ScreenCapturePickerSession *)session error:(NSError **)error;
- (void)remove:(ScreenCapturePickerSession *)session;
@end
@interface ScreenCapturePickerSession ()
@property NSUInteger selectionGeneration;
@end
@implementation ScreenCapturePickerSession {
    ScreenCapturePickerCoordinator *_coordinator;
}
- (instancetype)init { return [self initWithCoordinator:ScreenCapturePickerCoordinator.sharedCoordinator]; }
- (instancetype)initWithCoordinator:(ScreenCapturePickerCoordinator *)coordinator {
    if ((self = [super init])) _coordinator = coordinator;
    return self;
}
- (BOOL)presentWithError:(NSError **)error { return [_coordinator present:self error:error]; }
- (void)invalidate { self.selectionGeneration += 1; [_coordinator remove:self]; self.stream = nil; }
@end
@implementation ScreenCapturePickerCoordinator {
    NSObject *_picker;
    NSHashTable<ScreenCapturePickerSession *> *_sessions;
    NSLock *_routingLock;
    __weak ScreenCapturePickerSession *_pending;
    BOOL _registered;
}
+ (instancetype)sharedCoordinator {
    static ScreenCapturePickerCoordinator *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [MacScreenCaptureBridge isSupported];
        Protocol *observer = NSProtocolFromString(@"SCContentSharingPickerObserver");
        if (observer) class_addProtocol(self, observer);
        shared = [[self alloc] initWithPicker:[NSClassFromString(@"SCContentSharingPicker") sharedPicker]];
    });
    return shared;
}
- (instancetype)initWithPicker:(NSObject *)picker {
    if ((self = [super init])) { _picker = picker; _sessions = [NSHashTable weakObjectsHashTable]; _routingLock = [NSLock new]; }
    return self;
}
- (BOOL)present:(ScreenCapturePickerSession *)session error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Capture selection belongs to the main thread");
    [_routingLock lock];
    BOOL busy = _pending && _pending != session, alreadyPending = _pending == session;
    [_routingLock unlock];
    if (!_picker || busy || ([_picker isActive] && !_registered)) {
        if (error) *error = [NSError errorWithDomain:@"RockScreenPicker" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Another screen-sharing chooser is open."}];
        return NO;
    }
    if (alreadyPending) return YES;
    [_routingLock lock];
    ++session.selectionGeneration; [_sessions addObject:session]; _pending = session;
    [_routingLock unlock];
    if (!_registered) { [_picker addObserver:self]; _registered = YES; }
    [_picker setActive:YES];
    if (session.stream && [_picker respondsToSelector:@selector(presentPickerForStream:)]) [_picker presentPickerForStream:session.stream];
    else [_picker present];
    return YES;
}
- (void)remove:(ScreenCapturePickerSession *)session {
    [_routingLock lock];
    if (_pending == session) _pending = nil;
    [_sessions removeObject:session];
    BOOL unregister = _registered && _sessions.count == 0;
    if (unregister) _registered = NO;
    [_routingLock unlock];
    if (unregister) { [_picker removeObserver:self]; [_picker setActive:NO]; }
}
- (ScreenCapturePickerSession *)sessionForStream:(NSObject *)stream {
    if (!stream) return _pending;
    for (ScreenCapturePickerSession *session in _sessions) if (session.stream == stream) return session;
    return nil;
}
// Snapshot routing at callback receipt. Never synchronously wait for main
// from a framework callback: main may itself be inside a capture operation.
- (void)deliverForStream:(NSObject *)stream action:(void (^)(ScreenCapturePickerSession *))action {
    [_routingLock lock];
    ScreenCapturePickerSession *session = [self sessionForStream:stream];
    NSUInteger generation = session.selectionGeneration;
    if (_pending == session) _pending = nil;
    [_routingLock unlock];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_routingLock lock]; BOOL registered = session && [self->_sessions containsObject:session]; [self->_routingLock unlock];
        if (session && registered && session.selectionGeneration == generation) action(session);
    });
}
- (void)contentSharingPicker:(NSObject *)picker didUpdateWithFilter:(NSObject *)filter forStream:(NSObject *)stream {
    if (picker != _picker) return;
    [self deliverForStream:stream action:^(ScreenCapturePickerSession *session) { if (session.onFilter) session.onFilter(filter); }];
}
- (void)contentSharingPicker:(NSObject *)picker didCancelForStream:(NSObject *)stream {
    if (picker != _picker) return;
    [self deliverForStream:stream action:^(ScreenCapturePickerSession *session) { if (session.onCancel) session.onCancel(); }];
}
- (void)contentSharingPickerStartDidFailWithError:(NSError *)error {
    [self deliverForStream:nil action:^(ScreenCapturePickerSession *session) { if (session.onError) session.onError(error); }];
}
@end

@implementation MacScreenCaptureBridge {
    NSObject *_stream;
    ScreenCapturePickerSession *_pickerSession;
    ScreenCaptureLifecycle *_lifecycle;
    BOOL _picking, _stopping;
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

- (instancetype)init {
    if ((self = [super init])) _lifecycle = [ScreenCaptureLifecycle new];
    return self;
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
    // Text loses its fine strokes when Retina pixels are discarded before the
    // encoder. Preserve native detail, bounded by a 4K pixel budget and edge.
    // Divide square roots separately to avoid overflowing width * height.
    double scale = MIN(1, MIN(3840 / MAX(content.width, content.height),
                             sqrt(3840.0 * 2160.0) / sqrt(content.width) / sqrt(content.height)));
    return CGSizeMake(MAX(2, floor(content.width * scale / 2) * 2),
                      MAX(2, floor(content.height * scale / 2) * 2));
}

- (CGSize)captureSizeForContent:(CGSize)content {
    if (self.preserveDetail) return [self.class outputSizeForContent:content];
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
    CGSize size = [self captureSizeForContent:CGSizeMake(rect.size.width * scaleFactor / contentScale,
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
    if (!_pickerSession) {
        _pickerSession = [ScreenCapturePickerSession new];
        __weak typeof(self) weakSelf = self;
        _pickerSession.onFilter = ^(NSObject *filter) { [weakSelf selectFilter:filter]; };
        _pickerSession.onCancel = ^{ [weakSelf selectionCancelled]; };
        _pickerSession.onError = ^(NSError *error) { [weakSelf fail:error]; };
    }
    if (!_stream) ++_generation;
    _picking = YES; _pickerSession.stream = _stream;
    if (![_pickerSession presentWithError:error]) { _picking = NO; return NO; }
    return YES;
}

- (void)releasePicker {
    _picking = NO;
    if (!_stream) [_pickerSession invalidate];
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
    if (retired) [_lifecycle retireStream:retired output:self completion:^(NSError *error) {}];
    // Includes a stream already retiring during source replacement/startup.
    [_lifecycle drain:^{ [self finishStop:nil]; }];
}

- (void)finishStop:(NSError *)error {
    _stopping = NO;
    NSArray *callbacks = [_stopCompletions copy]; [_stopCompletions removeAllObjects];
    for (void (^callback)(NSError *) in callbacks) callback(error);
}

+ (void)configureTiming:(NSObject *)configuration fps:(NSInteger)fps queueDepth:(NSInteger)depth {
    if ([configuration respondsToSelector:@selector(setMinimumFrameInterval:)] && [configuration respondsToSelector:@selector(setQueueDepth:)]) {
        [configuration setMinimumFrameInterval:CMTimeMake(1, (int32_t)MAX(1, MIN(60, fps)))];
        [configuration setQueueDepth:MAX(3, MIN(8, depth))];
    }
}
+ (void)configureWindow:(NSObject *)configuration sourceStyle:(NSInteger)sourceStyle {
    if (sourceStyle != 1) return; // SCShareableContentStyleWindow
    // Keep the picker-authorized window filter. Fit its content rather than
    // forwarding desktop placement/shadow padding during window transitions.
    // These public macOS selectors are absent from UIKit's declarations.
    if ([configuration respondsToSelector:@selector(setScalesToFit:)]) [configuration setScalesToFit:YES];
    if ([configuration respondsToSelector:@selector(setPreservesAspectRatio:)]) [configuration setPreservesAspectRatio:YES];
    if ([configuration respondsToSelector:@selector(setIgnoreShadowsSingleWindow:)]) [configuration setIgnoreShadowsSingleWindow:YES];
    if ([configuration respondsToSelector:@selector(setIgnoreGlobalClipSingleWindow:)]) [configuration setIgnoreGlobalClipSingleWindow:YES];
}
- (void)selectFilter:(NSObject *)filter {
    if (!_picking && !_stream) return;
    NSUInteger generation = _generation, selection = ++_selection;
    [self invalidateWindowResize];
    NSObject *retired = _stream; _stream = nil;
    void (^start)(NSError *) = ^(NSError *error) {
        if (generation != self->_generation || selection != self->_selection) return;
        if (self.onEffect) self.onEffect(NO);
        [self captureFilter:filter generation:generation selection:selection];
    };
    if (retired) [_lifecycle retireStream:retired output:self completion:start];
    else start(nil);
}

- (void)captureFilter:(NSObject *)filter generation:(NSUInteger)generation selection:(NSUInteger)selection {
    if (generation != _generation || selection != _selection || _stopping) return;
    _sourceStyle = [filter style];
    NSObject *config = [[NSClassFromString(@"SCStreamConfiguration") alloc] init];
    CGSize content = [filter contentRect].size;
    double scale = [filter respondsToSelector:@selector(pointPixelScale)] ? [filter pointPixelScale] : 1;
    CGSize size = [self captureSizeForContent:CGSizeMake(content.width * scale, content.height * scale)];
    if (CGSizeEqualToSize(size, CGSizeZero)) size = CGSizeMake(1920, 1080);
    [config setWidth:(NSUInteger)size.width]; [config setHeight:(NSUInteger)size.height];
    [config setCapturesAudio:NO]; [config setPixelFormat:kCVPixelFormatType_32BGRA];
    [self.class configureTiming:config fps:30 queueDepth:3];
    [self.class configureWindow:config sourceStyle:_sourceStyle];
    if (self.onSelection) self.onSelection([filter style]);
    if (generation != _generation || selection != _selection || _stopping) return;
    NSObject *capture = [[NSClassFromString(@"SCStream") alloc] initWithFilter:filter configuration:config delegate:self];
    _stream = capture; _pickerSession.stream = capture;
    if (_sourceStyle == 1) [self prepareWindowResizeForStream:capture configuration:config];
    NSError *error;
    if (![capture addStreamOutput:self type:0 sampleHandlerQueue:dispatch_get_main_queue() error:&error]) {
        [self fail:error ?: CaptureError(@"Could not attach screen capture output.")]; return;
    }
    [_lifecycle startStream:capture output:self completion:^(NSError *error) {
        if (generation != self->_generation || selection != self->_selection) return;
        if (error) { [self fail:error]; return; }
        [self releasePicker];
    }];
}

- (void)fail:(NSError *)error {
    NSUInteger attempt = _generation + (_stopping ? 0 : 1);
    [self stopWithCompletionHandler:^(NSError *ignored) {
        if (self->_generation == attempt && self.onEnd) self.onEnd(error);
    }];
}
- (void)selectionCancelled {
    if (!_picking) return;
    [self releasePicker];
    if (self.onSelection) self.onSelection(-1);
    if (!_stream && self.onEnd) self.onEnd(nil);
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
        [self->_lifecycle retireStream:stream output:self completion:^(NSError *ignored) {}];
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
