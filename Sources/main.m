#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <unistd.h>

static NSString * const kAppName = @"MiScrcpy Mac";
static NSString * const kScrcpyTitlePrefix = @"MiScrcpy · ";
static NSString * const kDefaultWiFi = @"192.168.1.100:5555";
static NSString * const kDeviceMi3 = @"";

static NSString *findExecutable(NSArray<NSString *> *locations) {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *path in locations) if ([fm isExecutableFileAtPath:path]) return path;
    return nil;
}
static NSString *adbPath(void) {
    return findExecutable(@[@"/opt/homebrew/bin/adb", @"/usr/local/bin/adb"]);
}
static NSString *scrcpyPath(void) {
    return findExecutable(@[@"/opt/homebrew/bin/scrcpy", @"/usr/local/bin/scrcpy"]);
}
static NSString *runCapture(NSString *bin, NSArray<NSString *> *args, NSData **bytes, int *exitCode) {
    if (!bin) { if (exitCode) *exitCode = 127; return @"无法找到命令"; }
    NSTask *p = NSTask.new;
    p.executableURL = [NSURL fileURLWithPath:bin];
    p.arguments = args;
    p.environment = @{@"PATH": @"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"};
    NSPipe *out = NSPipe.pipe;
    p.standardOutput = out;
    p.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *err = nil;
    if (![p launchAndReturnError:&err]) { if(exitCode) *exitCode = 126; return err.localizedDescription; }
    NSData *data = [out.fileHandleForReading readDataToEndOfFile];
    [p waitUntilExit];
    if (exitCode) *exitCode = p.terminationStatus;
    if (bytes) *bytes = data;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}
static NSTextField *label(NSString *title, CGFloat size, BOOL bold) {
    NSTextField *v = [NSTextField labelWithString:title];
    v.font = bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];
    v.textColor = bold ? NSColor.labelColor : NSColor.secondaryLabelColor;
    v.lineBreakMode = NSLineBreakByTruncatingTail;
    return v;
}
static NSButton *button(NSString *title, SEL action, id target, NSRect frame) {
    NSButton *b = [[NSButton alloc] initWithFrame:frame];
    b.title = title;
    b.target = target;
    b.action = action;
    b.bezelStyle = NSBezelStyleRounded;
    b.font = [NSFont systemFontOfSize:13];
    return b;
}

@interface AppController : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property NSWindow *mainWindow;
@property NSPanel *toolbar;
@property NSVisualEffectView *toolbarBackground;
@property NSMutableArray<NSButton *> *toolbarActions;
@property NSPopUpButton *deviceList;
@property NSTextField *wifiField;
@property NSTextField *statusLabel;
@property NSButton *screenOffCheck;
@property NSButton *connectButton;
@property NSButton *stopButton;
@property NSTask *scrcpyTask;
@property NSTimer *followTimer;
@property NSString *activeSerial;
@property BOOL expanded;
@property BOOL screenSleeping;
@property NSStatusItem *menuBarItem;
@end

@implementation AppController

- (void)status:(NSString *)message {
    self.statusLabel.stringValue = message ?: @"";
    NSLog(@"[MiScrcpy] %@", message);
}
- (void)buildWindow {
    self.mainWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,550,407)
       styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable)
       backing:NSBackingStoreBuffered defer:NO];
    self.mainWindow.title = @"MiScrcpy Mac · 设备管理";
    self.mainWindow.delegate = self;
    [self.mainWindow center];
    NSView *content = self.mainWindow.contentView;
    content.wantsLayer = YES;
    NSTextField *headline=label(@"MiScrcpy Mac",23,YES); headline.frame=NSMakeRect(22,351,500,32); [content addSubview:headline];
    NSTextField *subtitle=label(@"原生 scrcpy 5.0.1 投屏 · QtScrcpy 风格侧边控制栏",12,NO);
    subtitle.frame=NSMakeRect(23,330,510,20); [content addSubview:subtitle];

    NSTextField *deviceLabel=label(@"选择 Android 设备（USB / Wi-Fi）",13,YES);
    deviceLabel.frame=NSMakeRect(23,296,500,20); [content addSubview:deviceLabel];
    self.deviceList=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(22,260,407,30) pullsDown:NO];
    [content addSubview:self.deviceList];
    NSButton *refresh=button(@"刷新",@selector(refreshPressed:),self,NSMakeRect(434,260,93,30));
    [content addSubview:refresh];

    NSTextField *wifiLabel=label(@"Wi-Fi ADB 地址",13,YES);
    wifiLabel.frame=NSMakeRect(23,228,300,20); [content addSubview:wifiLabel];
    self.wifiField=[[NSTextField alloc] initWithFrame:NSMakeRect(22,199,365,27)];
    self.wifiField.stringValue=[[NSUserDefaults standardUserDefaults] stringForKey:@"MiScrcpyWiFiEndpoint"] ?: @"";
    self.wifiField.placeholderString=@"192.168.1.100:5555";
    [content addSubview:self.wifiField];
    NSButton *wifiConnect=button(@"无线连接",@selector(connectWiFi:),self,NSMakeRect(393,198,134,30));
    [content addSubview:wifiConnect];

    self.screenOffCheck=[[NSButton alloc] initWithFrame:NSMakeRect(23,169,490,22)];
    self.screenOffCheck.buttonType=NSButtonTypeSwitch;
    self.screenOffCheck.title=@"启动投屏时关闭手机实体屏幕（远程画面继续显示）";
    self.screenOffCheck.font=[NSFont systemFontOfSize:12];
    self.screenOffCheck.state=NSControlStateValueOff;
    [content addSubview:self.screenOffCheck];

    self.connectButton=button(@"▶ 启动投屏 + 侧边工具栏",@selector(startPressed:),self,NSMakeRect(22,123,315,35));
    self.connectButton.keyEquivalent=@"\r";
    [content addSubview:self.connectButton];
    self.stopButton=button(@"■ 结束投屏",@selector(stopPressed:),self,NSMakeRect(348,123,179,35));
    self.stopButton.enabled=NO;
    [content addSubview:self.stopButton];

    NSTextField *foot=label(@"工具栏跟随投屏窗口，可点击 ≡ 折叠；仅控制当前选定设备。",12,NO);
    foot.frame=NSMakeRect(23,91,502,18); [content addSubview:foot];
    self.statusLabel=label(@"准备就绪",12,NO);
    self.statusLabel.frame=NSMakeRect(23,45,506,35);
    self.statusLabel.cell.wraps=YES;
    [content addSubview:self.statusLabel];
    NSTextField *runtime=label(@"后端: /opt/homebrew/bin/scrcpy   |   需要本机 Homebrew 环境",10,NO);
    runtime.frame=NSMakeRect(23,22,510,18);
    [content addSubview:runtime];
}

- (NSButton *)tool:(NSString *)symbol tooltip:(NSString *)tip key:(NSInteger)tag position:(NSInteger)n {
    NSButton *b=[[NSButton alloc] initWithFrame:NSMakeRect(7,7+n*40,44,34)];
    b.tag=tag;
    b.target=self;
    b.action=@selector(toolbarPressed:);
    b.bezelStyle=NSBezelStyleTexturedRounded;
    NSImage *image=[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip];
    if (image) { b.image=image; b.imagePosition=NSImageOnly; }
    else b.title=[tip substringToIndex:MIN((NSUInteger)2,tip.length)];
    b.toolTip=tip;
    [self.toolbarBackground addSubview:b];
    [self.toolbarActions addObject:b];
    return b;
}
- (void)buildToolbar {
    self.expanded=YES;
    self.toolbarActions=NSMutableArray.array;
    self.toolbar=[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,58,548)
             styleMask:(NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel)
             backing:NSBackingStoreBuffered defer:NO];
    self.toolbar.opaque=NO;
    self.toolbar.backgroundColor=NSColor.clearColor;
    self.toolbar.hasShadow=YES;
    self.toolbar.level=NSFloatingWindowLevel;
    self.toolbar.hidesOnDeactivate=NO;
    self.toolbar.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.toolbarBackground=[[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0,0,58,548)];
    self.toolbarBackground.material=NSVisualEffectMaterialHUDWindow;
    self.toolbarBackground.blendingMode=NSVisualEffectBlendingModeBehindWindow;
    self.toolbarBackground.state=NSVisualEffectStateActive;
    self.toolbarBackground.wantsLayer=YES;
    self.toolbarBackground.layer.cornerRadius=12;
    self.toolbarBackground.layer.masksToBounds=YES;
    self.toolbar.contentView=self.toolbarBackground;

    // 从顶向下排：折叠、熄/亮屏、截屏、音量、静音、导航、通知、电源和关闭。
    NSArray<NSArray *> *items=@[
        @[@"power", @"手机实体屏幕电源开关", @1],
        @[@"sun.max", @"唤醒手机屏幕", @2],
        @[@"camera", @"保存手机截图到图片目录", @3],
        @[@"speaker.wave.3", @"音量加", @4],
        @[@"speaker.wave.1", @"音量减", @5],
        @[@"speaker.slash", @"静音", @6],
        @[@"house", @"主页 Home", @7],
        @[@"arrow.uturn.backward", @"返回 Back", @8],
        @[@"square.on.square", @"最近任务", @9],
        @[@"bell", @"通知栏", @10],
        @[@"rectangle.expand.vertical", @"全屏操作提示", @11],
        @[@"xmark.circle", @"关闭投屏", @12]
    ];
    // 顶部折叠开关不随展开状态隐藏。
    NSButton *fold=[[NSButton alloc] initWithFrame:NSMakeRect(7,512,44,31)];
    fold.title=@"≡"; fold.bezelStyle=NSBezelStyleTexturedRounded;
    fold.toolTip=@"显示 / 隐藏侧边菜单"; fold.target=self; fold.action=@selector(toggleToolbar:);
    [self.toolbarBackground addSubview:fold];
    NSInteger idx=0;
    for(NSArray *it in items) {
        NSInteger y=475-idx*39;
        NSButton *b=[[NSButton alloc] initWithFrame:NSMakeRect(7,y,44,34)];
        NSString *symbol=it[0], *tip=it[1];
        b.tag=[it[2] integerValue]; b.target=self; b.action=@selector(toolbarPressed:);
        b.bezelStyle=NSBezelStyleTexturedRounded;
        NSImage *img=[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip];
        if (img) { b.image=img; b.imagePosition=NSImageOnly; } else {b.title=tip;}
        b.toolTip=tip;
        [self.toolbarBackground addSubview:b];
        [self.toolbarActions addObject:b]; idx++;
    }
    [self.toolbar orderOut:nil];
}
- (void)toggleToolbar:(id)sender {
    self.expanded=!self.expanded;
    for (NSButton *b in self.toolbarActions) b.hidden=!self.expanded;
    CGFloat newHeight=self.expanded?548:42;
    NSRect f=self.toolbar.frame;
    f.size.height=newHeight;
    self.toolbarBackground.frame=NSMakeRect(0,0,58,newHeight);
    for (NSButton *b in self.toolbarBackground.subviews) {
        if (![self.toolbarActions containsObject:b]) {
            b.frame=NSMakeRect(7,newHeight-36,44,31);
        }
    }
    [self.toolbar setFrame:f display:YES];
    [self alignToolbar];
}
- (void)refreshDevices {
    NSString *prior=[self.deviceList.selectedItem.representedObject isKindOfClass:NSString.class]
                        ? self.deviceList.selectedItem.representedObject : @"";
    int status=0;
    NSString *raw=runCapture(adbPath(),@[@"devices",@"-l"],NULL,&status);
    [self.deviceList removeAllItems];
    NSMutableArray<NSString *> *serials=NSMutableArray.array;
    for (NSString *line in [raw componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSArray *segments=[line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSMutableArray<NSString *> *parts=NSMutableArray.array;
        for (NSString *p in segments) if (p.length) [parts addObject:p];
        if(parts.count<2 || ![parts[1] isEqualToString:@"device"]) continue;
        NSString *serial=parts[0];
        NSString *model=@"Android";
        for (NSString *p in parts) if ([p hasPrefix:@"model:"]) { model=[p substringFromIndex:6]; break; }
        NSString *type=[serial containsString:@":"]?@"Wi-Fi":@"USB";
        NSString *title=[NSString stringWithFormat:@"%@ · %@ (%@)",model,type,serial];
        [self.deviceList addItemWithTitle:title];
        self.deviceList.lastItem.representedObject=serial;
        [serials addObject:serial];
    }
    if(!serials.count) {
        [self.deviceList addItemWithTitle:@"没有检测到已授权 Android 设备"];
        self.deviceList.lastItem.enabled=NO;
        self.connectButton.enabled=NO;
        [self status:@"请连接 USB 并允许调试，或先用无线连接。"];
    } else {
        self.connectButton.enabled=YES;
        NSString *desired=prior.length && [serials containsObject:prior]?prior:
            ([serials containsObject:kDeviceMi3]?kDeviceMi3:
             ([serials containsObject:kDefaultWiFi]?kDefaultWiFi:serials[0]));
        for (NSInteger i=0; i<self.deviceList.numberOfItems; i++) {
            if([self.deviceList.itemArray[i].representedObject isEqual:desired]) {
                [self.deviceList selectItemAtIndex:i]; break;
            }
        }
        if(!self.scrcpyTask.isRunning) [self status:[NSString stringWithFormat:@"检测到 %lu 个 ADB 连接，已选 %@",(unsigned long)serials.count,desired]];
    }
}
- (void)refreshPressed:(id)sender { [self refreshDevices]; }

- (void)connectWiFi:(id)sender {
    NSString *host=[self.wifiField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.:-"];
    if (host.length<5 || host.length>128 ||
        [host rangeOfCharacterFromSet:allowed.invertedSet].location!=NSNotFound) {
        [self status:@"Wi-Fi 地址不合法；示例：192.168.1.100:5555"]; return;
    }
    [self status:@"正在连接 Wi-Fi ADB..."];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        int code=0; NSString *output=runCapture(adbPath(),@[@"connect",host],NULL,&code);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshDevices];
            if (code==0 && [output containsString:@"connected"]) {
                [[NSUserDefaults standardUserDefaults] setObject:host forKey:@"MiScrcpyWiFiEndpoint"];
                for (NSMenuItem *item in self.deviceList.itemArray) {
                    if([item.representedObject isEqual:host]) [self.deviceList selectItem:item];
                }
            }
            [self status:[NSString stringWithFormat:@"无线连接：%@",output]];
        });
    });
}
- (void)startPressed:(id)sender {
    if (self.scrcpyTask.isRunning) {
        [self status:@"当前投屏正在运行；请先结束，避免同一设备重复启动。"];return;
    }
    NSString *serial=self.deviceList.selectedItem.representedObject;
    if(![serial isKindOfClass:NSString.class] || !serial.length) {
        [self status:@"请先选择已授权设备"];return;
    }
    NSString *bin=scrcpyPath();
    if(!bin || !adbPath()) {
        [self status:@"找不到 Homebrew scrcpy 或 adb；请先安装运行时。"];return;
    }
    int rc=0;
    NSString *state=[runCapture(adbPath(),@[@"-s",serial,@"get-state"],NULL,&rc)
                      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(rc!=0 || ![state isEqualToString:@"device"]) { [self status:@"设备未在线或未授权，请刷新设备列表。"];return; }
    NSMutableArray *args=[@[@"-s",serial,@"--no-audio",@"--max-size=800",@"--video-bit-rate=1M",
                             [@"--window-title=" stringByAppendingString:[kScrcpyTitlePrefix stringByAppendingString:serial]]] mutableCopy];
    if(self.screenOffCheck.state==NSControlStateValueOn) [args addObject:@"--turn-screen-off"];
    NSTask *t=NSTask.new; t.executableURL=[NSURL fileURLWithPath:bin]; t.arguments=args;
    t.environment=@{@"PATH":@"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", @"ADB":adbPath()};
    NSString *logs=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/MiScrcpyMac.log"];
    [NSFileManager.defaultManager createFileAtPath:logs contents:nil attributes:nil];
    NSFileHandle *fh=[NSFileHandle fileHandleForWritingAtPath:logs];
    [fh seekToEndOfFile]; t.standardOutput=fh; t.standardError=fh;
    NSError *err=nil; if(![t launchAndReturnError:&err]) {
        [self status:[NSString stringWithFormat:@"无法启动：%@",err.localizedDescription]]; return;
    }
    self.scrcpyTask=t; self.activeSerial=serial; self.screenSleeping=NO;
    self.connectButton.enabled=NO; self.stopButton.enabled=YES;
    self.expanded=YES;
    for(NSButton *b in self.toolbarActions) b.hidden=NO;
    [self.toolbar setContentSize:NSMakeSize(58,548)];
    [self.toolbar orderFrontRegardless];
    [self alignToolbar];
    [self status:[NSString stringWithFormat:@"投屏运行中：%@；侧边菜单可折叠",serial]];
    __weak typeof(self) weakSelf=self;
    t.terminationHandler=^(NSTask *ended) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.scrcpyTask==ended) {
                weakSelf.scrcpyTask=nil; weakSelf.activeSerial=nil;
                [weakSelf.toolbar orderOut:nil];
                weakSelf.connectButton.enabled=YES; weakSelf.stopButton.enabled=NO;
                [weakSelf status:[NSString stringWithFormat:@"投屏已结束（退出码 %d）",ended.terminationStatus]];
            }
        });
    };
}
- (void)stopPressed:(id)sender {
    NSTask *p=self.scrcpyTask;
    if(p.isRunning) { [p terminate]; [self status:@"正在结束当前投屏..."]; }
    else [self.toolbar orderOut:nil];
}
- (void)sendKey:(NSInteger)key description:(NSString *)desc {
    NSString *serial=[self.activeSerial copy];
    if(!self.scrcpyTask.isRunning || !serial.length) { [self status:@"请先启动投屏"];return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        int code=0;
        runCapture(adbPath(),@[@"-s",serial,@"shell",@"input",@"keyevent",[NSString stringWithFormat:@"%ld",(long)key]],NULL,&code);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self status:[NSString stringWithFormat:@"%@ %@：%@",serial,desc,code==0?@"成功":@"失败"]];
        });
    });
}
- (void)saveScreenshot {
    NSString *serial=[self.activeSerial copy];
    if(!serial.length || !self.scrcpyTask.isRunning) return;
    [self status:@"正在保存手机截图..."];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSData *data=nil;int code=0;
        runCapture(adbPath(),@[@"-s",serial,@"exec-out",@"screencap",@"-p"],&data,&code);
        NSString *safe=[[serial stringByReplacingOccurrencesOfString:@":" withString:@"_"]
                         stringByReplacingOccurrencesOfString:@"." withString:@"_"];
        NSString *dir=[NSHomeDirectory() stringByAppendingPathComponent:
                        [@"Pictures/MiScrcpyMac/" stringByAppendingString:safe]];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSDateFormatter *date=NSDateFormatter.new; date.dateFormat=@"yyyyMMdd-HHmmss";
        NSString *path=[dir stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"Screenshot-%@.png",[date stringFromDate:NSDate.date]]];
        BOOL ok=(code==0 && data.length>100 && [data writeToFile:path atomically:YES]);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self status:ok?[NSString stringWithFormat:@"截图已保存：%@",path]:@"截图失败，请确认手机权限"];
        });
    });
}
- (void)toolbarPressed:(NSButton *)sender {
    switch(sender.tag) {
        case 1: [self sendKey:26 description:@"屏幕电源"]; break;
        case 2: [self sendKey:224 description:@"唤醒屏幕"];break;
        case 3: [self saveScreenshot];break;
        case 4: [self sendKey:24 description:@"音量加"];break;
        case 5: [self sendKey:25 description:@"音量减"];break;
        case 6: [self sendKey:164 description:@"静音"];break;
        case 7: [self sendKey:3 description:@"Home"];break;
        case 8: [self sendKey:4 description:@"返回"];break;
        case 9: [self sendKey:187 description:@"最近任务"];break;
        case 10:[self sendKey:83 description:@"通知栏"];break;
        case 11:[self status:@"切换投屏窗口全屏：在投屏窗口按 Cmd+F（无需辅助功能权限）"];break;
        case 12:[self stopPressed:nil];break;
    }
}
- (void)alignToolbar {
    if(!self.toolbar.isVisible || !self.scrcpyTask.isRunning) return;
    CGFloat height=self.expanded?548:42;
    CGFloat x=NSMaxX(self.mainWindow.frame)+8;
    CGFloat y=NSMaxY(self.mainWindow.frame)-height;
    BOOL located=NO;
    CFArrayRef raw=CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID);
    if(raw) {
        for(NSDictionary *w in (__bridge NSArray *)raw) {
            NSNumber *owner=w[(id)kCGWindowOwnerPID];
            NSString *windowTitle=w[(id)kCGWindowName] ?: @"";
            NSString *expectedTitle=[kScrcpyTitlePrefix stringByAppendingString:self.activeSerial?:@""];
            if(owner.intValue!=self.scrcpyTask.processIdentifier &&
               ![windowTitle isEqualToString:expectedTitle]) continue;
            NSDictionary *rect=w[(id)kCGWindowBounds];
            if(!rect) continue;
            CGFloat wx=[rect[@"X"] doubleValue],wy=[rect[@"Y"] doubleValue];
            CGFloat ww=[rect[@"Width"] doubleValue],wh=[rect[@"Height"] doubleValue];
            if(ww<150 || wh<200) continue;
            CGFloat maxY=NSScreen.screens.firstObject.frame.size.height;
            x=wx+ww+7;
            y=maxY-wy-height;
            located=YES;break;
        }
        CFRelease(raw);
    }
    NSRect screen=NSScreen.mainScreen.frame;
    for(NSScreen *s in NSScreen.screens) {
        if (NSPointInRect(NSMakePoint(x-10,y+height/2),s.frame)) {screen=s.frame;break;}
    }
    if(x+60>NSMaxX(screen)-4) x=MAX(NSMinX(screen)+5,x-68);
    y=MAX(NSMinY(screen)+8,MIN(y,NSMaxY(screen)-height-8));
    if(!located) {x=MIN(NSMaxX(screen)-68,x); y=MAX(NSMinY(screen)+8,y);}
    [self.toolbar setFrameOrigin:NSMakePoint(x,y)];
}
- (void)showManager:(id)sender { [NSApp activateIgnoringOtherApps:YES]; [self.mainWindow makeKeyAndOrderFront:nil]; }
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [self buildWindow]; [self buildToolbar];
    [self refreshDevices]; [self.mainWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    self.followTimer=[NSTimer scheduledTimerWithTimeInterval:0.45 target:self selector:@selector(follow:) userInfo:nil repeats:YES];
    self.menuBarItem=[NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.menuBarItem.button.title=@"📱";
    self.menuBarItem.button.toolTip=@"MiScrcpy Mac";
    NSMenu *menu=NSMenu.new;
    NSMenuItem *show=[[NSMenuItem alloc] initWithTitle:@"打开设备管理" action:@selector(showManager:) keyEquivalent:@""];
    show.target=self;[menu addItem:show];
    NSMenuItem *quit=[[NSMenuItem alloc] initWithTitle:@"退出 MiScrcpy Mac" action:@selector(terminate:) keyEquivalent:@"q"];
    [menu addItem:quit];self.menuBarItem.menu=menu;
    // 集成自检：启动真实 GUI+scrcpy+侧栏，然后自行保存证据并安全退出。
    NSString *smokeMode=nil;
    for(NSString *arg in NSProcessInfo.processInfo.arguments) {
        if([arg isEqualToString:@"--smoke-usb"]) smokeMode=@"usb";
        else if([arg isEqualToString:@"--smoke-wifi"]) smokeMode=@"wifi";
    }
    if(smokeMode) {
        NSString *mode=[smokeMode copy];
        NSString *serial=@"";
        for (NSMenuItem *item in self.deviceList.itemArray) {
            NSString *candidate=item.representedObject;
            if (![candidate isKindOfClass:NSString.class] || !candidate.length) continue;
            if ([candidate containsString:@":"]==[mode isEqualToString:@"wifi"]) {
                serial=candidate; break;
            }
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.1*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            for(NSMenuItem *it in self.deviceList.itemArray)
                if([it.representedObject isEqual:serial]) { [self.deviceList selectItem:it];break; }
            [self startPressed:nil];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            if(self.scrcpyTask.isRunning) [self saveScreenshot];
            [self toggleToolbar:nil];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            CGFloat collapsed=self.toolbar.frame.size.height;
            [self toggleToolbar:nil];
            BOOL running=self.scrcpyTask.isRunning;
            NSDictionary *evidence=@{
                @"mode":mode, @"device":self.activeSerial?:@"none",
                @"running":@(running), @"toolbarVisible":@(self.toolbar.isVisible),
                @"toolbarCollapsedHeight":@(collapsed),
                @"toolbarExpandedHeight":@(self.toolbar.frame.size.height),
                @"toolbarX":@(self.toolbar.frame.origin.x),
                @"toolbarY":@(self.toolbar.frame.origin.y),
                @"scrcpyPid":@(self.scrcpyTask.processIdentifier),
                @"status":self.statusLabel.stringValue?:@""
            };
            NSData *data=[NSJSONSerialization dataWithJSONObject:evidence options:NSJSONWritingPrettyPrinted error:NULL];
            NSString *dst=[@"/tmp/miscrcpy-smoke-" stringByAppendingFormat:@"%@.json",mode];
            [data writeToFile:dst atomically:YES];
            [self stopPressed:nil];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [NSApp terminate:nil];
            });
        });
    }
}
- (void)follow:(NSTimer *)timer { [self alignToolbar]; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return NO; }
- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.followTimer invalidate];
    if(self.scrcpyTask.isRunning) [self.scrcpyTask terminate];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if(argc>1 && strcmp(argv[1],"--self-test")==0) {
            int code=0;NSString *out=runCapture(adbPath(),@[@"devices",@"-l"],NULL,&code);
            printf("MiScrcpyMac self-test: adb=%s scrcpy=%s adb_status=%d\n%s\n",
                   adbPath().UTF8String?: "(missing)",scrcpyPath().UTF8String?: "(missing)",code,out.UTF8String?: "");
            return code;
        }
        NSApplication *app=NSApplication.sharedApplication;
        AppController *controller=AppController.new;
        app.delegate=controller;
        [app run];
    }
    return 0;
}
