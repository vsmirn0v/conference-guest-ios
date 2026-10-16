#if DEBUG
#import "OwnedWindowCaptureFixture.h"
#import "../RockNRoll/MacScreenCaptureBridge.h"
#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>

// Exact public macOS selectors; none of this file belongs to the app target.
@interface NSObject (OwnedCapturePublicAPI)
- (id)initWithContentRect:(CGRect)rect styleMask:(NSUInteger)style backing:(NSUInteger)backing defer:(BOOL)defer;
- (void)setTitle:(NSString *)title;
- (void)setReleasedWhenClosed:(BOOL)value;
- (id)contentView;
- (void)setWantsLayer:(BOOL)value;
- (CALayer *)layer;
- (void)makeKeyAndOrderFront:(id)sender;
- (NSInteger)windowNumber;
- (void)orderOut:(id)sender;
- (void)close;
+ (void)getCurrentProcessShareableContentWithCompletionHandler:(void (^)(NSObject *, NSError *))completion;
- (NSArray *)windows;
- (uint32_t)windowID;
- (id)owningApplication;
- (pid_t)processID;
- (id)initWithDesktopIndependentWindow:(id)window;
- (void)setWidth:(NSUInteger)value;
- (void)setHeight:(NSUInteger)value;
- (void)setCapturesAudio:(BOOL)value;
- (void)setPixelFormat:(OSType)value;
- (id)initWithFilter:(id)filter configuration:(id)configuration delegate:(id)delegate;
- (BOOL)addStreamOutput:(id)output type:(NSInteger)type sampleHandlerQueue:(dispatch_queue_t)queue error:(NSError **)error;
@end

@implementation OwnedWindowCaptureFixture {
    NSObject *_window, *_stream;
    ScreenCaptureLifecycle *_lifecycle;
    NSTimer *_timer;
    NSUInteger _generation, _ticks, _frames, _changes;
    uint32_t _lastPixel;
    BOOL _starting, _closed;
}
- (instancetype)init {
    if ((self = [super init])) {
        _lifecycle = [ScreenCaptureLifecycle new];
        for (NSString *name in @[@"SCStreamOutput", @"SCStreamDelegate"]) {
            Protocol *protocol = NSProtocolFromString(name);
            if (protocol) class_addProtocol(self.class, protocol);
        }
    }
    return self;
}
- (NSUInteger)frames { return _frames; }
- (NSUInteger)changes { return _changes; }
- (BOOL)starting { return _starting; }
- (void)fail:(NSString *)message {
    _starting = NO;
    if (self.onEnd) self.onEnd([NSError errorWithDomain:@"OwnedWindowCapture" code:1
        userInfo:@{NSLocalizedDescriptionKey:message}]);
}
- (void)start {
    NSAssert(NSThread.isMainThread, @"Capture fixture is main-thread owned");
    if (_closed || _stream || _window) return;
    Class windowClass = NSClassFromString(@"NSWindow");
    Class contentClass = NSClassFromString(@"SCShareableContent");
    if (!NSProcessInfo.processInfo.isiOSAppOnMac || !windowClass ||
        ![contentClass respondsToSelector:@selector(getCurrentProcessShareableContentWithCompletionHandler:)]) {
        [self fail:@"Current-process screen capture is unavailable"]; return;
    }
    _generation += 1;
    _window = [[windowClass alloc] initWithContentRect:CGRectMake(100, 150, 640, 360)
        styleMask:1 backing:2 defer:NO];
    [_window setTitle:[@"Rock owned capture QA " stringByAppendingString:NSUUID.UUID.UUIDString]];
    [_window setReleasedWhenClosed:NO];
    [[_window contentView] setWantsLayer:YES];
    [[[_window contentView] layer] setBackgroundColor:UIColor.systemBlueColor.CGColor];
    [_window makeKeyAndOrderFront:nil];
    __weak typeof(self) weak = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
        typeof(self) self = weak;
        if (!self || self->_closed) { [timer invalidate]; return; }
        self->_ticks += 1;
        UIColor *color = self->_ticks % 2 ? UIColor.systemOrangeColor : UIColor.systemBlueColor;
        [[[self->_window contentView] layer] setBackgroundColor:color.CGColor];
    }];
    [self discover:_generation attempts:10];
}
- (void)discover:(NSUInteger)generation attempts:(NSUInteger)attempts {
    __weak typeof(self) weak = self;
    [NSClassFromString(@"SCShareableContent") getCurrentProcessShareableContentWithCompletionHandler:^(NSObject *content, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weak;
            if (!self || self->_closed || self->_generation != generation) return;
            NSObject *own = nil;
            NSInteger windowID = [self->_window windowNumber];
            for (NSObject *candidate in [content windows]) {
                if ([candidate windowID] == windowID &&
                    [[candidate owningApplication] processID] == NSProcessInfo.processInfo.processIdentifier) {
                    own = candidate; break;
                }
            }
            if (own) { [self capture:own generation:generation]; return; }
            if (attempts <= 1) { [self fail:error.localizedDescription ?: @"Owned test window unavailable"]; return; }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                if (!self->_closed && self->_generation == generation) [self discover:generation attempts:attempts - 1];
            });
        });
    }];
}
- (void)capture:(NSObject *)window generation:(NSUInteger)generation {
    NSObject *filter = [[NSClassFromString(@"SCContentFilter") alloc] initWithDesktopIndependentWindow:window];
    NSObject *config = [NSClassFromString(@"SCStreamConfiguration") new];
    [config setWidth:640]; [config setHeight:360]; [config setCapturesAudio:NO];
    [config setPixelFormat:kCVPixelFormatType_32BGRA];
    [MacScreenCaptureBridge configureTiming:config fps:30 queueDepth:3];
    [MacScreenCaptureBridge configureWindow:config sourceStyle:1];
    _stream = [[NSClassFromString(@"SCStream") alloc] initWithFilter:filter configuration:config delegate:self];
    NSError *error = nil;
    if (![_stream addStreamOutput:self type:0 sampleHandlerQueue:dispatch_get_main_queue() error:&error]) {
        [self fail:error.localizedDescription ?: @"Could not register owned capture output"]; return;
    }
    if (self.onSelected) self.onSelected();
    if (_closed || _generation != generation) return;
    _starting = YES;
    [_lifecycle startStream:_stream output:self completion:^(NSError *error) {
        if (self->_closed || self->_generation != generation) return;
        self->_starting = NO;
        if (error) [self fail:error.localizedDescription];
    }];
    if (self.onStarting) self.onStarting();
}
- (void)stream:(NSObject *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(NSInteger)type {
    if (_closed || stream != _stream || type != 0 || !CMSampleBufferIsValid(sample)) return;
    CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sample);
    if (!pixels || CVPixelBufferGetPixelFormatType(pixels) != kCVPixelFormatType_32BGRA ||
        CVPixelBufferGetWidth(pixels) == 0 || CVPixelBufferGetHeight(pixels) == 0) return;
    if (CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return;
    const uint8_t *base = CVPixelBufferGetBaseAddress(pixels);
    uint32_t pixel = 0;
    if (base) memcpy(&pixel, base + (CVPixelBufferGetHeight(pixels) / 2) * CVPixelBufferGetBytesPerRow(pixels)
        + (CVPixelBufferGetWidth(pixels) / 2) * 4, sizeof(pixel));
    CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
    if (_frames && pixel != _lastPixel) _changes += 1;
    _lastPixel = pixel; _frames += 1;
    if (self.onFrame) self.onFrame(sample);
}
- (void)stream:(NSObject *)stream didStopWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_closed && stream == self->_stream) [self fail:error.localizedDescription];
    });
}
- (void)stopWithCompletion:(void (^)(void))completion {
    NSAssert(NSThread.isMainThread, @"Capture fixture is main-thread owned");
    _closed = YES; _starting = NO; _generation += 1;
    [_timer invalidate]; _timer = nil;
    NSObject *stream = _stream; _stream = nil;
    [_window orderOut:nil]; [_window close]; _window = nil;
    if (stream) [_lifecycle retireStream:stream output:self completion:^(NSError *error) { completion(); }];
    else [_lifecycle drain:completion];
}
@end
#endif
