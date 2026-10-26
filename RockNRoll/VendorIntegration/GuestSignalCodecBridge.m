#import "GuestSignalCodecBridge.h"
#import <objc/runtime.h>

static void (*GuestOriginalSend)(id, SEL, NSURLSessionWebSocketMessage *, void (^)(NSError *));
static char GuestSignalQueueKey;
static dispatch_queue_t GuestSignalQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("dev.vsmirn0v.guest-signaling", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(queue, &GuestSignalQueueKey, &GuestSignalQueueKey, NULL);
    });
    return queue;
}
static void GuestSignalSync(dispatch_block_t block) {
    if (dispatch_get_specific(&GuestSignalQueueKey)) block();
    else dispatch_sync(GuestSignalQueue(), block);
}
/// Queue-confined weak bindings. Capacity exhaustion never evicts a live socket.
@interface GuestSignalSocketRegistry : NSObject
- (instancetype)initWithCapacity:(NSUInteger)capacity;
- (BOOL)bindTask:(id)task socket:(NSUUID *)socket;
- (id)taskForSocket:(NSUUID *)socket;
- (void)unbind:(NSUUID *)socket;
@property(nonatomic, readonly) NSUInteger count;
@end
@implementation GuestSignalSocketRegistry {
    NSMapTable<NSUUID *, id> *_tasks;
    NSMutableSet<NSUUID *> *_identities;
    NSUInteger _capacity;
}
- (instancetype)initWithCapacity:(NSUInteger)capacity {
    if ((self = [super init])) {
        _tasks = [NSMapTable strongToWeakObjectsMapTable]; _identities = [NSMutableSet set]; _capacity = capacity;
    }
    return self;
}
- (BOOL)bindTask:(id)task socket:(NSUUID *)socket {
    if (!task || !socket) return NO;
    // NSMapTable's enumerator can omit expired weak entries while count still
    // includes their tombstones. Keep a bounded key set so every one is pruned.
    for (NSUUID *key in _identities.allObjects) {
        if (![_tasks objectForKey:key]) { [_tasks removeObjectForKey:key]; [_identities removeObject:key]; }
    }
    id existing = [_tasks objectForKey:socket];
    if (existing) return existing == task;
    if (_identities.count >= _capacity) return NO;
    [_tasks setObject:task forKey:socket]; [_identities addObject:socket]; return YES;
}
- (id)taskForSocket:(NSUUID *)socket { return [_tasks objectForKey:socket]; }
- (void)unbind:(NSUUID *)socket { [_tasks removeObjectForKey:socket]; [_identities removeObject:socket]; }
- (NSUInteger)count { return _identities.count; }
@end

static __weak NSURLSessionWebSocketTask *GuestObservedSendingTask;
static GuestSignalSocketRegistry *GuestSignalTasks(void) {
    static GuestSignalSocketRegistry *tasks;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ tasks = [[GuestSignalSocketRegistry alloc] initWithCapacity:16]; });
    return tasks;
}

@implementation GuestSignalCodecBridge
+ (NSUUID *)identity:(NSURLSessionWebSocketTask *)task {
    static char key;
    @synchronized (task) {
        NSUUID *identity = objc_getAssociatedObject(task, &key);
        if (!identity) {
            identity = NSUUID.UUID;
            objc_setAssociatedObject(task, &key, identity, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return identity;
    }
}
+ (NSData *)bytes:(NSURLSessionWebSocketMessage *)message {
    return message.type == NSURLSessionWebSocketMessageTypeString
        ? [message.string dataUsingEncoding:NSUTF8StringEncoding] : message.data;
}
+ (BOOL)bindObservedSocket:(NSUUID *)socket {
    // Qualification is called inside intercepted send processing. Never wait
    // for the bridge queue while a caller may own the policy operation lock.
    if (!dispatch_get_specific(&GuestSignalQueueKey)) return NO;
    NSURLSessionWebSocketTask *task = GuestObservedSendingTask;
    return task && [[self identity:task] isEqual:socket] && [GuestSignalTasks() bindTask:task socket:socket];
}
+ (void)unbindSocketAfterPendingSends:(NSUUID *)socket {
    dispatch_async(GuestSignalQueue(), ^{ [GuestSignalTasks() unbind:socket]; });
}
+ (void)sendData:(NSData *)data socket:(NSUUID *)socket when:(BOOL (^)(void))current {
    dispatch_async(GuestSignalQueue(), ^{
        NSURLSessionWebSocketTask *task = [GuestSignalTasks() taskForSocket:socket];
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        BOOL allowed = task && task.state == NSURLSessionTaskStateRunning && text && GuestOriginalSend && current();
#if DEBUG
        static NSUInteger traceCount;
        BOOL trace = [NSProcessInfo.processInfo.environment[@"ROCKNROLL_TEST_NATIVE_SHARE_TRACE"] isEqualToString:@"1"] && traceCount < 64;
        if (trace) { traceCount++; NSLog(@"LEGACY_OWN_SOCKET task=%d state=%ld allowed=%d", task != nil, task ? (long)task.state : -1L, allowed); }
#endif
        if (!allowed) return;
        NSURLSessionWebSocketMessage *message = [[NSURLSessionWebSocketMessage alloc] initWithString:text];
        GuestOriginalSend(task, @selector(sendMessage:completionHandler:), message, ^(NSError *error) {
            // The SDK owns socket recovery; no stale subscription retry survives it.
#if DEBUG
            if (trace) NSLog(@"LEGACY_OWN_COMPLETION success=%d code=%ld", error == nil, (long)error.code);
#endif
        });
    });
}
+ (BOOL)installWithOutgoing:(NSData * (^)(NSUUID *, NSData *))outgoing
                  incoming:(void (^)(NSUUID *, NSData *))incoming {
    static dispatch_once_t once;
    static BOOL installed;
    dispatch_once(&once, ^{
        // Discover the concrete implementation using a public factory. Never
        // connect this task, assume an OS class name, or use private selectors.
        NSURLSessionWebSocketTask *probe = [NSURLSession.sharedSession webSocketTaskWithURL:[NSURL URLWithString:@"wss://example.invalid/"]];
        Class cls = probe.class;
        [probe cancel];
        SEL send = @selector(sendMessage:completionHandler:);
        SEL receive = @selector(receiveMessageWithCompletionHandler:);
        Method sendMethod = class_getInstanceMethod(cls, send);
        Method receiveMethod = class_getInstanceMethod(cls, receive);
        if (!sendMethod || !receiveMethod) return;
        void (*originalSend)(id, SEL, NSURLSessionWebSocketMessage *, void (^)(NSError *)) = (void *)method_getImplementation(sendMethod);
        GuestOriginalSend = originalSend;
        void (*originalReceive)(id, SEL, void (^)(NSURLSessionWebSocketMessage *, NSError *)) = (void *)method_getImplementation(receiveMethod);
        IMP sendIMP = imp_implementationWithBlock(^(NSURLSessionWebSocketTask *task, NSURLSessionWebSocketMessage *message, void (^completion)(NSError *)) {
            GuestSignalSync(^{
            NSUUID *identity = [self identity:task];
            NSURLSessionWebSocketTask *previous = GuestObservedSendingTask;
            GuestObservedSendingTask = task;
            NSData *replacement;
            @try { replacement = outgoing(identity, [self bytes:message]); }
            @finally { GuestObservedSendingTask = previous; }
            NSURLSessionWebSocketMessage *forwarded = message;
            if (replacement) {
                if (message.type == NSURLSessionWebSocketMessageTypeString) {
                    NSString *text = [[NSString alloc] initWithData:replacement encoding:NSUTF8StringEncoding];
                    if (text) forwarded = [[NSURLSessionWebSocketMessage alloc] initWithString:text];
                } else {
                    forwarded = [[NSURLSessionWebSocketMessage alloc] initWithData:replacement];
                }
            }
            originalSend(task, send, forwarded, completion);
            });
        });
        IMP receiveIMP = imp_implementationWithBlock(^(NSURLSessionWebSocketTask *task, void (^completion)(NSURLSessionWebSocketMessage *, NSError *)) {
            NSUUID *identity = [self identity:task];
            originalReceive(task, receive, ^(NSURLSessionWebSocketMessage *message, NSError *error) {
                if (message) GuestSignalSync(^{ incoming(identity, [self bytes:message]); });
                completion(message, error);
            });
        });
        // Add overrides if inherited, rather than modifying a superclass used
        // by unrelated task implementations. Forward completions exactly once.
        if (!class_addMethod(cls, send, sendIMP, method_getTypeEncoding(sendMethod))) class_replaceMethod(cls, send, sendIMP, method_getTypeEncoding(sendMethod));
        if (!class_addMethod(cls, receive, receiveIMP, method_getTypeEncoding(receiveMethod))) class_replaceMethod(cls, receive, receiveIMP, method_getTypeEncoding(receiveMethod));
        installed = YES;
    });
    return installed;
}
@end
