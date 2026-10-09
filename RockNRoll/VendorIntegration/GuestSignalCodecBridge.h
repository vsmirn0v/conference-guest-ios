#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Public Foundation message boundary for the pinned SDK, whose settings do
/// not expose publishing codec selection. No SDK binary or SDP is modified.
@interface GuestSignalCodecBridge : NSObject
+ (BOOL)installWithOutgoing:(NSData * _Nullable (^)(NSUUID *, NSData *))outgoing
                  incoming:(void (^)(NSUUID *, NSData *))incoming NS_SWIFT_NAME(install(outgoing:incoming:));
@end
NS_ASSUME_NONNULL_END
