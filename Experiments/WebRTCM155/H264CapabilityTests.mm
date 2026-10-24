// Exercise the real private parser/query wrapper and rebuilt public factory ABI.
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <atomic>
#include <dlfcn.h>
#include <cstdio>
#include <cstring>
#include "sdk/objc/components/video_codec/RTCH264ProfileLevelId+Private.h"

@interface NSObject (H264CapabilityTestFactory)
+ (NSArray *)supportedCodecs;
@end

namespace {
int assertions = 0;
void Check(bool condition, const char *label) {
  ++assertions;
  if (!condition) {
    fprintf(stderr, "FAIL: %s\n", label);
    exit(1);
  }
}
NSDictionary *Properties(NSArray *values) {
  return @{(__bridge NSString *)kVTCompressionPropertyKey_ProfileLevel :
               @{(__bridge NSString *)kVTPropertySupportedValueListKey : values}};
}
bool Empty(const VideoToolboxH264ProfileLevels &levels) {
  return !levels.constrainedBaseline && !levels.main && !levels.constrainedHigh;
}
using Level = webrtc::H264Level;
using Profile = webrtc::H264Profile;
CFDictionaryRef retainedQueryResult;
OSStatus TestQuery(int32_t width, int32_t height, CMVideoCodecType codec,
                   CFDictionaryRef specification, CFStringRef *identifier,
                   CFDictionaryRef *properties) {
  Check(width == 1600 && height == 1000 && codec == kCMVideoCodecType_H264,
        "query forwards dimensions and H264 codec");
  Check(specification != nullptr && identifier == nullptr,
        "query forwards hardware selector without requesting encoder identity");
  *properties = retainedQueryResult ? (CFDictionaryRef)CFRetain(retainedQueryResult) : nullptr;
  return height == 1000 && width == 1600 ? noErr : -1;
}
OSStatus FailedQuery(int32_t, int32_t, CMVideoCodecType, CFDictionaryRef,
                     CFStringRef *, CFDictionaryRef *properties) {
  *properties = retainedQueryResult ? (CFDictionaryRef)CFRetain(retainedQueryResult) : nullptr;
  return -1;
}
void ParserAndQueryTests() {
  Check(Empty(ParseSupportedH264ProfileLevels(nil)), "nil query is unknown");
  Check(Empty(ParseSupportedH264ProfileLevels((NSDictionary *)@[])), "wrong root type is unknown");
  Check(Empty(ParseSupportedH264ProfileLevels(@{})), "missing property is unknown");
  NSString *key = (__bridge NSString *)kVTCompressionPropertyKey_ProfileLevel;
  Check(Empty(ParseSupportedH264ProfileLevels(@{key : @[]})), "wrong property type is unknown");
  Check(Empty(ParseSupportedH264ProfileLevels(@{key : @{(__bridge NSString *)kVTPropertySupportedValueListKey : @1}})),
        "wrong value-list type is unknown");
  Check(Empty(ParseSupportedH264ProfileLevels(Properties(@[@1, @"unrecognized", (__bridge id)kVTProfileLevel_H264_Baseline_AutoLevel]))),
        "non-numeric and unknown levels cannot advertise a level");
  const auto mixed = ParseSupportedH264ProfileLevels(Properties(@[
      (__bridge id)kVTProfileLevel_H264_Baseline_4_0, (__bridge id)kVTProfileLevel_H264_Baseline_3_1,
      (__bridge id)kVTProfileLevel_H264_High_5_2, (__bridge id)kVTProfileLevel_H264_Main_4_2,
      (__bridge id)kVTProfileLevel_H264_Baseline_4_0]));
  Check(mixed.constrainedBaseline == Level::kLevel4, "baseline retains its maximum, not high-family maximum");
  Check(mixed.main == Level::kLevel4_2 && mixed.constrainedHigh == Level::kLevel5_2,
        "main and high are independently selected");
  const auto baselineOnly = ParseSupportedH264ProfileLevels(Properties(@[(__bridge id)kVTProfileLevel_H264_Baseline_4_1]));
  Check(!SupportedVideoToolboxLevelForProfile(Profile::kProfileConstrainedHigh, baselineOnly),
        "missing high family remains unknown for caller's Level 3.1 fallback");
  Check(SupportedVideoToolboxLevelForProfile(Profile::kProfileConstrainedBaseline, baselineOnly) == Level::kLevel4_1,
        "baseline capability remains usable in a partial dictionary");
  Check(!SupportedVideoToolboxLevelForProfile(Profile::kProfileConstrainedBaseline, {}),
        "failed/no query cannot invent Level 5");
  NSDictionary *specification = @{(__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder : @YES};
  retainedQueryResult = (__bridge_retained CFDictionaryRef)Properties(@[(__bridge id)kVTProfileLevel_H264_Baseline_4_2]);
  Check(CopySupportedH264ProfileLevels(1600, 1000, specification, &TestQuery).constrainedBaseline == Level::kLevel4_2,
        "successful query uses actual returned properties");
  Check(Empty(CopySupportedH264ProfileLevels(1600, 1000, specification, &FailedQuery)),
        "failed query ignores a non-null result");
  CFRelease(retainedQueryResult);
  retainedQueryResult = nullptr;
  Check(Empty(CopySupportedH264ProfileLevels(1600, 1000, specification, &TestQuery)),
        "successful query with null properties is unknown");
  Check(Empty(CopySupportedH264ProfileLevels(1600, 1000, specification, &FailedQuery)),
        "failed query with null properties is unknown");
}
void RuntimeTests(const char *binary, bool prefixed) {
  void *library = dlopen(binary, RTLD_NOW | RTLD_LOCAL);
  Check(library != nullptr, "candidate framework loads");
  using Accessor = NSString *(*)(void);
  const auto baseline = (Accessor)dlsym(library, prefixed ? "LKRTCMaxSupportedH264ProfileLevelConstrainedBaseline" : "RTCMaxSupportedH264ProfileLevelConstrainedBaseline");
  const auto high = (Accessor)dlsym(library, prefixed ? "LKRTCMaxSupportedH264ProfileLevelConstrainedHigh" : "RTCMaxSupportedH264ProfileLevelConstrainedHigh");
  Check(baseline && high, "both actual M150-compatible function exports exist");
  // Race the first call to both accessors; this must precede factory creation.
  std::atomic<int> failures{0};
  auto *failuresPointer = &failures;
  dispatch_apply(32, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
    @autoreleasepool {
      NSString *first = index % 2 == 0 ? baseline() : high();
      NSString *second = index % 2 == 0 ? high() : baseline();
      if (first.length != 6 || second.length != 6) {
        failuresPointer->fetch_add(1);
      }
    }
  });
  Check(failures == 0, "concurrent first access always returns complete profile-level strings");
  NSString *baselineValue = baseline(), *highValue = high();
  Check(baseline() == baselineValue && high() == highValue, "subsequent calls retain cached identity");
  Class encoder = NSClassFromString(prefixed ? @"LKRTCVideoEncoderH264" : @"RTCVideoEncoderH264");
  Class decoder = NSClassFromString(prefixed ? @"LKRTCVideoDecoderH264" : @"RTCVideoDecoderH264");
  Check(encoder != Nil && decoder != Nil, "both H264 factory classes exist");
  for (Class factory in @[encoder, decoder]) {
    NSArray *codecs = [factory supportedCodecs];
    Check(codecs.count == 2, "H264 factory returns both supported profile families");
    NSMutableSet *profiles = [NSMutableSet set];
    for (id codec in codecs) {
      [profiles addObject:[codec valueForKey:@"parameters"][@"profile-level-id"]];
    }
    Check([profiles isEqualToSet:[NSSet setWithArray:@[baselineValue, highValue]]],
          "encoder and decoder advertise the queried lazy capabilities");
  }
  // This host acceptance is deliberately explicit: the native Mac repair must
  // support the observed 1600x1000 fixture (6300 macroblocks requires level >= 4).
  unsigned baselineLevel = 0;
  NSScanner *scanner = [NSScanner scannerWithString:[baselineValue substringFromIndex:4]];
  Check([scanner scanHexInt:&baselineLevel] && baselineLevel >= 40,
        "current native hardware advertises a level sufficient for 1600x1000");
  printf("runtime baseline=%s high=%s\n", baselineValue.UTF8String, highValue.UTF8String);
  // Keep the ObjC framework loaded until process exit.
}
}  // namespace

int main(int argc, char **argv) {
  @autoreleasepool {
    ParserAndQueryTests();
    if (argc == 3) {
      RuntimeTests(argv[1], strcmp(argv[2], "prefixed") == 0);
    } else if (argc != 1) {
      fprintf(stderr, "usage: H264CapabilityTests [FRAMEWORK_BINARY guest|prefixed]\n");
      return 2;
    }
    printf("PASS: %d H264 capability assertions%s\n", assertions, argc == 3 ? " including rebuilt runtime" : " (deterministic helpers only)");
  }
}
