#import <AppKit/AppKit.h>
@interface ResizeWindow : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@property NSTextField *label;
@property NSTimer *timer;
@property NSDate *started;
@property NSInteger phase;
@end
@implementation ResizeWindow
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
 self.phase=-1;
 self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(100,180,900,600) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
 self.window.title=@"Rock Presenter resize test — synthetic window only";
 self.window.contentView.wantsLayer=YES;
 self.label=[NSTextField labelWithString:@"PRESENTER RESIZE TEST\nSynthetic content only"];
 self.label.font=[NSFont boldSystemFontOfSize:28];self.label.textColor=NSColor.whiteColor;
 [self.window.contentView addSubview:self.label];[self.window makeKeyAndOrderFront:nil];
 self.timer=[NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer){
  self.window.contentView.layer.backgroundColor=[NSColor colorWithHue:fmod(NSDate.timeIntervalSinceReferenceDate/10,1) saturation:0.85 brightness:0.6 alpha:1].CGColor;
  if(!self.started)self.started=NSDate.date;
  NSInteger phase=(NSInteger)(-[self.started timeIntervalSinceNow]/5)%4;
  if(phase!=self.phase){self.phase=phase;NSSize sizes[]={NSMakeSize(900,600),NSMakeSize(600,850),NSMakeSize(1200,450),NSMakeSize(550,350)};[self.window setContentSize:sizes[phase]];}
  self.label.frame=NSMakeRect(24,MAX(0,self.window.contentView.bounds.size.height-130),MAX(1,self.window.contentView.bounds.size.width-48),110);
  self.label.stringValue=[NSString stringWithFormat:@"PRESENTER RESIZE TEST\nPhase %ld · %.0f × %.0f\nSynthetic content only",(long)phase,self.window.contentView.bounds.size.width,self.window.contentView.bounds.size.height];
 }];
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,240*NSEC_PER_SEC),dispatch_get_main_queue(),^{[NSApp terminate:nil];});
}
@end
int main(){@autoreleasepool{NSApplication *app=NSApplication.sharedApplication;[app setActivationPolicy:NSApplicationActivationPolicyRegular];ResizeWindow *delegate=[ResizeWindow new];app.delegate=delegate;[app run];}return 0;}
