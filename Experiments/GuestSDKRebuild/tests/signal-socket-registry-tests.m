#import "../../../RockNRoll/VendorIntegration/GuestSignalCodecBridge.m"

// No network is opened. The registry owns weak object handles, and the send
// boundary is exercised with a minimal task double implementing public state.
@interface RegistryTaskDouble : NSObject
@property(nonatomic, readonly) NSURLSessionTaskState state;
@end
@implementation RegistryTaskDouble
- (NSURLSessionTaskState)state { return NSURLSessionTaskStateRunning; }
@end

static NSUUID *cleanupSocket;
static NSUInteger forwarded;
static void CaptureSend(id task, SEL selector, NSURLSessionWebSocketMessage *message, void (^completion)(NSError *)) {
    NSCAssert([GuestSignalTasks() taskForSocket:cleanupSocket] == task, @"Cleanup must keep its exact binding until forwarded");
    forwarded++;
    completion(nil);
}

int main(void) {
    @autoreleasepool {
        GuestSignalSocketRegistry *registry = [[GuestSignalSocketRegistry alloc] initWithCapacity:16];
        NSMutableArray *live = [NSMutableArray array], *identities = [NSMutableArray array];
        NSObject *first = [NSObject new]; NSUUID *firstID = NSUUID.UUID;
        [live addObject:first]; [identities addObject:firstID];
        NSCAssert([registry bindTask:first socket:firstID], @"First qualified socket must bind");
        for (NSUInteger i = 0; i < 512; i++) {
            NSCAssert([registry taskForSocket:NSUUID.UUID] == nil, @"Unrelated lookup must not register or evict");
        }
        NSCAssert(registry.count == 1 && [registry taskForSocket:firstID] == first, @"Unrelated traffic cannot evict the active binding");
        for (NSUInteger i = 1; i < 16; i++) {
            NSObject *task = [NSObject new]; NSUUID *identity = NSUUID.UUID;
            [live addObject:task]; [identities addObject:identity];
            NSCAssert([registry bindTask:task socket:identity], @"Capacity must be usable");
        }
        for (NSUInteger i = 0; i < 512; i++) {
            NSCAssert(![registry bindTask:[NSObject new] socket:NSUUID.UUID], @"Capacity exhaustion must reject rather than evict");
        }
        NSCAssert(registry.count == 16 && [registry taskForSocket:firstID] == first, @"The exact cleanup socket must survive capacity pressure");
        NSCAssert(![registry bindTask:[NSObject new] socket:firstID], @"A socket identity cannot be rebound to another task");
        [registry unbind:identities[1]];
        NSObject *replacement = [NSObject new];
        NSCAssert([registry bindTask:replacement socket:NSUUID.UUID], @"Explicit retirement must recover capacity");

        GuestSignalSocketRegistry *weakRegistry = [[GuestSignalSocketRegistry alloc] initWithCapacity:1];
        __weak NSObject *weakTask;
        @autoreleasepool {
            NSObject *temporary = [NSObject new]; weakTask = temporary;
            NSCAssert([weakRegistry bindTask:temporary socket:NSUUID.UUID], @"Weak fixture binds");
        }
        NSCAssert(weakTask == nil, @"Registry must not prolong task lifetime");
        NSCAssert([weakRegistry bindTask:replacement socket:NSUUID.UUID], @"Expired weak binding must not exhaust capacity");

        NSCAssert(![GuestSignalCodecBridge bindObservedSocket:NSUUID.UUID], @"Unrelated callers cannot pin an unobserved socket");
        RegistryTaskDouble *owned = [RegistryTaskDouble new];
        GuestSignalSync(^{
            GuestObservedSendingTask = (NSURLSessionWebSocketTask *)owned;
            cleanupSocket = [GuestSignalCodecBridge identity:(NSURLSessionWebSocketTask *)owned];
            NSCAssert([GuestSignalCodecBridge bindObservedSocket:cleanupSocket], @"Qualified observed socket must bind");
            GuestObservedSendingTask = nil;
            GuestOriginalSend = CaptureSend;
        });
        [GuestSignalCodecBridge sendData:[@"{}" dataUsingEncoding:NSUTF8StringEncoding] socket:cleanupSocket when:^BOOL { return YES; }];
        [GuestSignalCodecBridge unbindSocketAfterPendingSends:cleanupSocket];
        GuestSignalSync(^{
            NSCAssert(forwarded == 1, @"Queued cleanup must run before unbinding");
            NSCAssert([GuestSignalTasks() taskForSocket:cleanupSocket] == nil, @"Retired socket must be removed after cleanup");
        });
        puts("PASS: qualified-only weak registry, 16-socket bound, 1024 capacity/traffic checks, identity fencing, and cleanup-before-unbind ordering");
    }
    return 0;
}
