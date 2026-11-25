#import <UIKit/UIKit.h>
#import "YZBrowserController.h"
#import "YZCrash.h"
#import "YZLog.h"
#import <QuartzCore/QuartzCore.h>
#import "YZAppIcon.h"
#import "YZSplashController.h"
#import "YZSystemNotifier.h"
#import "YZSettings.h"
#import "YZStrings.h"
#import "YZTheme.h"
#include "yozora_core.h"
#include "webgl/yozora_gl.h"

// the core thread reports a download that ended or paused, the delegate hears of it on the main thread
static void YZDownloadObserver(unsigned identifier, int state, void *context);

@interface YZAppDelegate : UIResponder <UIApplicationDelegate> {
    UIWindow *_window;
    YZBrowserController *_browser;
    YZSplashController *_splash;
    // a link that came before the browser existed
    NSURL *_pendingURL;
    // a hidden app is given a few minutes to finish what it started: downloads go on under this task and are paused before it ends
    UIBackgroundTaskIdentifier _backgroundTask;
    // the downloads that were paused because the time ran out, resumed when the app comes back
    NSMutableSet *_pausedForBackground;
}
- (void)downloadEnded:(unsigned)identifier state:(int)state;
@property(nonatomic, retain) UIWindow *window;
@end

@implementation YZAppDelegate
@synthesize window = _window;
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)options;
    // uidevice reports nothing before this
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    NSLog(@"yozora: launch orientation device %d interface %d", (int)[[UIDevice currentDevice] orientation], (int)[application statusBarOrientation]);
    _backgroundTask = UIBackgroundTaskInvalid;
    _pausedForBackground = [[NSMutableSet alloc] init];
    yozora_downloads_set_observer(YZDownloadObserver, self);
    [application setStatusBarStyle:[YZTheme statusBarStyle]];
    self.window = [[[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    self.window.backgroundColor = [YZSplashController launchColor];
    // the browser takes a moment to make, so the splash is drawn first and the browser is made on the next turn of the run loop
    _splash = [[YZSplashController alloc] init];
    self.window.rootViewController = _splash;
    [self.window makeKeyAndVisible];
    // making the browser blocks this thread for a second and what the screen was not given by then is not
    // drawn before it ends, so the splash is laid out, started and sent first (the animation runs in the
    // render server and goes on) and the browser is made after
    [_splash.view layoutIfNeeded];
    [_splash play];
    [CATransaction flush];
    [self performSelector:@selector(startBrowser) withObject:nil afterDelay:0.05];
    // a new install brings the icon of the app, the choice of the person is put back
    YZAppIconRestore();
    return YES;
}

- (void)startBrowser {
    _browser = [[YZBrowserController alloc] init];
    // the view is loaded here, where the core and the tabs are made, so the splash is still on screen while it happens
    [_browser view];
    // the strip behind the status bar takes the toolbar color
    self.window.backgroundColor = [YZTheme toolbarColor];
    self.window.rootViewController = _browser;
    YZSplashController *splash = _splash;
    _splash = nil;
    [splash fadeOutOverWindow:self.window completion:^{ [splash release]; }];
    // the launch got past JavaScriptCore and the first page core
    [YZSettings endJitStart];
    [_browser offerJit];
    [_browser checkForUpdate];
    if (_pendingURL) {
        [_browser openExternalURL:_pendingURL];
        [_pendingURL release];
        _pendingURL = nil;
    }
}

// ios 4.2 to 8 call this one
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)source annotation:(id)annotation {
    (void)application; (void)source; (void)annotation;
    return [self openLink:url];
}
// ios 9 and later call this one instead of the one above
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url options:(NSDictionary *)options {
    (void)application; (void)options;
    return [self openLink:url];
}

// a link that starts the app waits for the browser, a later link replaces an earlier one still waiting
- (BOOL)openLink:(NSURL *)url {
    if (_browser)
        return [_browser openExternalURL:url];
    NSString *scheme = [[url scheme] lowercaseString];
    // a sign in request waits like a page does, the browser asks the person once it exists
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"yozora-auth"])
        return NO;
    [_pendingURL release];
    _pendingURL = [url retain];
    return YES;
}
- (void)applicationDidEnterBackground:(UIApplication *)application {
    (void)application;
    [YZCrash applicationDidEnterBackground];
    [_browser saveTabsAndWait];
    [self flushCachesInBackground:application];
    // pages do not run while the app is hidden, the thread resumes with the app. queued work, the flush above included, still runs,
    // except behind a page that waits at the gl gate below until the app is back
    yozora_set_background(1);
    [self keepDownloadsRunning];
    // last: the system takes the graphics chip back soon after this returns (on ios 9 with an a5 from 1.5 s for
    // home and from 0.35 s for a lock, the app then ends in gpusSubmitDataBuffers under a webgl call) and the
    // core thread can still be in a script that draws. from here its gl calls wait for the return
    if (!yozora_gl_set_allowed(0))
        NSLog(@"yozora: a gl call was still in the driver a second after the gl gate shut");
}
- (void)applicationWillEnterForeground:(UIApplication *)application {
    (void)application;
    // the graphics chip is the app's again before the core thread may run a page
    yozora_gl_set_allowed(1);
    [YZCrash applicationWillEnterForeground];
    [self endBackgroundTask];
    yozora_set_background(0);
    for (NSNumber *identifier in _pausedForBackground)
        yozora_download_resume([identifier unsignedIntValue]);
    [_pausedForBackground removeAllObjects];
}

// responses queued for the disk are lost when the system ends a background process. the flushes wait for the
// core thread, which may sit in a script, and waited for on the main thread they passed the ios 5 and 6 limit
// for applicationDidEnterBackground and the app was killed with 0x8badf00d. they run on a queue under a
// background task that ends with the last flush or when the system takes the time back
- (void)flushCachesInBackground:(UIApplication *)application {
    static dispatch_queue_t queue;
    if (!queue)
        queue = dispatch_queue_create("com.sqmrak.yozora.flush", DISPATCH_QUEUE_SERIAL);
    __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
    void (^finish)(void) = ^{
        if (task == UIBackgroundTaskInvalid)
            return;
        UIBackgroundTaskIdentifier ended = task;
        task = UIBackgroundTaskInvalid;
        [[UIApplication sharedApplication] endBackgroundTask:ended];
    };
    // the handler and the end of the flush both run on the main queue, so the task is ended once
    task = [application beginBackgroundTaskWithExpirationHandler:finish];
    dispatch_async(queue, ^{
        yozora_flush_http_cache();
        yozora_flush_bytecode_cache();
        yozora_flush_site_data();
        // the hit rate of the bytecode cache is what says whether a bigger cache or a lower size floor would pay, it is read here once per leave
        unsigned long long loaded = 0, stale = 0, stored = 0, bytes = 0;
        yozora_bytecode_cache_statistics(&loaded, &stale, &stored, &bytes);
        NSLog(@"yozora: bytecode cache, %llu scripts loaded from it, %llu replaced as stale, %llu stored, %llu bytes written", loaded, stale, stored, bytes);
        dispatch_async(dispatch_get_main_queue(), finish);
    });
}

#pragma mark downloads in the background

// downloads that wait or run, which a hidden app is worth keeping awake for. a paused one waits for the person
- (NSUInteger)activeDownloadIDs:(NSMutableArray *)identifiers {
    yozora_download list[50];
    int count = yozora_downloads_list(list, 50);
    NSUInteger active = 0;
    for (int i = 0; i < count; ++i) {
        if (list[i].state == YOZORA_DOWNLOAD_QUEUED || list[i].state == YOZORA_DOWNLOAD_RUNNING) {
            ++active;
            [identifiers addObject:[NSNumber numberWithUnsignedInt:list[i].id]];
        }
    }
    return active;
}

- (void)endBackgroundTask {
    if (_backgroundTask == UIBackgroundTaskInvalid)
        return;
    UIBackgroundTaskIdentifier task = _backgroundTask;
    _backgroundTask = UIBackgroundTaskInvalid;
    [[UIApplication sharedApplication] endBackgroundTask:task];
}

// a hidden app runs a few minutes (ten on ios 5 and 6, three later) and is then ended. the core thread keeps
// serving transfers until the last ends or the time is nearly out
- (void)keepDownloadsRunning {
    if (![self activeDownloadIDs:[NSMutableArray array]])
        return;
    if (_backgroundTask == UIBackgroundTaskInvalid) {
        _backgroundTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{ [self backgroundTimeEnded]; }];
    }
    // a refused task leaves the thread still, as before
    if (_backgroundTask == UIBackgroundTaskInvalid)
        return;
    yozora_set_background_downloads(1);
    [YZSystemNotifier askPermission];
    [self announceRunningDownloads];
}

// the notification that says a file is coming while the app is hidden: the name of the file, or how many files there are
- (void)announceRunningDownloads {
    yozora_download list[50];
    int count = yozora_downloads_list(list, 50);
    NSUInteger running = 0;
    const char *first = NULL;
    for (int i = 0; i < count; ++i) {
        if (list[i].state != YOZORA_DOWNLOAD_QUEUED && list[i].state != YOZORA_DOWNLOAD_RUNNING)
            continue;
        if (!first)
            first = list[i].name;
        ++running;
    }
    if (!running)
        return;
    NSString *name = [NSString stringWithUTF8String:first];
    [YZSystemNotifier post:running == 1 ? [NSString stringWithFormat:@"%@: %@", YZT(@"Загрузка идёт"), name ? name : @""]
                                        : [NSString stringWithFormat:@"%@: %lu", YZT(@"Загружается файлов"), (unsigned long)running]];
}

// the time ran out: what is still running is paused, with its part file kept, and goes on when the app is shown again
- (void)backgroundTimeEnded {
    NSMutableArray *running = [NSMutableArray array];
    [self activeDownloadIDs:running];
    for (NSNumber *identifier in running) {
        yozora_download_pause([identifier unsignedIntValue]);
        [_pausedForBackground addObject:identifier];
    }
    yozora_set_background_downloads(0);
    if ([running count])
        [YZSystemNotifier post:YZT(@"Загрузки приостановлены, откройте Yozora, чтобы продолжить")];
    [self endBackgroundTask];
}

- (void)downloadEnded:(unsigned)identifier state:(int)state {
    UIApplication *application = [UIApplication sharedApplication];
    // a file that ended while the page is on the screen is told by the page, in every other state by the system
    if (application.applicationState == UIApplicationStateActive)
        return;
    if (state == YOZORA_DOWNLOAD_DONE || state == YOZORA_DOWNLOAD_FAILED) {
        yozora_download list[50];
        int count = yozora_downloads_list(list, 50);
        for (int i = 0; i < count; ++i) {
            if (list[i].id != identifier)
                continue;
            [YZSystemNotifier post:[NSString stringWithFormat:@"%@: %s", state == YOZORA_DOWNLOAD_DONE ? YZT(@"Загружено") : YZT(@"Не загружено"), list[i].name]];
            break;
        }
    }
    // the number on the icon and the spinner follow what is left, the page that sets them while it is shown is not polling now
    NSUInteger left = [self activeDownloadIDs:[NSMutableArray array]];
    [YZSystemNotifier setBadge:(NSInteger)left];
    [YZSystemNotifier setActivity:left > 0];
    // the last transfer is over: the thread holds still again and the system may suspend the app
    if (!left) {
        yozora_set_background_downloads(0);
        [self endBackgroundTask];
    }
}

- (void)applicationWillTerminate:(UIApplication *)application {
    (void)application;
    [YZCrash applicationWillTerminate];
    [_browser saveTabsAndWait];
    yozora_flush_http_cache();
    yozora_flush_bytecode_cache();
    yozora_flush_site_data();
}
- (void)dealloc {
    [_pausedForBackground release];
    [_pendingURL release];
    [_splash release];
    [_browser release];
    [_window release];
    [super dealloc];
}
@end

static void YZDownloadObserver(unsigned identifier, int state, void *context) {
    YZAppDelegate *delegate = (YZAppDelegate *)context;
    dispatch_async(dispatch_get_main_queue(), ^{ [delegate downloadEnded:identifier state:state]; });
}

int main(int argc, char **argv) {
    // NSLog of an app started from the home screen goes to the system log only, which a phone without syslogd keeps
    // nowhere. with this CoreFoundation also writes to stderr, which the log capture reads: the zombie's line with
    // the class and the selector (and every NSLog of the app) then reaches the log file
    setenv("CFLOG_FORCE_STDERR", "1", 1);
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    // before JavaScriptCore: its start maps the jit region and a signal there happened ahead of the recorder
    // that used to be installed in didFinishLaunching, so a launch crash on a new ios left no file at all
    [YZCrash install];
    // zombies first, before any object of the app can be freed: the names of the freed objects need the log, so
    // the capture goes on with them
    if ([YZSettings zombies]) {
        [YZSettings setLogging:YES];
        [YZCrash enableZombies];
    }
    // started here so a launch that dies in the engine start still has a log
    [YZLog setCapturing:[YZSettings logging]];
    // the jit is chosen while JavaScriptCore starts, so the setting is read here and a change in the settings counts at the next launch
    yozora_set_jit_requested([YZSettings beginJitStart] ? 1 : 0);
    [YZCrash note:@"launch: javascriptcore start"];
    yozora_initialize_javascript();
    [YZCrash note:@"launch: javascriptcore ready"];
    // what the engine runs, so a crash record that ends in generated code says which tiers could have made it
    yozora_jit_info jit;
    yozora_jit_info_read(&jit);
    [YZCrash note:[NSString stringWithFormat:@"jit: %s baseline %d dfg %d regexp %d concurrent %d pool %llu of %llu",
                   jit.compiled ? "built" : "not built", jit.active, jit.dfg, jit.regexp, jit.concurrent, jit.pool_used, jit.pool_size]];
    int result = UIApplicationMain(argc, argv, nil, NSStringFromClass([YZAppDelegate class]));
    [pool drain];
    return result;
}
