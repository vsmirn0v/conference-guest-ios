#import "GuestSignalCodecBridge.h"
#import <objc/runtime.h>

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
        void (*originalReceive)(id, SEL, void (^)(NSURLSessionWebSocketMessage *, NSError *)) = (void *)method_getImplementation(receiveMethod);
        IMP sendIMP = imp_implementationWithBlock(^(NSURLSessionWebSocketTask *task, NSURLSessionWebSocketMessage *message, void (^completion)(NSError *)) {
            NSData *replacement = outgoing([self identity:task], [self bytes:message]);
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
        IMP receiveIMP = imp_implementationWithBlock(^(NSURLSessionWebSocketTask *task, void (^completion)(NSURLSessionWebSocketMessage *, NSError *)) {
            NSUUID *identity = [self identity:task];
            originalReceive(task, receive, ^(NSURLSessionWebSocketMessage *message, NSError *error) {
                if (message) incoming(identity, [self bytes:message]);
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
