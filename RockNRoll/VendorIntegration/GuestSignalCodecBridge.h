#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Public Foundation message boundary for the pinned SDK, whose settings do
/// not expose publishing codec selection. No SDK binary or SDP is modified.
@interface GuestSignalCodecBridge : NSObject
+ (BOOL)installWithOutgoing:(NSData * _Nullable (^)(NSUUID *, NSData *))outgoing
                  incoming:(void (^)(NSUUID *, NSData *))incoming NS_SWIFT_NAME(install(outgoing:incoming:));
/// Only the current intercepted SDK join may establish a weak socket binding.
+ (BOOL)bindObservedSocket:(NSUUID *)socket NS_SWIFT_NAME(bindObservedSocket(_:));
/// Queued after exact-socket cleanup sends, never before them.
+ (void)unbindSocketAfterPendingSends:(NSUUID *)socket NS_SWIFT_NAME(unbindAfterPendingSends(_:));
/// Sends on the exact observed socket, bypassing the SDK-intent interceptor.
+ (void)sendData:(NSData *)data socket:(NSUUID *)socket when:(BOOL (^)(void))current
    NS_SWIFT_NAME(send(_:socket:when:));
@end
NS_ASSUME_NONNULL_END
