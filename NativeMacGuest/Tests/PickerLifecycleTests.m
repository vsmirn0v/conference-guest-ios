#import <Foundation/Foundation.h>
#import "MacScreenCaptureBridge.h"

@interface PickerFixture : NSObject
@property BOOL active;
@property NSObject *defaultConfiguration;
@property NSNumber *maximumStreamCount;
@property NSInteger style;
@property NSInteger presentations;
@property NSInteger additions;
@property NSInteger removals;
@property(copy) void (^onRemove)(void);
@end
@implementation PickerFixture
- (BOOL)isActive { return self.active; }
- (void)addObserver:(NSObject *)observer { self.additions++; }
- (void)removeObserver:(NSObject *)observer { self.removals++; if (self.onRemove) self.onRemove(); }
- (void)present { self.style = 0; self.presentations++; }
- (void)presentPickerUsingContentStyle:(NSInteger)style { self.style = style; self.presentations++; }
- (void)presentPickerForStream:(NSObject *)stream { [self present]; }
- (void)presentPickerForStream:(NSObject *)stream usingContentStyle:(NSInteger)style { [self presentPickerUsingContentStyle:style]; }
@end

static void Pump(void) { for (int n = 0; n < 4; n++) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]]; }
int main(void) {
    @autoreleasepool {
        [MacScreenCaptureBridge isSupported]; // Load public types, without presenting real UI or opening capture.
        PickerFixture *picker = [PickerFixture new];
        NSObject *prior = [NSObject new]; picker.defaultConfiguration = prior; picker.maximumStreamCount = @0;
        ScreenCapturePickerCoordinator *coordinator = [[ScreenCapturePickerCoordinator alloc] initWithPicker:picker];
        ScreenCapturePickerSession *window = [[ScreenCapturePickerSession alloc] initWithCoordinator:coordinator];
        window.selectionMode = MacScreenCaptureSelectionModeWindow;
        NSError *error;
        NSCAssert([window presentWithError:&error], @"Window request must be accepted");
        NSCAssert(picker.maximumStreamCount.integerValue > 0, @"Zero maximum must not suppress a new-stream picker");
        if ([picker.defaultConfiguration respondsToSelector:NSSelectorFromString(@"allowedPickerModes")])
            NSCAssert([[picker.defaultConfiguration valueForKey:@"allowedPickerModes"] unsignedIntegerValue] == 1, @"Window request must restrict only user-selectable mode");
        Pump(); NSCAssert(picker.presentations == 1 && picker.style == 1 && picker.active, @"Window-only user selector must be explicit");
        NSObject *selected = [NSObject new]; __block int deliveries = 0;
        window.onFilter = ^(NSObject *filter) { NSCAssert(filter == selected, @"Exact user-selected filter"); deliveries++; };
        [coordinator contentSharingPicker:picker didUpdateWithFilter:selected forStream:nil]; Pump();
        NSCAssert(deliveries == 1, @"Selection must route exactly once");
        [window invalidate];
        NSCAssert(!picker.active && picker.defaultConfiguration == prior && picker.maximumStreamCount.integerValue == 0, @"Last stop restores picker ownership and configuration");
        ScreenCapturePickerSession *retired = [[ScreenCapturePickerSession alloc] initWithCoordinator:coordinator];
        NSCAssert([retired presentWithError:&error], @"General request"); [retired invalidate]; Pump();
        NSCAssert(picker.presentations == 1, @"Cancellation before main-turn presentation must not open an obsolete chooser");
        ScreenCapturePickerSession *general = [[ScreenCapturePickerSession alloc] initWithCoordinator:coordinator];
        NSCAssert([general presentWithError:&error], @"General request"); Pump();
        NSCAssert(picker.style == 0 && picker.presentations == 2, @"General UI must not be forced to window mode");
        NSCAssert([[picker.defaultConfiguration valueForKey:@"allowedPickerModes"] unsignedIntegerValue] == 31,
                  @"General selection must explicitly allow all five public modes; zero can silently reject the chooser");
        __block BOOL rejected = NO;
        picker.onRemove = ^{
            ScreenCapturePickerSession *replacement = [[ScreenCapturePickerSession alloc] initWithCoordinator:coordinator];
            NSError *rejection; rejected = ![replacement presentWithError:&rejection];
        };
        [general invalidate];
        NSCAssert(rejected && !picker.active, @"Reentrant replacement cannot be clobbered by old observer removal");
        picker.onRemove = nil;
        ScreenCapturePickerSession *stale = [[ScreenCapturePickerSession alloc] initWithCoordinator:coordinator];
        __block int staleDeliveries = 0; stale.onFilter = ^(NSObject *filter) { staleDeliveries++; };
        NSCAssert([stale presentWithError:&error], @"Old request"); Pump();
        [coordinator contentSharingPicker:picker didUpdateWithFilter:selected forStream:nil];
        [stale invalidate];
        ScreenCapturePickerSession *next = [[ScreenCapturePickerSession alloc] initWithCoordinator:coordinator];
        next.onFilter = ^(NSObject *filter) { NSCAssert(NO, @"Old selection must never reach a replacement"); };
        NSCAssert([next presentWithError:&error], @"Replacement request"); Pump();
        NSCAssert(staleDeliveries == 0 && picker.active, @"A queued obsolete filter must be rejected after owner replacement");
        [next invalidate];
        puts("PASS: explicit window picker, positive stream capacity, general choice, exact filter routing, queued cancel, configuration restore and reentrant removal; no capture/UI");
    }
    return 0;
}
