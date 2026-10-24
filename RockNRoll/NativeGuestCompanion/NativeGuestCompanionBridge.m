#import "NativeGuestCompanionBridge.h"
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *const CompanionID = @"dev.vsmirn0v.conferenceguest.nativeguest";
static NSString *const CompanionTeam = @"5V64BP2H3P";

// Signatures from the public macOS AppKit headers; absent from the iOS SDK.
@interface NSObject (NativeGuestAppKitABI)
+ (id)sharedWorkspace;
+ (id)configuration;
- (NSURL *)URLForApplicationWithBundleIdentifier:(NSString *)identifier;
- (NSArray<NSURL *> *)URLsForApplicationsWithBundleIdentifier:(NSString *)identifier;
- (void)setCreatesNewApplicationInstance:(BOOL)enabled;
- (void)setActivates:(BOOL)enabled;
- (void)openApplicationAtURL:(NSURL *)url configuration:(NSObject *)configuration
          completionHandler:(void (^)(NSObject * _Nullable application, NSError * _Nullable error))completion;
- (int32_t)processIdentifier;
- (BOOL)isTerminated;
- (BOOL)activateWithOptions:(NSUInteger)options;
- (BOOL)terminate;
@end

typedef int32_t (*CreateStaticCode)(CFURLRef, uint32_t, CFTypeRef *);
typedef int32_t (*CreateRequirement)(CFStringRef, uint32_t, CFTypeRef *);
typedef int32_t (*CheckStaticCode)(CFTypeRef, uint32_t, CFTypeRef);

static NSError *CompanionError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"NativeGuestCompanion" code:code
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}
static NSError *CompanionStageError(NSInteger code, NSString *message, NSString *stage, int32_t status) {
    return [NSError errorWithDomain:@"NativeGuestCompanion" code:code userInfo:@{
        NSLocalizedDescriptionKey: message, @"NativeGuestStage": stage, @"NativeGuestOSStatus": @(status)
    }];
}

static NSDictionary *NativeBundleInfo(NSURL *url, NSError **error) {
    BOOL scoped = [url startAccessingSecurityScopedResource];
    int fd = -1;
    @try {
        // AppKit supplies native paths. Avoid the iOS Foundation bundle/URL reader.
        NSString *path = [url.path stringByAppendingPathComponent:@"Contents/Info.plist"];
        fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        int32_t status = fd < 0 ? errno : 0;
        struct stat info;
        if (!status && fstat(fd, &info) != 0) status = errno;
        if (!status && (!S_ISREG(info.st_mode) || info.st_size <= 0 || info.st_size > 262144)) status = EINVAL;
        NSMutableData *data = !status ? [NSMutableData dataWithLength:(NSUInteger)info.st_size] : nil;
        size_t offset = 0;
        while (!status && offset < data.length) {
            ssize_t amount = read(fd, (uint8_t *)data.mutableBytes + offset, data.length - offset);
            if (amount < 0) { if (errno == EINTR) continue; status = errno; }
            else if (amount == 0) status = EIO;
            else offset += (size_t)amount;
        }
        if (!status) {
            uint8_t extra;
            ssize_t amount;
            do { amount = read(fd, &extra, 1); } while (amount < 0 && errno == EINTR);
            if (amount != 0) status = amount < 0 ? errno : EFBIG;
        }
        #if DEBUG
        NSString *location = [url.URLByDeletingLastPathComponent.lastPathComponent isEqualToString:@"Applications"] ? @"Applications" : @"other";
        NSLog(@"Native guest metadata: location=%@ posix=%d", location, status);
        #endif
        if (status) {
            if (error) *error = CompanionStageError(2, @"The native meeting app metadata could not be read.",
                                                   @"native-info-read", status);
            return nil;
        }
        NSError *parseError;
        id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:&parseError];
        if (![plist isKindOfClass:NSDictionary.class]) {
            if (error) *error = CompanionStageError(2, @"The native meeting app metadata is invalid.",
                                                   @"native-info-format", (int32_t)parseError.code);
            return nil;
        }
        return plist;
    } @finally {
        if (fd >= 0) close(fd);
        if (scoped) [url stopAccessingSecurityScopedResource];
    }
}

@implementation NativeGuestCompanionBridge {
    NSObject *_application;
    BOOL _launching;
}
+ (BOOL)isSupported {
    if (!NSProcessInfo.processInfo.isiOSAppOnMac) return NO;
    static BOOL available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *appKit = dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_NOW | RTLD_LOCAL);
        available = appKit && NSClassFromString(@"NSWorkspace") && NSClassFromString(@"NSWorkspaceOpenConfiguration");
    });
    return available;
}
+ (NSURL *)validatedApplicationURLWithError:(NSError **)error {
    if (![self isSupported]) {
        if (error) *error = CompanionError(1, @"Native meetings require the Mac app.");
        return nil;
    }
    NSObject *workspace = [NSClassFromString(@"NSWorkspace") sharedWorkspace];
    NSMutableOrderedSet<NSURL *> *registered = [NSMutableOrderedSet orderedSetWithArray:
        [workspace URLsForApplicationsWithBundleIdentifier:CompanionID] ?: @[]];
    NSURL *preferred = [workspace URLForApplicationWithBundleIdentifier:CompanionID];
    if (preferred) [registered addObject:preferred];
    // A development build can displace an installed copy in Launch Services.
    // Prefer Applications directories, then validate every candidate identically.
    NSArray<NSURL *> *candidates = [registered.array sortedArrayUsingComparator:^NSComparisonResult(NSURL *left, NSURL *right) {
        BOOL leftInstalled = [left.URLByDeletingLastPathComponent.lastPathComponent isEqualToString:@"Applications"];
        BOOL rightInstalled = [right.URLByDeletingLastPathComponent.lastPathComponent isEqualToString:@"Applications"];
        if (leftInstalled == rightInstalled) return NSOrderedSame;
        return leftInstalled ? NSOrderedAscending : NSOrderedDescending;
    }];
    if (candidates.count == 0) {
        if (error) *error = CompanionStageError(2, @"Install the compatible native meeting app first.", @"bundle-resolution", 0);
        return nil;
    }
    static CreateStaticCode createCode;
    static CreateRequirement createRequirement;
    static CheckStaticCode checkCode;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW | RTLD_LOCAL);
        if (security) {
            createCode = (CreateStaticCode)dlsym(security, "SecStaticCodeCreateWithPath");
            createRequirement = (CreateRequirement)dlsym(security, "SecRequirementCreateWithString");
            checkCode = (CheckStaticCode)dlsym(security, "SecStaticCodeCheckValidity");
        }
    });
    NSString *rule = [NSString stringWithFormat:
        @"anchor apple generic and identifier \"%@\" and certificate leaf[subject.OU] = \"%@\"",
        CompanionID, CompanionTeam];
    if (!createCode || !createRequirement || !checkCode) {
        if (error) *error = CompanionStageError(3, @"Native signature validation is unavailable.", @"security-symbols", -1);
        return nil;
    }
    NSError *lastError;
    for (NSURL *url in candidates) {
        if (!url.isFileURL) continue;
        NSDictionary *info = NativeBundleInfo(url, &lastError);
        if (!info) continue;
        NSNumber *version = info[@"NativeGuestProtocolVersion"];
        if (![info[@"CFBundleIdentifier"] isEqualToString:CompanionID] ||
            ![version isKindOfClass:NSNumber.class] || version.integerValue != 1) {
            lastError = CompanionStageError(2, @"Install the compatible native meeting app first.", @"bundle-protocol", 0);
            continue;
        }
        CFTypeRef code = NULL, requirement = NULL;
        NSString *stage;
        int32_t status;
        stage = @"static-code-create";
        status = createCode((__bridge CFURLRef)url, 0, &code);
        if (status == 0) {
            stage = @"requirement-create";
            status = createRequirement((__bridge CFStringRef)rule, 0, &requirement);
            if (status == 0) {
                stage = @"static-code-validate";
                // Public kSecCSCheckAllArchitectures | kSecCSStrictValidate, from SecStaticCode.h.
                status = checkCode(code, (1u << 0) | (1u << 4), requirement);
            }
        }
        if (code) CFRelease(code);
        if (requirement) CFRelease(requirement);
        if (status == 0) return url;
        lastError = CompanionStageError(3, @"The native meeting app signature could not be verified.", stage, status);
    }
    if (error) *error = lastError ?: CompanionStageError(2, @"Install the compatible native meeting app first.", @"bundle-resolution", 0);
    return nil;
}
- (void)launchSession:(NSUUID *)sessionID completion:(void (^)(int32_t, NSError *))completion {
    NSAssert(NSThread.isMainThread, @"Native launch belongs to the main thread");
    if (_launching || (_application && ![_application isTerminated])) {
        completion(0, CompanionError(4, @"A native meeting is already running."));
        return;
    }
    _launching = YES;
    __block BOOL completed = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (completed) return;
        completed = YES; self->_launching = NO;
        completion(0, CompanionError(6, @"The native meeting app did not start in time."));
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error;
        NSURL *url = [NativeGuestCompanionBridge validatedApplicationURLWithError:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completed) return;
            if (!url) { completed = YES; self->_launching = NO; completion(0, error); return; }
            NSObject *configuration = [NSClassFromString(@"NSWorkspaceOpenConfiguration") configuration];
            [configuration setCreatesNewApplicationInstance:YES];
            [configuration setActivates:YES];
            NSObject *workspace = [NSClassFromString(@"NSWorkspace") sharedWorkspace];
            // The helper admits exactly one fresh unclaimed ticket from the protected app group.
            // No launch argument or URL carries session data.
            [workspace openApplicationAtURL:url configuration:configuration completionHandler:^(NSObject *application, NSError *launchError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completed) {
                        if (application) { self->_application = application; [application terminate]; }
                        return;
                    }
                    completed = YES;
                    self->_launching = NO;
                    if (application) self->_application = application;
                    completion(application ? [application processIdentifier] : 0,
                               launchError ?: (application ? nil : CompanionError(5, @"The native meeting app did not start.")));
                });
            }];
        });
    });
}
- (int32_t)processIdentifier { return _application ? [_application processIdentifier] : 0; }
- (BOOL)launchedApplicationTerminated { return !_application || [_application isTerminated]; }
- (void)show {
    if (_application && ![_application isTerminated]) [_application activateWithOptions:0];
}
- (BOOL)terminateLaunchedApplication {
    return !_application || [_application isTerminated] || [_application terminate];
}
@end
