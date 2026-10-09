#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Observes messages on public WebSocket tasks created during this subscription.
/// It never opens a connection, sends a message, or changes a completion result.
@interface GuestWebSocketTap : NSObject
- (instancetype)initWithHandler:(void (^)(NSURLSessionWebSocketTask *task, BOOL outgoing, NSData *data))handler;
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
