#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import "MacScreenCaptureBridge.h"

static void Emit(NSDictionary *record) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
    if (data) { fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout); }
}
static id Number(double value) { return isfinite(value) ? @(value) : NSNull.null; }
static NSArray *RectMetrics(CGRect rect) {
    return @[Number(rect.origin.x), Number(rect.origin.y), Number(rect.size.width), Number(rect.size.height)];
}

@interface WindowGeometryProbe : NSObject <NSApplicationDelegate, SCStreamOutput, SCStreamDelegate>
@property NSWindow *window;
@property NSTextField *label;
@property SCStream *stream;
@property MacScreenCaptureBridge *geometry;
@property ScreenCaptureLifecycle *lifecycle;
@property NSTimer *timer;
@property NSTimeInterval started, lastLog;
@property NSInteger phase;
@property NSUInteger frames;
@property NSUInteger discoveryAttempts;
@property BOOL baseline, stopping;
@property NSMutableDictionary *counts;
@end

@implementation WindowGeometryProbe
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    self.baseline = [NSProcessInfo.processInfo.arguments containsObject:@"--baseline"];
    self.phase = -1; self.counts = NSMutableDictionary.dictionary;
    self.geometry = [MacScreenCaptureBridge new]; self.geometry.preserveDetail = YES;
    self.lifecycle = [ScreenCaptureLifecycle new];
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 180, 900, 600)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Rock window geometry probe — synthetic content only";
    self.window.releasedWhenClosed = NO;
    self.window.contentView.wantsLayer = YES;
    self.window.contentView.layer.backgroundColor = NSColor.systemBlueColor.CGColor;
    self.window.contentView.layer.borderColor = NSColor.systemYellowColor.CGColor;
    self.window.contentView.layer.borderWidth = 12;
    self.label = [NSTextField labelWithString:@"Synthetic window capture — preparing"];
    self.label.font = [NSFont monospacedSystemFontOfSize:24 weight:NSFontWeightBold];
    self.label.textColor = NSColor.whiteColor;
    [self.window.contentView addSubview:self.label]; [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    Emit(@{@"event":@"begin", @"baseline":@(self.baseline), @"os":NSProcessInfo.processInfo.operatingSystemVersionString,
           @"privacy":@"Own generated window only; no microphone, meeting, or pixel files"});
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 55 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self finish:@"timeout" code:2];
    });
    [self discoverWindow];
}
- (void)retryDiscovery:(NSString *)reason {
    if (self.discoveryAttempts >= 12) { [self finish:reason code:2]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (!self.stopping) [self discoverWindow];
    });
}
- (void)discoverWindow {
    self.discoveryAttempts += 1;
    // This API exposes only capture already allowed for this process. Never
    // substitute broad getShareableContent or a display/application filter.
    [SCShareableContent getCurrentProcessShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.stopping) return;
            SCWindow *own = nil;
            for (SCWindow *candidate in content.windows)
                if (candidate.windowID == self.window.windowNumber &&
                    candidate.owningApplication.processID == NSProcessInfo.processInfo.processIdentifier) { own = candidate; break; }
            if (!own) {
                NSString *reason = error.localizedDescription ?: @"Own window unavailable";
                Emit(@{@"event":@"discovery-retry", @"attempt":@(self.discoveryAttempts), @"reason":reason});
                [self retryDiscovery:reason]; return;
            }
            [self beginCapture:own];
        });
    }];
}
- (void)beginCapture:(SCWindow *)window {
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
    SCStreamConfiguration *config = [SCStreamConfiguration new];
    CGSize source = filter.contentRect.size;
    double scale = filter.pointPixelScale;
    CGSize size = [self.geometry captureSizeForContent:CGSizeMake(source.width * scale, source.height * scale)];
    Emit(@{@"event":@"initial-geometry", @"attempt":@(self.discoveryAttempts), @"style":@(filter.style),
           @"filterRect":RectMetrics(filter.contentRect), @"windowRect":RectMetrics(window.frame), @"scale":Number(scale),
           @"width":Number(size.width), @"height":Number(size.height)});
    if (!isfinite(scale) || scale <= 0 || !isfinite(source.width) || !isfinite(source.height) ||
        source.width <= 0 || source.height <= 0 || size.width < 2 || size.height < 2) {
        [self retryDiscovery:@"Own-window initial geometry remained invalid"]; return;
    }
    config.width = size.width; config.height = size.height;
    config.capturesAudio = NO; config.pixelFormat = kCVPixelFormatType_32BGRA;
    [MacScreenCaptureBridge configureTiming:config fps:30 queueDepth:3];
    if (!self.baseline) [MacScreenCaptureBridge configureWindow:config sourceStyle:filter.style];
    Emit(@{@"event":@"initial-configuration", @"width":@(config.width), @"height":@(config.height),
           @"scalesToFit":@(config.scalesToFit), @"preservesAspectRatio":@(config.preservesAspectRatio),
           @"ignoreShadowsSingleWindow":@(config.ignoreShadowsSingleWindow),
           @"ignoreGlobalClipSingleWindow":@(config.ignoreGlobalClipSingleWindow)});
    self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
    [self.geometry prepareWindowResizeForStream:self.stream configuration:config];
    NSError *error = nil;
    if (![self.stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_get_main_queue() error:&error]) {
        [self finish:error.localizedDescription ?: @"Output registration failed" code:2]; return;
    }
    [self.lifecycle startStream:self.stream output:self completion:^(NSError *failure) {
        if (self.stopping) return;
        if (failure) { [self finish:failure.localizedDescription code:2]; return; }
        self.started = NSProcessInfo.processInfo.systemUptime;
        self.timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) { [self tick]; }];
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
        [self tick];
    }];
}
- (NSString *)phaseName {
    NSArray *names = @[@"landscape", @"portrait", @"wide", @"off-display", @"manual-mission-control", @"restored"];
    return self.phase >= 0 && self.phase < names.count ? names[self.phase] : @"starting";
}
- (void)tick {
    NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - self.started;
    if (elapsed >= 45) { [self finish:@"completed" code:self.frames ? 0 : 2]; return; }
    NSInteger phase = elapsed < 20 ? (NSInteger)(elapsed / 5) : elapsed < 40 ? 4 : 5;
    if (phase != self.phase) {
        self.phase = phase;
        NSRect screen = self.window.screen.frame;
        NSSize sizes[] = {{900,600},{600,850},{1200,450},{900,600},{900,600},{700,500}};
        [self.window setContentSize:sizes[phase]];
        [self.window setFrameOrigin:NSMakePoint(NSMinX(screen) + (phase == 3 ? -300 : 100), NSMinY(screen) + 160)];
        Emit(@{@"event":@"phase", @"phase":self.phaseName, @"seconds":@(elapsed),
               @"instruction":phase == 4 ? @"Open Mission Control now, then leave it before 40 seconds" : @"Automatic synthetic-window geometry change"});
    }
    NSSize size = self.window.contentView.bounds.size;
    self.label.frame = NSMakeRect(24, MAX(0, size.height - 160), MAX(1, size.width - 48), 140);
    self.label.stringValue = [NSString stringWithFormat:@"SYNTHETIC WINDOW ONLY\n%@ · %.1f s\n%.0f × %.0f points", self.phaseName, elapsed, size.width, size.height];
}
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    if (self.stopping || stream != self.stream || type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sample)) return;
    CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sample); if (!pixels) return;
    [self.geometry observeWindowSample:sample];
    NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sample, NO);
    NSDictionary *info = attachments.firstObject;
    NSNumber *status = info[SCStreamFrameInfoStatus];
    if (!status || status.integerValue != SCFrameStatusComplete) return;
    self.frames += 1;
    NSString *phase = self.phaseName;
    self.counts[phase] = @([self.counts[phase] unsignedIntegerValue] + 1);
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now - self.lastLog < 1) return; self.lastLog = now;
    CGRect rect = CGRectZero;
    NSDictionary *rectInfo = info[SCStreamFrameInfoContentRect];
    if ([rectInfo isKindOfClass:NSDictionary.class]) CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)rectInfo, &rect);
    Emit(@{@"event":@"frame", @"phase":phase, @"seconds":@(self.started ? now - self.started : 0),
           @"width":@(CVPixelBufferGetWidth(pixels)), @"height":@(CVPixelBufferGetHeight(pixels)),
           @"contentRect":@[@(rect.origin.x),@(rect.origin.y),@(rect.size.width),@(rect.size.height)],
           @"contentScale":info[SCStreamFrameInfoContentScale] ?: NSNull.null,
           @"backingScale":info[SCStreamFrameInfoScaleFactor] ?: NSNull.null});
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{ [self finish:error.localizedDescription code:2]; });
}
- (void)finish:(NSString *)reason code:(int)code {
    if (self.stopping) return; self.stopping = YES;
    [self.timer invalidate]; [self.geometry invalidateWindowResize];
    void (^done)(NSError *) = ^(NSError *error) {
        Emit(@{@"event":@"summary", @"reason":reason, @"frames":@(self.frames), @"phaseFrameCounts":self.counts,
               @"baseline":@(self.baseline), @"stopError":error.localizedDescription ?: NSNull.null});
        exit(code ?: (error ? 2 : 0));
    };
    if (self.stream) [self.lifecycle retireStream:self.stream output:self completion:done]; else done(nil);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        Emit(@{@"event":@"summary", @"reason":@"stop-timeout", @"frames":@(self.frames)}); exit(2);
    });
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        WindowGeometryProbe *probe = [WindowGeometryProbe new]; app.delegate = probe;
        [app run];
    }
    return 0;
}
