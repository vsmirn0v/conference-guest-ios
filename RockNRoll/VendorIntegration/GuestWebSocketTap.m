#import "GuestWebSocketTap.h"
#import <objc/runtime.h>

@interface GuestWebSocketTap ()
@property (atomic, copy) void (^handler)(NSURLSessionWebSocketTask *, BOOL, NSData *);
@end

@implementation GuestWebSocketTap
static NSRecursiveLock *tapLock;
static NSHashTable<GuestWebSocketTap *> *activeTaps;
static NSMapTable<NSURLSessionWebSocketTask *, NSHashTable<GuestWebSocketTap *> *> *taskTaps;
static NSMutableSet<NSValue *> *installedImplementations;

+ (void)initialize {
    if (self != GuestWebSocketTap.class) return;
    tapLock = [NSRecursiveLock new];
    activeTaps = [NSHashTable weakObjectsHashTable];
    taskTaps = [NSMapTable weakToStrongObjectsMapTable];
    installedImplementations = [NSMutableSet new];
}

static IMP originalMethod(Class cls, SEL selector) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NULL;
    IMP original = method_getImplementation(method);
    return [installedImplementations containsObject:[NSValue valueWithPointer:original]] ? NULL : original;
}

static void replaceMethod(Class cls, SEL selector, id block) {
    Method method = class_getInstanceMethod(cls, selector);
    IMP replacement = imp_implementationWithBlock(block);
    const char *encoding = method_getTypeEncoding(method);
    if (!class_addMethod(cls, selector, replacement, encoding)) {
        class_replaceMethod(cls, selector, replacement, encoding);
    }
    [installedImplementations addObject:[NSValue valueWithPointer:replacement]];
}

static void emitMessage(NSURLSessionWebSocketTask *task, BOOL outgoing, NSURLSessionWebSocketMessage *message) {
    [tapLock lock];
    NSArray<GuestWebSocketTap *> *subscriptions = [taskTaps objectForKey:task].allObjects;
    [tapLock unlock];
    if (!message || subscriptions.count == 0) return;
    NSData *data = message.type == NSURLSessionWebSocketMessageTypeString
        ? [message.string dataUsingEncoding:NSUTF8StringEncoding] : message.data;
    // The receive adapter needs only small formal events, not media or documents.
    if (!data || data.length > 64 * 1024) return;
    for (GuestWebSocketTap *tap in subscriptions) {
        void (^handler)(NSURLSessionWebSocketTask *, BOOL, NSData *) = tap.handler;
        if (handler) handler(task, outgoing, data);
    }
}

static void registerTask(NSURLSessionWebSocketTask *task) {
    if (!task) return;
    [tapLock lock];
    NSArray<GuestWebSocketTap *> *subscriptions = activeTaps.allObjects;
    if (subscriptions.count == 0) { [tapLock unlock]; return; }
    // Never reassign an existing task to a later media-attempt scope.
    if ([taskTaps objectForKey:task]) { [tapLock unlock]; return; }
    NSHashTable *registered = [NSHashTable weakObjectsHashTable];
    for (GuestWebSocketTap *tap in subscriptions) [registered addObject:tap];
    [taskTaps setObject:registered forKey:task];
    Class cls = object_getClass(task);
    SEL receive = @selector(receiveMessageWithCompletionHandler:);
    IMP receiveIMP = originalMethod(cls, receive);
    if (receiveIMP) {
        typedef void (^Completion)(NSURLSessionWebSocketMessage *, NSError *);
        typedef void (*Receive)(id, SEL, Completion);
        replaceMethod(cls, receive, ^(NSURLSessionWebSocketTask *target, Completion completion) {
            [tapLock lock];
            BOOL watched = [taskTaps objectForKey:target].allObjects.count > 0;
            [tapLock unlock];
            if (!watched) { ((Receive)receiveIMP)(target, receive, completion); return; }
            ((Receive)receiveIMP)(target, receive, ^(NSURLSessionWebSocketMessage *message, NSError *error) {
                completion(message, error);
                if (!error) emitMessage(target, NO, message);
            });
        });
    }
    SEL send = @selector(sendMessage:completionHandler:);
    IMP sendIMP = originalMethod(cls, send);
    if (sendIMP) {
        typedef void (*Send)(id, SEL, NSURLSessionWebSocketMessage *, void (^)(NSError *));
        replaceMethod(cls, send, ^(NSURLSessionWebSocketTask *target, NSURLSessionWebSocketMessage *message,
                                  void (^completion)(NSError *)) {
            emitMessage(target, YES, message);
            ((Send)sendIMP)(target, send, message, completion);
        });
    }
    [tapLock unlock];
}

static void prepareFactory(void) {
    // Obtain the concrete implementation through a public local session; no
    // private class names or SDK objects are queried. This creates no request.
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    Class cls = object_getClass(session);
    for (NSString *name in @[@"webSocketTaskWithRequest:", @"webSocketTaskWithURL:"]) {
        SEL selector = NSSelectorFromString(name);
        IMP original = originalMethod(cls, selector);
        if (!original) continue;
        typedef NSURLSessionWebSocketTask *(*Factory)(id, SEL, id);
        replaceMethod(cls, selector, ^NSURLSessionWebSocketTask *(NSURLSession *target, id argument) {
            NSURLSessionWebSocketTask *task = ((Factory)original)(target, selector, argument);
            registerTask(task);
            return task;
        });
    }
    SEL protocols = @selector(webSocketTaskWithURL:protocols:);
    IMP original = originalMethod(cls, protocols);
    if (original) {
        typedef NSURLSessionWebSocketTask *(*Factory)(id, SEL, NSURL *, NSArray *);
        replaceMethod(cls, protocols, ^NSURLSessionWebSocketTask *(NSURLSession *target, NSURL *url, NSArray *values) {
            NSURLSessionWebSocketTask *task = ((Factory)original)(target, protocols, url, values);
            registerTask(task);
            return task;
        });
    }
    [session invalidateAndCancel];
}

- (instancetype)initWithHandler:(void (^)(NSURLSessionWebSocketTask *, BOOL, NSData *))handler {
    self = [super init];
    if (!self) return nil;
    _handler = [handler copy];
    [tapLock lock];
    prepareFactory();
    [activeTaps addObject:self];
    [tapLock unlock];
    return self;
}

- (void)invalidate {
    [tapLock lock];
    [activeTaps removeObject:self];
    for (NSURLSessionWebSocketTask *task in taskTaps.keyEnumerator) {
        [[taskTaps objectForKey:task] removeObject:self];
    }
    self.handler = nil;
    [tapLock unlock];
}
- (void)dealloc { [self invalidate]; }
@end
