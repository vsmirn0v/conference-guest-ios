#import "MacMeetingWindowBridge.h"
#import <UIKit/UIKit.h>

// Exact public AppKit ABI. The iOS SDK does not declare these methods.
@protocol RockNativeApplication <NSObject>
- (id)mainWindow;
- (NSArray *)windows;
- (void)hide:(id)sender;
- (void)unhide:(id)sender;
- (void)activateIgnoringOtherApps:(BOOL)flag;
- (void)terminate:(id)sender;
- (BOOL)isHidden;
@end
@protocol RockNativeWindow <NSObject>
- (id)delegate;
- (void)setDelegate:(id)delegate;
- (void)deminiaturize:(id)sender;
- (BOOL)isMiniaturized;
- (BOOL)isVisible;
- (NSUInteger)styleMask;
- (NSInteger)level;
- (id)sheetParent;
- (id)parentWindow;
- (id)standardWindowButton:(NSUInteger)button;
- (void)performClose:(id)sender;
@end
@interface NSObject (RockPublicAppKit)
+ (id)sharedApplication;
+ (id)systemStatusBar;
+ (id)imageWithSystemSymbolName:(NSString *)name accessibilityDescription:(NSString *)description;
- (id)statusItemWithLength:(CGFloat)length;
- (void)removeStatusItem:(id)item;
- (id)button;
- (void)setImage:(id)image;
- (void)setTemplate:(BOOL)flag;
- (void)setToolTip:(NSString *)text;
- (void)setMenu:(id)menu;
- (id)menu;
- (NSArray *)itemArray;
- (void)performActionForItemAtIndex:(NSInteger)index;
- (id)initWithTitle:(NSString *)title;
- (id)initWithTitle:(NSString *)title action:(SEL)action keyEquivalent:(NSString *)key;
- (void)addItem:(id)item;
+ (id)separatorItem;
- (void)setSubmenu:(id)menu;
- (void)setTarget:(id)target;
- (id)target;
- (SEL)action;
- (void)setAction:(SEL)action;
- (void)performClick:(id)sender;
- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender;
- (void)setRepresentedObject:(id)object;
- (id)representedObject;
- (void)setEnabled:(BOOL)enabled;
- (void)setState:(NSInteger)state;
- (void)setAutoenablesItems:(BOOL)flag;
@end

static BOOL RockEligibleMeetingWindow(id<RockNativeWindow> window) {
    for (NSString *name in @[@"isVisible", @"styleMask", @"level", @"sheetParent", @"parentWindow"])
        if (![window respondsToSelector:NSSelectorFromString(name)]) return NO;
    return ![window isKindOfClass:NSClassFromString(@"NSPanel")] && [window isVisible] &&
        ([window styleMask] & 1) && [window level] == 0 && ![window sheetParent] && ![window parentWindow];
}
static id RockUniqueMeetingWindow(NSArray *windows) {
    id selected = nil;
    for (id window in windows) if (RockEligibleMeetingWindow(window)) {
        if (selected) return nil;
        selected = window;
    }
    return selected;
}

@interface RockWindowDelegateProxy : NSObject
@property(nonatomic, weak) id original;
@property(nonatomic, weak) id window;
@property(nonatomic, copy) BOOL (^hideForMeeting)(void);
@end
@implementation RockWindowDelegateProxy
- (BOOL)windowShouldClose:(id)sender {
    if (sender == self.window && self.hideForMeeting && self.hideForMeeting()) return NO;
    id original = self.original;
    if ([original respondsToSelector:_cmd]) {
        BOOL (*invoke)(id, SEL, id) = (void *)[original methodForSelector:_cmd];
        return invoke(original, _cmd, sender);
    }
    return YES;
}
- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [self.original respondsToSelector:selector];
}
- (BOOL)conformsToProtocol:(Protocol *)protocol {
    return [super conformsToProtocol:protocol] || [self.original conformsToProtocol:protocol];
}
- (id)forwardingTargetForSelector:(SEL)selector {
    return [self.original respondsToSelector:selector] ? self.original : [super forwardingTargetForSelector:selector];
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [super methodSignatureForSelector:selector] ?: [self.original methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
    id original = self.original;
    if ([original respondsToSelector:invocation.selector]) [invocation invokeWithTarget:original];
    else [super forwardInvocation:invocation];
}
@end

@interface RockMacMeetingWindowBridge ()
@property(nonatomic, strong) id<RockNativeApplication> application;
@property(nonatomic, weak) id<RockNativeWindow> window;
@property(nonatomic, strong) RockWindowDelegateProxy *proxy;
@property(nonatomic, strong) id statusBar;
@property(nonatomic, strong) id statusItem;
@property(nonatomic, copy) void (^action)(NSString *);
@property(nonatomic) BOOL active;
@property(nonatomic, weak) UIWindow *owningWindow;
@property(nonatomic) BOOL bindingPending;
@property(nonatomic) BOOL invalidated;
@property(nonatomic, weak) id closeButton;
@property(nonatomic, weak) id closeTarget;
@property(nonatomic) SEL closeAction;
@property(nonatomic) NSUInteger visibilityRevision;
@property(nonatomic, readwrite) BOOL hiddenForMeeting;
@end

@implementation RockMacMeetingWindowBridge
- (instancetype)initWithWindow:(UIWindow *)window action:(void (^)(NSString *))action {
    if ((self = [super init])) {
        _action = [action copy];
        _owningWindow = window;
        if (!NSProcessInfo.processInfo.isiOSAppOnMac) return self;
        Class application = NSClassFromString(@"NSApplication");
        Class statusBar = NSClassFromString(@"NSStatusBar");
        if (![application respondsToSelector:@selector(sharedApplication)] ||
            ![statusBar respondsToSelector:@selector(systemStatusBar)]) return self;
        id app = [application sharedApplication];
        for (NSString *name in @[@"mainWindow", @"hide:", @"unhide:", @"terminate:", @"activateIgnoringOtherApps:"]) {
            if (![app respondsToSelector:NSSelectorFromString(name)]) return self;
        }
        _application = app;
        _statusBar = [statusBar systemStatusBar];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(willTerminate:)
            name:@"NSApplicationWillTerminateNotification" object:app];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(nativeWindowReady:)
            name:@"NSWindowDidBecomeMainNotification" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(nativeWindowReady:)
            name:@"NSWindowDidDeminiaturizeNotification" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(nativeWindowReady:)
            name:@"NSApplicationDidBecomeActiveNotification" object:app];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowUpdated:)
            name:@"NSWindowDidUpdateNotification" object:nil];
    }
    return self;
}
- (BOOL)bindMainWindow {
    NSAssert(NSThread.isMainThread, @"Mac window binding must be on main");
    if (!self.application || self.invalidated) return NO;
    if (self.proxy && !self.window) return NO; // A new scene needs a new coordinator.
    if (self.window) {
        if ([self.window delegate] != self.proxy) return NO;
        [self bindCloseButton];
        return YES;
    }
    NSArray *scenes = [UIApplication.sharedApplication.connectedScenes.allObjects filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(UIScene *scene, NSDictionary *bindings) {
            return [scene isKindOfClass:UIWindowScene.class] &&
                (scene.activationState == UISceneActivationStateForegroundActive || scene.activationState == UISceneActivationStateForegroundInactive) &&
                [scene.session.role isEqualToString:UIWindowSceneSessionRoleApplication];
        }]];
    if (scenes.count != 1) return NO;
    UIWindowScene *scene = scenes.firstObject;
    NSArray *visibleWindows = [scene.windows filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(UIWindow *window, NSDictionary *bindings) {
            return !window.isHidden && window.windowLevel == UIWindowLevelNormal;
        }]];
    if (visibleWindows.count != 1 || visibleWindows.firstObject != self.owningWindow) return NO;
    id window = [self.application mainWindow];
    if (!window) {
        window = RockUniqueMeetingWindow([self.application windows]);
    }
    if (!RockEligibleMeetingWindow(window)) return NO;
    for (NSString *name in @[@"delegate", @"setDelegate:", @"deminiaturize:", @"isMiniaturized"]) {
        if (![window respondsToSelector:NSSelectorFromString(name)]) return NO;
    }
    self.window = window;
    RockWindowDelegateProxy *proxy = [RockWindowDelegateProxy new];
    proxy.original = [self.window delegate];
    proxy.window = window;
    __weak typeof(self) weakSelf = self;
    proxy.hideForMeeting = ^BOOL {
        return [weakSelf hideMeeting];
    };
    self.proxy = proxy;
    [self.window setDelegate:proxy];
    [self bindCloseButton];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"NSWindowDidUpdateNotification" object:nil];
    return [self.window delegate] == proxy;
}
- (void)restoreCloseButton {
    if ([self.closeButton target] == self && [self.closeButton action] == @selector(closeButtonAction:)) {
        [self.closeButton setTarget:self.closeTarget];
        [self.closeButton setAction:self.closeAction];
    }
    self.closeButton = nil; self.closeTarget = nil; self.closeAction = NULL;
}
- (void)bindCloseButton {
    if (![self.window respondsToSelector:@selector(standardWindowButton:)]) return;
    id button = [self.window standardWindowButton:0]; // NSWindowCloseButton
    if (button == self.closeButton && [button target] == self && [button action] == @selector(closeButtonAction:)) return;
    [self restoreCloseButton];
    if (![button respondsToSelector:@selector(target)] || ![button respondsToSelector:@selector(action)] ||
        ![button respondsToSelector:@selector(setTarget:)] || ![button respondsToSelector:@selector(setAction:)]) return;
    if (![button action]) return; // Preserve native handling when there is no action to forward.
    self.closeButton = button; self.closeTarget = [button target]; self.closeAction = [button action];
    [button setTarget:self]; [button setAction:@selector(closeButtonAction:)];
}
- (void)closeButtonAction:(id)sender {
    if ([self hideMeeting]) return;
    if (self.closeAction) [(id)self.application sendAction:self.closeAction to:self.closeTarget from:sender];
}
- (BOOL)hideMeeting {
    if (!self.active || !self.statusItem || !self.window || [self.window delegate] != self.proxy) return NO;
    self.hiddenForMeeting = YES;
    self.visibilityRevision++;
    [self.application hide:nil];
    if (self.action) self.action(@"hidden");
    return YES;
}
- (void)windowUpdated:(NSNotification *)notification {
    if (self.proxy || self.invalidated || self.bindingPending) return;
    self.bindingPending = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        self.bindingPending = NO;
        if (self && !self.proxy && !self.invalidated && [self bindMainWindow] && self.action) self.action(@"binding");
    });
}
- (void)nativeWindowReady:(NSNotification *)notification {
    if (([notification.name isEqualToString:@"NSWindowDidBecomeMainNotification"] ||
         [notification.name isEqualToString:@"NSWindowDidDeminiaturizeNotification"]) &&
        notification.object != (self.window ?: [self.application mainWindow])) return;
    if (self.action) self.action(@"binding");
}
- (id)makeMenu:(NSArray<NSDictionary *> *)items title:(NSString *)title {
    id menu = [[NSClassFromString(@"NSMenu") alloc] initWithTitle:title];
    [menu setAutoenablesItems:NO];
    for (NSDictionary *entry in items) {
        id item;
        if (entry[@"separator"]) item = [NSClassFromString(@"NSMenuItem") separatorItem];
        else {
            item = [[NSClassFromString(@"NSMenuItem") alloc] initWithTitle:entry[@"title"] ?: @""
                action:entry[@"action"] ? @selector(menuAction:) : NULL keyEquivalent:@""];
            [item setTarget:self];
            [item setRepresentedObject:entry[@"action"]];
            [item setEnabled:entry[@"enabled"] ? [entry[@"enabled"] boolValue] : YES];
            [item setState:[entry[@"selected"] boolValue] ? 1 : 0];
            if (entry[@"tooltip"]) [item setToolTip:entry[@"tooltip"]];
            if (entry[@"children"]) [item setSubmenu:[self makeMenu:entry[@"children"] title:entry[@"title"]]];
        }
        [menu addItem:item];
    }
    return menu;
}
- (void)updateActive:(BOOL)active title:(NSString *)title microphoneOn:(BOOL)microphoneOn menu:(NSArray<NSDictionary *> *)items {
    NSAssert(NSThread.isMainThread, @"Mac menu updates must be on main");
    self.active = active;
    if (!active) {
        if (self.hiddenForMeeting) [self showMeeting];
        if (self.statusItem) [self.statusBar removeStatusItem:self.statusItem];
        self.statusItem = nil;
        return;
    }
    if (!self.application || !self.window || [self.window delegate] != self.proxy) return;
    if (!self.statusItem) self.statusItem = [self.statusBar statusItemWithLength:-1]; // NSVariableStatusItemLength
    id image = [NSClassFromString(@"NSImage") imageWithSystemSymbolName:
        microphoneOn ? @"mic.fill" : @"mic.slash.fill" accessibilityDescription:title];
    [image setTemplate:YES];
    id button = [self.statusItem button];
    [button setImage:image];
    [button setToolTip:title];
    [self.statusItem setMenu:[self makeMenu:items title:title]];
}
- (void)menuAction:(id)sender {
    NSString *action = [sender representedObject];
    if ([action isEqualToString:@"show"]) [self showMeeting];
    else if ([action isEqualToString:@"quit"]) [self.application terminate:nil];
    else if (self.active && self.action) self.action(action);
}
- (void)closeMeetingWindow {
    if (![self hideMeeting]) [self.window performClose:nil];
}
- (void)showMeeting {
    if (!self.window) return;
    NSUInteger revision = ++self.visibilityRevision;
    [self.application unhide:nil];
    if ([self.window isMiniaturized]) [self.window deminiaturize:nil];
    [self.owningWindow makeKeyAndVisible];
    [self.application activateIgnoringOtherApps:YES];
    [self completeVisibility:revision attempt:0];
}
- (void)completeVisibility:(NSUInteger)revision attempt:(NSUInteger)attempt {
    if (self.invalidated || self.visibilityRevision != revision || !self.window || [self.window delegate] != self.proxy) return;
    if (![self.application isHidden] && [self.window isVisible]) {
        self.hiddenForMeeting = NO;
        if (self.action) self.action(@"visible");
    } else if (attempt < 10) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [weakSelf completeVisibility:revision attempt:attempt + 1];
        });
    }
}
- (void)markVisible {
    if (self.window && ![self.application isHidden] && [self.window isVisible]) self.hiddenForMeeting = NO;
}
- (void)willTerminate:(NSNotification *)notification {
    self.active = NO;
    if (self.action) self.action(@"terminate");
}
- (void)invalidate {
    self.invalidated = YES;
    self.visibilityRevision++;
    self.active = NO; self.action = nil; self.hiddenForMeeting = NO;
    [self restoreCloseButton];
    if (self.window && [self.window delegate] == self.proxy) [self.window setDelegate:self.proxy.original];
    if (self.statusItem) [self.statusBar removeStatusItem:self.statusItem];
    self.statusItem = nil; self.proxy = nil; self.window = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
- (void)dealloc { [self invalidate]; }
#if DEBUG
- (void)closeForTesting {
    id button = [self.window standardWindowButton:0];
    if (button) [button performClick:nil]; else [self.window performClose:nil];
}
- (void)closeThroughDelegateForTesting { [self.window performClose:nil]; }
- (NSDictionary *)stateForTesting {
    return @{@"bound": @(self.window && [self.window delegate] == self.proxy),
        @"hidden": @(self.hiddenForMeeting), @"active": @(self.active), @"statusItem": @(self.statusItem != nil),
        @"sceneState": @(self.owningWindow.windowScene.activationState), @"uiKey": @(self.owningWindow.isKeyWindow),
        @"uiHidden": @(self.owningWindow.isHidden)};
}
- (BOOL)invokeMenuActionForTesting:(NSString *)action {
    id menu = [self.statusItem menu];
    NSArray *items = [menu itemArray];
    for (NSUInteger index = 0; index < items.count; index++) {
        if ([[items[index] representedObject] isEqual:action]) {
            [menu performActionForItemAtIndex:index];
            return YES;
        }
    }
    return NO;
}
#endif
@end

#if DEBUG
NSDictionary *RockMacMeetingBridgeDiagnostics(void) {
    if (!NSProcessInfo.processInfo.isiOSAppOnMac) return @{@"mac": @NO};
    id<RockNativeApplication> app = [NSClassFromString(@"NSApplication") sharedApplication];
    id<RockNativeWindow> window = [app mainWindow];
    NSMutableArray *windows = [NSMutableArray new];
    for (id<RockNativeWindow> item in [app windows]) {
        [windows addObject:@{@"class": NSStringFromClass([item class]), @"style": @([item styleMask]),
            @"level": @([item level]), @"visible": @([item isVisible])}];
    }
    return @{@"mac": @YES, @"window": NSStringFromClass([window class]) ?: @"nil",
        @"delegate": NSStringFromClass([[window delegate] class]) ?: @"nil", @"nativeWindows": windows};
}
@interface RockProxyTestDelegate : NSObject
@property(nonatomic) NSUInteger notifications;
@property(nonatomic) NSUInteger closes;
- (BOOL)windowShouldClose:(id)window;
- (NSInteger)scalarValue;
- (CGRect)rectangleValue;
- (void)rockTestNotification;
- (void)testClose:(id)sender;
@end
@implementation RockProxyTestDelegate
- (BOOL)windowShouldClose:(id)window { return NO; }
- (NSInteger)scalarValue { return 42; }
- (CGRect)rectangleValue { return CGRectMake(1, 2, 3, 4); }
- (void)rockTestNotification { self.notifications++; }
- (void)testClose:(id)sender { self.closes++; }
@end
@interface RockCloseTestButton : NSObject
@property(nonatomic, weak) id target;
@property(nonatomic) SEL action;
@end
@implementation RockCloseTestButton
@end
@interface RockProxyTestWindow : NSObject
@property(nonatomic, weak) id delegate;
@property(nonatomic) BOOL isVisible;
@property(nonatomic) NSUInteger styleMask;
@property(nonatomic) NSInteger level;
@property(nonatomic, strong) id sheetParent;
@property(nonatomic, strong) id parentWindow;
@property(nonatomic, strong) RockCloseTestButton *closeButton;
@end
@implementation RockProxyTestWindow
- (id)standardWindowButton:(NSUInteger)button { return self.closeButton; }
@end
@interface RockCloseTestApplication : NSObject
@property(nonatomic) NSUInteger hides;
@property(nonatomic) BOOL isHidden;
@end
@implementation RockCloseTestApplication
- (void)hide:(id)sender { self.hides++; }
- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender {
    if (![target respondsToSelector:action]) return NO;
    void (*invoke)(id, SEL, id) = (void *)[target methodForSelector:action];
    invoke(target, action, sender);
    return YES;
}
@end
BOOL RockMacMeetingVisibilityQualification(void) {
    RockProxyTestWindow *window = [RockProxyTestWindow new];
    RockWindowDelegateProxy *proxy = [RockWindowDelegateProxy new]; window.delegate = proxy;
    RockCloseTestApplication *app = [RockCloseTestApplication new];
    RockMacMeetingWindowBridge *bridge = [[RockMacMeetingWindowBridge alloc] initWithWindow:nil action:^(NSString *action) {}];
    [bridge invalidate]; bridge.invalidated = NO;
    bridge.application = (id)app; bridge.window = (id)window; bridge.proxy = proxy;
    bridge.hiddenForMeeting = YES;
    __block NSUInteger visible = 0;
    bridge.action = ^(NSString *action) { if ([action isEqualToString:@"visible"]) visible++; };
    NSUInteger revision = ++bridge.visibilityRevision;
    [bridge completeVisibility:revision attempt:10];
    [bridge markVisible];
    BOOL correct = bridge.hiddenForMeeting && visible == 0;
    window.isVisible = YES;
    [bridge completeVisibility:revision attempt:10];
    correct &= !bridge.hiddenForMeeting && visible == 1;
    bridge.hiddenForMeeting = YES; bridge.visibilityRevision++;
    [bridge completeVisibility:revision attempt:10];
    correct &= bridge.hiddenForMeeting && visible == 1;
    revision = bridge.visibilityRevision;
    [bridge invalidate];
    [bridge completeVisibility:revision attempt:10];
    return correct && visible == 1;
}
BOOL RockMacMeetingCloseButtonQualification(void) {
    RockProxyTestDelegate *original = [RockProxyTestDelegate new];
    RockCloseTestButton *button = [RockCloseTestButton new];
    button.target = original; button.action = @selector(testClose:);
    RockProxyTestWindow *window = [RockProxyTestWindow new]; window.closeButton = button;
    RockWindowDelegateProxy *proxy = [RockWindowDelegateProxy new];
    proxy.original = original; window.delegate = proxy;
    RockMacMeetingWindowBridge *bridge = [[RockMacMeetingWindowBridge alloc] initWithWindow:nil action:^(NSString *action) {}];
    [bridge invalidate]; // Remove native observers before using test doubles.
    RockCloseTestApplication *app = [RockCloseTestApplication new];
    bridge.application = (id)app; bridge.statusBar = nil;
    bridge.window = (id)window; bridge.proxy = proxy; bridge.statusItem = [NSObject new];
    bridge.active = YES;
    [bridge bindCloseButton];
    [bridge closeButtonAction:button];
    BOOL correct = app.hides == 1 && original.closes == 0 && bridge.hiddenForMeeting;
    bridge.active = NO;
    [bridge closeButtonAction:button];
    correct &= original.closes == 1 && app.hides == 1;
    [bridge invalidate];
    correct &= button.target == original && button.action == @selector(testClose:);
    bridge.window = (id)window; bridge.proxy = proxy;
    [bridge bindCloseButton];
    RockProxyTestDelegate *replacement = [RockProxyTestDelegate new];
    button.target = replacement; button.action = @selector(rockTestNotification);
    [bridge invalidate];
    correct &= button.target == replacement && button.action == @selector(rockTestNotification);
    bridge.window = (id)window; bridge.proxy = proxy;
    button.target = original; button.action = NULL;
    [bridge bindCloseButton];
    correct &= button.target == original && button.action == NULL;
    [bridge invalidate];
    return correct;
}
BOOL RockMacMeetingProxyQualification(void) {
    RockProxyTestDelegate *original = [RockProxyTestDelegate new];
    RockWindowDelegateProxy *proxy = [RockWindowDelegateProxy new];
    proxy.original = original; proxy.window = original;
    __block NSUInteger hidden = 0;
    proxy.hideForMeeting = ^BOOL { hidden++; return YES; };
    id forwarded = proxy;
    BOOL correct = ![proxy windowShouldClose:original] && hidden == 1 &&
        ![proxy windowShouldClose:[NSObject new]] && hidden == 1 &&
        [forwarded respondsToSelector:@selector(rectangleValue)] &&
        [forwarded scalarValue] == 42 && CGRectEqualToRect([forwarded rectangleValue], CGRectMake(1, 2, 3, 4));
    [forwarded rockTestNotification];
    correct &= original.notifications == 1;
    RockProxyTestWindow *window = [RockProxyTestWindow new];
    RockMacMeetingWindowBridge *bridge = [[RockMacMeetingWindowBridge alloc] initWithWindow:nil action:^(NSString *action) {}];
    bridge.window = (id)window; bridge.proxy = proxy;
    window.delegate = proxy;
    [bridge invalidate];
    correct &= window.delegate == original;
    bridge.window = (id)window; bridge.proxy = proxy;
    id replacement = [NSObject new]; window.delegate = replacement;
    [bridge invalidate];
    correct &= window.delegate == replacement;
    RockProxyTestWindow *candidate = [RockProxyTestWindow new];
    candidate.isVisible = YES; candidate.styleMask = 1;
    correct &= RockUniqueMeetingWindow(@[]) == nil && RockUniqueMeetingWindow(@[candidate]) == candidate;
    window.isVisible = YES; window.styleMask = 1;
    correct &= RockUniqueMeetingWindow(@[candidate, window]) == nil;
    candidate.sheetParent = original;
    correct &= !RockEligibleMeetingWindow((id)candidate);
    candidate.sheetParent = nil; candidate.parentWindow = original;
    correct &= !RockEligibleMeetingWindow((id)candidate);
    candidate.parentWindow = nil; candidate.isVisible = NO;
    correct &= !RockEligibleMeetingWindow((id)candidate);
    candidate.isVisible = YES; candidate.styleMask = 0;
    correct &= !RockEligibleMeetingWindow((id)candidate);
    candidate.styleMask = 1; candidate.level = 3;
    correct &= !RockEligibleMeetingWindow((id)candidate);
    proxy.original = nil;
    return correct && [proxy windowShouldClose:[NSObject new]];
}
#endif
