#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#if PROBE_LIVEKIT
#import <LiveKitWebRTC/LiveKitWebRTC.h>
#else
#import <WebRTC/WebRTC.h>
#endif

@interface ProbeMetalView : MTKView
@property(nonatomic, strong) id<CAMetalDrawable> lastDrawable;
@end

@implementation ProbeMetalView
- (id<CAMetalDrawable>)currentDrawable {
  id<CAMetalDrawable> drawable = [super currentDrawable];
  if (drawable) self.lastDrawable = drawable;
  return drawable;
}
@end

@interface RTC_OBJC_TYPE(RTCMTLVideoView) (ProbeInternals)
+ (MTKView *)createMetalView:(CGRect)frame;
@end

static MTKView *CreateProbeMetalView(id receiver, SEL selector, CGRect frame) {
  ProbeMetalView *view = [[ProbeMetalView alloc] initWithFrame:frame device:MTLCreateSystemDefaultDevice()];
  view.framebufferOnly = NO;
  return view;
}

@interface ProbeDelegate : NSObject <RTC_OBJC_TYPE(RTCVideoViewDelegate)>
@property(nonatomic) NSUInteger callbacks;
@property(nonatomic) CGSize lastSize;
@end

@implementation ProbeDelegate
- (void)videoView:(id<RTC_OBJC_TYPE(RTCVideoRenderer)>)view didChangeVideoSize:(CGSize)size {
  self.callbacks += 1;
  self.lastSize = size;
}
@end

static void Require(BOOL condition, NSString *message) {
  if (!condition) @throw [NSException exceptionWithName:@"ProbeFailure" reason:message userInfo:nil];
}

static void DrainMainQueue(void) {
  [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
}

int main(void) {
  @autoreleasepool {
    @try {
      Require([NSThread isMainThread], @"Probe must run on the main thread");
      Require([RTC_OBJC_TYPE(RTCMTLVideoView) isSubclassOfClass:[NSView class]], @"Unified view is not an NSView");
      Require([RTC_OBJC_TYPE(RTCMTLNSVideoView) isSubclassOfClass:[NSView class]], @"Original Mac view is missing");
      if (![RTC_OBJC_TYPE(RTCMTLVideoView) isMetalAvailable]) {
        fprintf(stderr, "Metal is unavailable on this host\n");
        return 77;
      }
      RTC_OBJC_TYPE(RTCMTLVideoView) *base = [[RTC_OBJC_TYPE(RTCMTLVideoView) alloc] initWithFrame:NSMakeRect(0, 0, 64, 32)];
      RTC_OBJC_TYPE(RTCMTLNSVideoView) *legacy = [[RTC_OBJC_TYPE(RTCMTLNSVideoView) alloc] initWithFrame:NSMakeRect(0, 0, 64, 32)];
      Require(base != nil && legacy != nil, @"Native Mac view construction failed");
      Method factory = class_getClassMethod([RTC_OBJC_TYPE(RTCMTLVideoView) class], @selector(createMetalView:));
      Require(factory != NULL, @"Metal view factory is missing");
      IMP savedFactory = method_setImplementation(factory, (IMP)CreateProbeMetalView);
      RTC_OBJC_TYPE(RTCMTLVideoView) *view = [[RTC_OBJC_TYPE(RTCMTLVideoView) alloc] initWithFrame:NSMakeRect(0, 0, 64, 32)];
      method_setImplementation(factory, savedFactory);
      ProbeDelegate *delegate = [[ProbeDelegate alloc] init];
      view.delegate = delegate;
      ProbeMetalView *metal = [view valueForKey:@"metalView"];
      Require([metal isKindOfClass:[ProbeMetalView class]], @"Metal view factory override was ignored");
      Require(view.enabled, @"Rendering should start enabled");
      view.enabled = NO;
      Require(metal.paused, @"Disabling rendering did not pause Metal");
      view.enabled = YES;

      CVPixelBufferRef pixel = NULL;
      NSDictionary *attributes = @{(__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
                                   (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}};
      CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 32, kCVPixelFormatType_32BGRA,
                                           (__bridge CFDictionaryRef)attributes, &pixel);
      Require(status == kCVReturnSuccess && pixel != NULL, @"Synthetic pixel buffer allocation failed");
      CVPixelBufferLockBaseAddress(pixel, 0);
      uint8_t *bytes = CVPixelBufferGetBaseAddress(pixel);
      size_t stride = CVPixelBufferGetBytesPerRow(pixel);
      for (size_t y = 0; y < 32; ++y) {
        for (size_t x = 0; x < 64; ++x) {
          uint8_t *color = bytes + y * stride + x * 4;
          color[0] = 25; color[1] = 180; color[2] = 45; color[3] = 255;
        }
      }
      CVPixelBufferUnlockBaseAddress(pixel, 0);
      RTC_OBJC_TYPE(RTCCVPixelBuffer) *buffer = [[RTC_OBJC_TYPE(RTCCVPixelBuffer) alloc] initWithPixelBuffer:pixel];
      CVPixelBufferRelease(pixel);
      RTC_OBJC_TYPE(RTCVideoFrame) *frame = [[RTC_OBJC_TYPE(RTCVideoFrame) alloc]
          initWithBuffer:buffer rotation:RTC_OBJC_TYPE(RTCVideoRotation_0) timeStampNs:987654321];
      [view setSize:CGSizeMake(64, 32)];
      [view renderFrame:frame];
      DrainMainQueue();
      Require(delegate.callbacks == 1 && CGSizeEqualToSize(delegate.lastSize, CGSizeMake(64, 32)), @"Size delegate callback failed");
      [view layoutSubtreeIfNeeded];
      [(id<MTKViewDelegate>)view drawInMTKView:metal];
      Require([[view valueForKey:@"lastFrameTimeNs"] longLongValue] == frame.timeStampNs, @"Synthetic frame did not reach draw callback");
      id renderer = [view valueForKey:@"rendererRGB"];
      Require(renderer != nil && metal.device != nil, @"RGB renderer destination failed");
      NSString *rendererClass = NSStringFromClass([renderer class]);
      Require([rendererClass hasSuffix:@"RTCMTLRGBRenderer"], @"Unexpected RGB renderer class");
#if PROBE_LIVEKIT
      Require([rendererClass hasPrefix:@"LK"], @"LiveKit resolved a guest renderer class");
#endif
      id<MTLCommandQueue> queue = [renderer valueForKey:@"commandQueue"];
      Require(queue != nil, @"Renderer did not create a Metal queue");
      id<MTLCommandBuffer> fence = [queue commandBuffer];
      [fence commit];
      [fence waitUntilCompleted];
      Require(fence.status == MTLCommandBufferStatusCompleted, @"Metal draw command queue failed");
      NSMutableDictionary *result = [@{@"passed": @YES,
                                       @"view_class": NSStringFromClass([base class]),
                                       @"legacy_class": NSStringFromClass([legacy class]),
                                       @"renderer_class": rendererClass,
                                       @"metal_device": metal.device.name,
                                       @"synthetic_frame_drawn": @YES,
                                       @"drawable_available": @(metal.lastDrawable != nil),
                                       @"headless": @YES} mutableCopy];
      if (metal.lastDrawable != nil) {
        id<MTLTexture> texture = metal.lastDrawable.texture;
        id<MTLBuffer> sample = [metal.device newBufferWithLength:256 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> copy = [queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [copy blitCommandEncoder];
        [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0
                sourceOrigin:MTLOriginMake(texture.width / 2, texture.height / 2, 0)
                  sourceSize:MTLSizeMake(1, 1, 1) toBuffer:sample destinationOffset:0
             destinationBytesPerRow:256 destinationBytesPerImage:256];
        [blit endEncoding];
        [copy commit];
        [copy waitUntilCompleted];
        Require(copy.status == MTLCommandBufferStatusCompleted, @"Drawable pixel readback failed");
        uint8_t *actual = sample.contents;
        result[@"center_bgra"] = @[@(actual[0]), @(actual[1]), @(actual[2]), @(actual[3])];
        Require(abs(actual[0] - 25) <= 3 && abs(actual[1] - 180) <= 3 &&
                abs(actual[2] - 45) <= 3 && actual[3] == 255, @"Rendered synthetic pixel differs");
        result[@"rendered_pixel_verified"] = @YES;
      } else {
        result[@"rendered_pixel_verified"] = @NO;
      }
      RTC_OBJC_TYPE(RTCVideoRotation) rotation = RTC_OBJC_TYPE(RTCVideoRotation_90);
      view.rotationOverride = [NSValue valueWithBytes:&rotation objCType:@encode(RTC_OBJC_TYPE(RTCVideoRotation))];
      Require(CGSizeEqualToSize(metal.drawableSize, CGSizeMake(32, 64)), @"Rotation override did not swap drawable dimensions");
      view.enabled = NO;
      [view renderFrame:nil];
      Require([[view valueForKey:@"lastFrameTimeNs"] longLongValue] == frame.timeStampNs, @"Disabled renderer changed draw timestamp");
      result[@"rotation_override_verified"] = @YES;
      NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
      fwrite(json.bytes, 1, json.length, stdout);
      fputc('\n', stdout);
      return 0;
    } @catch (NSException *exception) {
      fprintf(stderr, "%s: %s\n", exception.name.UTF8String, exception.reason.UTF8String);
      return 1;
    }
  }
}
