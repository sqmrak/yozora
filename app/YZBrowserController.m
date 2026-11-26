#import <objc/message.h>
#import "YZBrowserController.h"
#import "YZCertificates.h"
#import "YZHomeElementsEditor.h"
#import "YZClassic.h"
#import "YZSystemNotifier.h"
#import "YZControls.h"
#import "YZLog.h"
#import "YZCrash.h"
#import "YZUpdateUI.h"
#import "YZMediaPlayer.h"
#import "YZMotion.h"
#import "YZPasswords.h"
#import "YZCompat.h"
#import "YZSettings.h"
#import "YZSettingsController.h"
#import "YZStrings.h"
#import "YZTab.h"
#import "YZTheme.h"
#include "yozora_color.h"
#include "yozora_address.h"
#include "yozora_home.h"
#include "yozora_password.h"

static NSString *const YZTabsDefaultsKey = @"YZTabs";
static NSString *const YZCurrentTabDefaultsKey = @"YZCurrentTab";
static const NSUInteger YZTabLimit = 24;
static const NSInteger YZBottomSkirtTag = 7701;

// the display link runs at the rate of the screen divided by divisor: 60 and 30 on an ordinary phone, 120 and 60 on a phone with ProMotion, which
// only gives a third-party app its 120 Hz when the link asks for it (preferredFramesPerSecond, ios 10) and Info.plist allows it
// (CADisableMinimumFrameDurationOnPhone). before ios 10 the divisor is the old frameInterval
static void YZSetLinkDivisor(CADisplayLink *link, NSInteger divisor) {
    SEL preferred = NSSelectorFromString(@"setPreferredFramesPerSecond:");
    if (![link respondsToSelector:preferred]) {
        link.frameInterval = divisor;
        return;
    }
    NSInteger maximum = 60;
    UIScreen *screen = [UIScreen mainScreen];
    if ([screen respondsToSelector:NSSelectorFromString(@"maximumFramesPerSecond")])
        maximum = MAX((NSInteger)30, [[screen valueForKey:@"maximumFramesPerSecond"] integerValue]);
    ((void (*)(id, SEL, NSInteger))(void *)objc_msgSend)(link, preferred, MAX((NSInteger)1, maximum / divisor));
}
static const NSUInteger YZSuggestionLimit = 6;
// the tray shows a page as wide as the screen in the stack of the flat design: the preview is as wide as the screen in pixels (at most 800),
// 280 was enough for the cards of the grid and was stretched to twice its size here
static CGFloat YZThumbnailPixels(void) {
    UIScreen *screen = [UIScreen mainScreen];
    return MIN((CGFloat)800, round(screen.bounds.size.width * screen.scale));
}

// the display link retains its target, this one holds the controller without retaining it
@interface YZCoreLinkTarget : NSObject {
@public
    YZBrowserController *controller;
}
- (void)fire:(CADisplayLink *)link;
@end
@implementation YZCoreLinkTarget
- (void)fire:(CADisplayLink *)link {
    [controller noteDisplayFrame];
    [controller pumpCore:link];
}
@end

// the status calls run every display frame, a new string is made only when the text changed
static NSString *YZStringReusing(const char *text, NSString *previous) {
    if (!text)
        text = "";
    if (previous && strcmp(text, [previous UTF8String]) == 0)
        return previous;
    NSString *string = [NSString stringWithUTF8String:text];
    return string ? string : @"";
}

static BOOL YZSameString(NSString *a, NSString *b) {
    return a == b || (a && b && [a isEqualToString:b]);
}

// the view of a page as the tiles hold it at the scroll position, scaled down
static UIImage *YZThumbnailFromView(UIView *view) {
    CGSize size = view.bounds.size;
    if (size.width < 1 || size.height < 1)
        return nil;
    // the page is drawn at the density of the screen, at 1 its text came out at half the pixels the preview needs
    CGFloat captureScale = MIN([[UIScreen mainScreen] scale], (CGFloat)2048 / MAX(size.width, size.height));
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size.width * captureScale, size.height * captureScale), YES, 1);
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!context) {
        UIGraphicsEndImageContext();
        return nil;
    }
    CGContextScaleCTM(context, captureScale, captureScale);
    [view.layer renderInContext:context];
    UIImage *capture = [UIGraphicsGetImageFromCurrentImageContext() retain];
    UIGraphicsEndImageContext();
    if (!capture)
        return nil;
    CGFloat scale = MIN(captureScale, YZThumbnailPixels() / size.width);
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size.width * scale, size.height * scale), YES, 1);
    context = UIGraphicsGetCurrentContext();
    if (!context) {
        UIGraphicsEndImageContext();
        [capture release];
        return nil;
    }
    // shrinking after the tile layers are flattened avoids seams between scaled tiles
    [capture drawInRect:CGRectMake(0, 0, size.width * scale, size.height * scale)];
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    [capture release];
    UIGraphicsEndImageContext();
    return result;
}

// iOS 11 and later, absent from the iOS 5 headers
@interface UIViewController (YZSafeArea)
- (void)viewSafeAreaInsetsDidChange;
@end

// a plain navigation controller opened the panels in portrait on ios 10
@interface YZPanelNavigationController : UINavigationController
@end

@implementation YZPanelNavigationController
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return YZPresentedOrientation();
}

// a navigation controller takes the status bar style from its own bar, not from the screen it shows: the default bar gave dark
// text over the dark themes from ios 7 on
- (UIStatusBarStyle)preferredStatusBarStyle {
    return [YZTheme statusBarStyle];
}

// before ios 6 the default is portrait only and the panel screens never answer, so they opened sideways
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    (void)orientation;
    return YES;
}
@end

@interface YZBrowserController ()
- (YZTab *)currentTab;
- (void)layoutChrome;
- (void)installEdgeSwipes;
- (void)trackEdgeColorAtTime:(CFTimeInterval)now;
- (void)setEdgeColor:(UIColor *)top bottom:(UIColor *)bottom;
- (void)cancelEdgeSwipe;
- (void)updateChromeForced:(BOOL)forced;
- (void)updateAddressDisplay;
- (BOOL)createCore;
- (void)destroyCore;
- (void)parkCoreKeepingTab:(YZTab *)kept;
- (void)loadURL:(NSString *)url;
- (void)openAddressText:(NSString *)text;
- (void)showBanner:(NSString *)text;
- (void)watchExternalLinks;
- (void)showError:(NSString *)text;
- (void)showHome;
- (void)setBottomBarShown:(BOOL)shown animated:(BOOL)animated;
- (void)givePageRoomBack;
- (void)moveTopBarAway:(BOOL)away animated:(BOOL)animated;
- (YZTranslation *)currentTranslation;
- (void)updateTranslationAnimated:(BOOL)animated;
- (void)presentTranslateSheet;
- (void)setTranslateBarShown:(BOOL)shown animated:(BOOL)animated;
- (void)switchToTab:(NSUInteger)index;
- (void)addBlankTab;
- (void)closeTabAtIndex:(NSUInteger)index;
- (BOOL)beginSignInFromURL:(NSURL *)link;
- (void)startSignIn:(YZSignIn *)request;
- (void)closeSignInTab;
- (void)sendSignIn:(YZSignIn *)signIn outcome:(yozora_signin_outcome)outcome address:(NSString *)address cookies:(NSString *)cookies;
- (void)finishSignIn:(YZSignIn *)signIn address:(NSString *)address cookies:(NSString *)cookies tooLarge:(BOOL)tooLarge;
- (void)answerSignIn:(YZSignIn *)signIn outcome:(yozora_signin_outcome)outcome;
- (void)leavePrivateAfterSignIn;
- (void)checkSignInAtTime:(CFTimeInterval)now;
- (void)setIncognito:(BOOL)incognito;
- (void)wobbleChrome;
- (void)styleBarButton:(UIButton *)button icon:(YZIcon)icon;
- (void)styleField;
- (void)presentPanel:(YZPanelNavigationController *)navigation;
- (void)styleCancelButton;
- (void)restoreTabs;
- (void)openSiteData;
- (void)openHTTPCache;
- (void)openBytecodeCache;
- (void)setEditing:(BOOL)editing;
- (void)refreshSuggestions;
- (NSString *)currentURL;
- (void)closePopup;
- (void)handleMedia:(const yozora_media_request *)request;
- (void)dismissVideoAnimated:(BOOL)animated;
- (void)presentVideoOfPlayer:(YZMediaPlayer *)player;
@end

@implementation YZBrowserController

#pragma mark setup

// a button of the bottom bar: the glyph in the text color, a pill of the accent under it while pressed, a bounce of the whole button
- (UIButton *)barButtonWithIcon:(YZIcon)icon action:(SEL)action label:(NSString *)label {
    YZStateButton *button = [YZStateButton buttonWithType:UIButtonTypeCustom];
    button.pillSize = CGSizeMake(56, 32);
    [self styleBarButton:button icon:icon];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    YZMotionAttachBounce(button, 0.06f);
    button.accessibilityLabel = label;
    button.tag = icon;
    return button;
}

// the address field is a flat pill in the modern design and the rounded field of the system in the classic one
- (void)styleField {
    [(YZWellView *)_field applyTheme];
    // the floating pill lifts off the page ground with a soft shadow, the other fields lie flat
    BOOL floating = [YZTheme isFloatingBar];
    _field.layer.shadowColor = [[UIColor blackColor] CGColor];
    _field.layer.shadowOpacity = floating ? ([YZTheme isDark] ? 0.5f : 0.14f) : 0;
    _field.layer.shadowRadius = 9;
    _field.layer.shadowOffset = CGSizeMake(0, 3);
}

- (void)styleCancelButton {
    [_cancelButton setTitleColor:[YZTheme isClassic] ? [YZTheme barInkColor] : [YZTheme accentColor] forState:UIControlStateNormal];
    if ([YZTheme isClassic]) {
        // the title of a bar button of ios 5 and 6 carries the dark stamp under its letters
        _cancelButton.titleLabel.shadowColor = [YZClassic stampColor];
        _cancelButton.titleLabel.shadowOffset = CGSizeMake(0, -1);
    } else {
        _cancelButton.titleLabel.shadowColor = nil;
    }
}

// the keys of the bars in the order they stand. the flat design and the floating bar have the share key where the others have the star (the star
// lives in the menu there), the tabs and the menu close the row in every design but the floating one, which puts the menu before the tabs
- (NSArray *)barButtons {
    // the bar at the top has two keys, as Firefox has: back, forward and share are in its menu
    if ([self layoutAtTop])
        return [NSArray arrayWithObjects:_tabsButton, _menuButton, nil];
    if ([YZTheme isFloatingBar])
        return [NSArray arrayWithObjects:_backButton, _forwardButton, _shareButton, _menuButton, _tabsButton, nil];
    if ([YZTheme isFlat])
        return [NSArray arrayWithObjects:_backButton, _forwardButton, _shareButton, _tabsButton, _menuButton, nil];
    return [NSArray arrayWithObjects:_backButton, _forwardButton, _starButton, _tabsButton, _menuButton, nil];
}

- (void)styleBarButton:(UIButton *)button icon:(YZIcon)icon {
    [button setImage:[YZTheme barIcon:icon size:24 disabled:NO] forState:UIControlStateNormal];
    [button setImage:[YZTheme barIcon:icon size:24 disabled:YES] forState:UIControlStateDisabled];
}

- (void)loadView {
    UIView *root = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]];
    root.backgroundColor = [YZTheme surfaceColor];
    self.view = root;
    [root release];

    _pageView = [[YZPageView alloc] initWithFrame:CGRectZero];
    _pageView.delegate = self;
    [self.view addSubview:_pageView];
    [self installEdgeSwipes];

    _home = [[YZHomeView alloc] initWithFrame:CGRectZero];
    _home.homeDelegate = self;
    [self.view addSubview:_home];
    // the ground of the start page takes the whole screen, under the page and the bars, and the strips of a blank tab show it
    [self.view insertSubview:_home.groundView belowSubview:_home];

    _errorPage = [[YZErrorPage alloc] initWithTarget:self action:@selector(retryPagePressed)];
    _errorPage.hidden = YES;
    [self.view addSubview:_errorPage];

    _banner = [[UILabel alloc] initWithFrame:CGRectZero];
    _banner.backgroundColor = [YZTheme cardColor];
    _banner.textColor = [YZTheme textColor];
    // the fonts of the views that live on follow the text size of the settings
    _banner.font = [YZTheme systemFontOfSize:14];
    _input.font = [YZTheme systemFontOfSize:15];
    _cancelButton.titleLabel.font = [YZTheme boldSystemFontOfSize:15];
    _banner.layer.cornerRadius = 14;
    _banner.layer.masksToBounds = YES;
    _banner.font = [YZTheme systemFontOfSize:14];
    _banner.numberOfLines = 2;
    _banner.textAlignment = YZTextAlignmentCenter;
    _banner.hidden = YES;
    [self.view addSubview:_banner];

    _suggestionsTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _suggestionsTable.dataSource = self;
    _suggestionsTable.delegate = self;
    _suggestionsTable.hidden = YES;
    _suggestionsTable.backgroundColor = [YZTheme surfaceColor];
    _suggestionsTable.separatorStyle = UITableViewCellSeparatorStyleNone;
    _suggestionsTable.rowHeight = 62;
    [self.view addSubview:_suggestionsTable];
    _suggestions = [[NSMutableArray alloc] init];

    // the toolbar of the system in the classic design and the flat toolbar color in the modern one
    _topBar = [[YZSystemBarView alloc] initWithFrame:CGRectZero];
    [self.view addSubview:_topBar];
    // the status bar text is light on every theme, so the strip under it is always black
    UIView *statusStrip = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
    statusStrip.backgroundColor = [YZTheme statusStripColor];
    statusStrip.tag = 2;
    [_topBar addSubview:statusStrip];
    _tabStrip = [[YZTabStrip alloc] initWithFrame:CGRectZero];
    _tabStrip.delegate = self;
    _tabStrip.hidden = YES;
    [_topBar addSubview:_tabStrip];

    // the classic design lays a rounded text field of the system under the address
    _field = [[YZWellView alloc] initWithFrame:CGRectZero];
    _field.userInteractionEnabled = YES;
    _field.layer.cornerRadius = 20;
    [self styleField];
    [_topBar addSubview:_field];

    _securityView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _securityView.contentMode = UIViewContentModeCenter;
    [_field addSubview:_securityView];

    _input = [[UITextField alloc] initWithFrame:CGRectZero];
    _input.borderStyle = UITextBorderStyleNone;
    YZSetPlaceholder(_input, YZT(@"Поиск или адрес"), [YZTheme fieldHintColor]);
    // the url keyboard has no space key, the web search keyboard (10) has it but exists from ios 7
    _input.keyboardType = [UIViewController instancesRespondToSelector:NSSelectorFromString(@"topLayoutGuide")] ? (UIKeyboardType)10 : UIKeyboardTypeDefault;
    _input.returnKeyType = UIReturnKeyGo;
    _input.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _input.autocorrectionType = UITextAutocorrectionTypeNo;
    _input.clearButtonMode = UITextFieldViewModeWhileEditing;
    _input.font = [YZTheme systemFontOfSize:15];
    _input.textColor = [YZTheme fieldInkColor];
    _input.keyboardAppearance = [YZTheme isDark] ? UIKeyboardAppearanceAlert : UIKeyboardAppearanceDefault;
    _input.textAlignment = YZTextAlignmentCenter;
    _input.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    _input.delegate = self;
    _input.accessibilityLabel = YZT(@"Адрес страницы");
    [_input addTarget:self action:@selector(inputChanged) forControlEvents:UIControlEventEditingChanged];
    [_field addSubview:_input];

    _reloadButton = [[YZStateButton buttonWithType:UIButtonTypeCustom] retain];
    [(YZStateButton *)_reloadButton setPillSize:CGSizeMake(32, 32)];
    [_reloadButton addTarget:self action:@selector(reloadPressed) forControlEvents:UIControlEventTouchUpInside];
    YZMotionAttachBounce(_reloadButton, 0.1f);
    [_field addSubview:_reloadButton];
    _micButton = [[YZStateButton buttonWithType:UIButtonTypeCustom] retain];
    [(YZStateButton *)_micButton setPillSize:CGSizeMake(32, 32)];
    [_micButton addTarget:self action:@selector(micPressed) forControlEvents:UIControlEventTouchUpInside];
    _micButton.accessibilityLabel = YZT(@"Голосовой поиск");
    _micButton.hidden = YES;
    [self paintMic:NO];
    [_field addSubview:_micButton];

    // the translation of the page: a card at the bottom of the page, the menu starts it by hand
        _translateBar = [[YZTranslateBar alloc] initWithFrame:CGRectZero];
    _translateBar.delegate = self;
    // grows from its bottom edge so the card does not overshoot upward as a whole
    _translateBar.layer.anchorPoint = CGPointMake(0.5f, 1);
    _translateBar.hidden = YES;
    [self.view addSubview:_translateBar];
    _bottomBarShown = YES;
    _pageReservesBar = YES;
    _pageReservesTop = YES;

    _cancelButton = [[YZStateButton buttonWithType:UIButtonTypeCustom] retain];
    [(YZStateButton *)_cancelButton setPillInsets:UIEdgeInsetsMake(10, 6, 10, 6)];
    [_cancelButton setTitle:YZT(@"Отмена") forState:UIControlStateNormal];
    [self styleCancelButton];
    _cancelButton.titleLabel.font = [YZTheme boldSystemFontOfSize:15];
    [_cancelButton addTarget:self action:@selector(cancelPressed) forControlEvents:UIControlEventTouchUpInside];
    _cancelButton.hidden = YES;
    [_topBar addSubview:_cancelButton];

    _progress = [[UIView alloc] initWithFrame:CGRectZero];
    _progress.backgroundColor = [YZTheme barHighlightProgressColor];
    _progress.hidden = YES;
    [_topBar addSubview:_progress];

    _bottomBar = [[YZSystemBarView alloc] initWithFrame:CGRectZero];
    ((YZSystemBarView *)_bottomBar).hairlineAtTop = YES;
    // the wobble lifts the bar's lower edge above the screen for a moment, a skirt of its color hides the
    // page strip
    UIView *skirt = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
    skirt.tag = YZBottomSkirtTag;
    skirt.backgroundColor = [YZTheme toolbarColor];
    [_bottomBar addSubview:skirt];
    [self.view addSubview:_bottomBar];
    _backButton = [[self barButtonWithIcon:YZIconBack action:@selector(backPressed) label:YZT(@"Назад")] retain];
    _forwardButton = [[self barButtonWithIcon:YZIconForward action:@selector(forwardPressed) label:YZT(@"Вперёд")] retain];
    _starButton = [[self barButtonWithIcon:YZIconStar action:@selector(starPressed) label:YZT(@"Избранное")] retain];
    _shareButton = [[self barButtonWithIcon:YZIconShare action:@selector(sharePressed) label:YZT(@"Поделиться")] retain];
    _tabsButton = [[self barButtonWithIcon:YZIconTabs action:@selector(tabsPressed) label:YZT(@"Вкладки")] retain];
    _menuButton = [[self barButtonWithIcon:YZIconMenu action:@selector(menuPressed) label:YZT(@"Меню")] retain];
    for (UIButton *button in [NSArray arrayWithObjects:_backButton, _forwardButton, _starButton, _shareButton, _tabsButton, _menuButton, nil])
        [_bottomBar addSubview:button];

    _tabsView = [[YZTabsView alloc] initWithFrame:CGRectZero];
    _tabsView.delegate = self;
    _tabsView.hidden = YES;
    [self.view addSubview:_tabsView];

    NSString *failure = nil;
    _store = [[YZStore openDefaultStore:&failure] retain];
    _tabs = [[NSMutableArray alloc] init];
    if (_popupMode) {
        [_tabs addObject:[[[YZTab alloc] init] autorelease]];
        [_tabsButton removeTarget:self action:@selector(tabsPressed) forControlEvents:UIControlEventTouchUpInside];
        [_tabsButton addTarget:self action:@selector(closePopup) forControlEvents:UIControlEventTouchUpInside];
        [_tabsButton setImage:[YZTheme barIcon:YZIconClose size:24 disabled:NO] forState:UIControlStateNormal];
        _tabsButton.accessibilityLabel = YZT(@"Закрыть");
    } else {
        [self restoreTabs];
        [self openSiteData];
        [self openHTTPCache];
        [self openBytecodeCache];
    }
    if (![self createCore])
        return;
    if (!_store)
        [self showError:[NSString stringWithFormat:YZT(@"История недоступна: %@"), failure ? failure : YZT(@"профиль не открыт")]];
    else if ([YZStore usesDocumentsProfile] && ![[NSUserDefaults standardUserDefaults] boolForKey:@"YZDocumentsProfileNotice"]) {
        [self showError:YZT(@"Папка профиля недоступна. Создан отдельный профиль в Documents/Yozora; прежние данные не удалены.")];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"YZDocumentsProfileNotice"];
    }
    YZCoreLinkTarget *target = [[YZCoreLinkTarget alloc] init];
    target->controller = self;
    _linkTarget = target;
    _link = [[CADisplayLink displayLinkWithTarget:target selector:@selector(fire:)] retain];
    YZSetLinkDivisor(_link, 1);
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardChanged:)
                                                 name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardChanged:)
                                                 name:UIKeyboardWillHideNotification object:nil];
    [self showHome];
    [self applyDeveloperSettings];
}

#pragma mark tabs

// cookies and local storage are the user's logins, they live in the profile directory the store made, not in the caches
- (void)openSiteData {
    // the folder of the files that pages hand over is set with the other places, the core makes it when the first file comes
    yozora_downloads_set_directory([[YZDownloadsController directory] fileSystemRepresentation]);
    char error[256] = {0};
    NSString *directory = [YZStore profileDirectory];
    if (!yozora_set_site_data([directory fileSystemRepresentation], error, sizeof(error)))
        NSLog(@"yozora: cookies and local storage are kept in memory only: %s", error);
}

// stored pages live in the caches directory, which the system may empty and does not back up
- (void)openHTTPCache {
    NSArray *roots = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if (![roots count])
        return;
    NSString *directory = [[roots objectAtIndex:0] stringByAppendingPathComponent:@"Yozora"];
    NSDictionary *private_mode = [NSDictionary dictionaryWithObject:[NSNumber numberWithUnsignedLong:0700] forKey:NSFilePosixPermissions];
    NSFileManager *files = [NSFileManager defaultManager];
    NSError *failure = nil;
    if (![files createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:private_mode error:&failure]
        || ![files setAttributes:private_mode ofItemAtPath:directory error:&failure]) {
        NSLog(@"yozora: cache directory unavailable: %@", failure);
        return;
    }
    char error[256] = {0};
    if (!yozora_set_http_cache([directory fileSystemRepresentation], 64 * 1024 * 1024, error, sizeof(error)))
        NSLog(@"yozora: http cache disabled: %s", error);
}

// compiled scripts of the sites the user visits, in a directory of their own beside the stored pages
- (void)openBytecodeCache {
    NSArray *roots = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if (![roots count])
        return;
    NSString *directory = [[roots objectAtIndex:0] stringByAppendingPathComponent:@"YozoraBytecode"];
    NSDictionary *private_mode = [NSDictionary dictionaryWithObject:[NSNumber numberWithUnsignedLong:0700] forKey:NSFilePosixPermissions];
    NSFileManager *files = [NSFileManager defaultManager];
    NSError *failure = nil;
    if (![files createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:private_mode error:&failure]
        || ![files setAttributes:private_mode ofItemAtPath:directory error:&failure]) {
        NSLog(@"yozora: bytecode cache directory unavailable: %@", failure);
        return;
    }
    char error[256] = {0};
    if (!yozora_set_bytecode_cache([directory fileSystemRepresentation], 64 * 1024 * 1024, error, sizeof(error)))
        NSLog(@"yozora: bytecode cache disabled: %s", error);
}

- (YZTab *)currentTab {
    return [_tabs objectAtIndex:_current];
}

- (void)restoreTabs {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [YZSettings applyToCore];
    NSArray *saved = [defaults objectForKey:YZTabsDefaultsKey];
    if ([saved isKindOfClass:[NSArray class]]) {
        for (id item in saved) {
            if (![item isKindOfClass:[NSDictionary class]] || [_tabs count] >= YZTabLimit)
                continue;
            id url = [item objectForKey:@"url"], title = [item objectForKey:@"title"];
            YZTab *tab = [[[YZTab alloc] init] autorelease];
            id identifier = [item objectForKey:@"id"];
            if ([identifier isKindOfClass:[NSString class]])
                tab.identifier = identifier;
            tab.url = [url isKindOfClass:[NSString class]] ? url : @"";
            tab.title = [title isKindOfClass:[NSString class]] ? title : @"";
            // the preview of the last run is read when the tray asks for it
            [tab noteStoredThumbnail];
            [_tabs addObject:tab];
        }
    }
    NSMutableArray *kept = [NSMutableArray array];
    for (YZTab *tab in _tabs)
        [kept addObject:tab.identifier];
    [YZTab removeStoredThumbnailsExcept:kept];
    if (![_tabs count])
        [_tabs addObject:[[[YZTab alloc] init] autorelease]];
    NSInteger index = [defaults integerForKey:YZCurrentTabDefaultsKey];
    _current = (index >= 0 && (NSUInteger)index < [_tabs count]) ? (NSUInteger)index : 0;
}

- (void)writeTabsAndWait:(BOOL)wait {
    // private tabs are never written, the profile's list is the one that is not shown while the private session is
    NSMutableArray *profile = [YZSettings incognito] ? _otherTabs : _tabs;
    NSMutableArray *saved = [NSMutableArray array];
    for (YZTab *tab in profile)
        [saved addObject:[NSDictionary dictionaryWithObjectsAndKeys:tab.url ? tab.url : @"", @"url", tab.title ? tab.title : @"", @"title",
                          tab.identifier, @"id", nil]];
    NSInteger current = (NSInteger)([YZSettings incognito] ? _otherCurrent : _current);
    if (!_saveQueue)
        _saveQueue = dispatch_queue_create("yozora.tabs", DISPATCH_QUEUE_SERIAL);
    // the plist is rewritten on flash, which can take long enough to be seen as a stall of the page
    void (^write)(void) = ^{
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:saved forKey:YZTabsDefaultsKey];
        [defaults setInteger:current forKey:YZCurrentTabDefaultsKey];
        if (![defaults synchronize]) {
            NSLog(@"yozora: tab list was not written");
            [self retain];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showError:YZT(@"Вкладки не сохранены")];
                [self release];
            });
        }
    };
    if (wait)
        dispatch_sync(_saveQueue, write);
    else
        dispatch_async(_saveQueue, write);
}

- (void)saveTabs {
    if (_popupMode)
        return;
    [self writeTabsAndWait:NO];
}

- (void)saveTabsAndWait {
    if (_popupMode)
        return;
    // the preview of the open page is stored with the list, so the tray has it after the next start
    [self captureCurrentTab];
    [self writeTabsAndWait:YES];
    [_store flush];
}

- (void)captureCurrentTab {
    if (!_core)
        return;
    YZTab *tab = [self currentTab];
    if (_hasFrame && ![tab isBlank]) {
        UIImage *picture = YZThumbnailFromView(_pageView);
        if (picture)
            tab.thumbnail = picture;
    }
    tab.scrollY = yozora_core_scroll_y(_core);
}

- (BOOL)createCore {
    NSString *resources = [[NSBundle mainBundle] resourcePath];
    char error[256] = {0};
    YZTab *tab = [self currentTab];
    _core = [tab takeSuspendedCore];
    if (_core && !yozora_core_set_suspended(_core, 0)) {
        NSLog(@"yozora: suspended tab could not resume, reloading its address");
        yozora_core_destroy(_core);
        _core = NULL;
    }
    BOOL restored = _core != NULL;
    if (!_core) {
        if (_initialPopupCore) {
            _core = _initialPopupCore;
            _initialPopupCore = NULL;
        } else
            _core = yozora_core_create([[resources stringByAppendingPathComponent:@"fonts"] fileSystemRepresentation],
                                      [[YZCertificates rootsPath] fileSystemRepresentation],
                                      error, sizeof(error));
    }
    if (!_core) {
        NSLog(@"yozora: core initialization failed: %s", error);
        [self showError:YZTCore([NSString stringWithUTF8String:error])];
        return NO;
    }
    _pageView.core = _core;
    _hasFrame = NO;
    // the translation belongs to the core: a core that came back from the cache brings its own, a new one gets a new one
    YZTranslation *translation = tab.translation;
    if (!restored || !translation) {
        [translation invalidate];
        translation = [[[YZTranslation alloc] initWithCore:_core] autorelease];
        tab.translation = translation;
    }
    translation.delegate = self;
    [self layoutChrome];
    // a new core starts in the mobile mode, a tab that was asked for the desktop site asks again
    if (!restored)
        yozora_core_set_desktop(_core, tab.desktop ? 1 : 0);
    if (!restored && ![tab isBlank]) {
        _restoreScroll = tab.scrollY;
        [self loadURL:tab.url];
    }
    return YES;
}

- (void)destroyCore {
    if (!_core)
        return;
    // a question of the page that goes away has nobody to answer
    if (_authAlert) {
        [_authAlert dismissSilently];
        [_authAlert release];
        _authAlert = nil;
    }
    if (_geoAlert) {
        [_geoAlert dismissSilently];
        [_geoAlert release];
        _geoAlert = nil;
    }
    if (_notificationAlert) {
        [_notificationAlert dismissSilently];
        [_notificationAlert release];
        _notificationAlert = nil;
    }
    [_location detachCore:_core];
    [self dismissVideoAnimated:NO];
    [self closePageControls];
    [self closeFindBar];
    [_pageView stopFling];
    [self captureCurrentTab];
    for (YZMediaPlayer *player in [_mediaPlayers allValues])
        [player shutDown];
    [_mediaPlayers release];
    _mediaPlayers = nil;
    [_pageView clearFrame];
    _pageView.core = NULL;
    _pageEditing = NO;
    // the translation is told before the core goes
    [[self currentTab].translation invalidate];
    [self currentTab].translation.delegate = nil;
    [self currentTab].translation = nil;
    yozora_core_destroy(_core);
    _core = NULL;
    [self updateTranslationAnimated:NO];
    _hasFrame = NO;
    _restoreScroll = 0;
    _thumbnailDue = 0;
    _lastLoadState = 0;
}

- (void)parkCoreKeepingTab:(YZTab *)kept {
    [self closePageControls];
    [self closeFindBar];
    // media players belong to the controller, a cached page must not keep an orphaned native player
    if (!_core || _popupMode || _popupController || [_mediaPlayers count] || _authAlert
        || (_memoryWarningTime && CACurrentMediaTime() - _memoryWarningTime < 20)
        || !yozora_core_set_suspended(_core, 1)) {
        [self destroyCore];
        return;
    }
    for (YZTab *tab in _tabs) {
        if (tab != kept)
            [tab discardSuspendedCore];
    }
    [self captureCurrentTab];
    [_pageView stopFling];
    [_pageView clearSelection];
    [_pageView resignFirstResponder];
    [_pageView clearFrame];
    _pageView.core = NULL;
    _pageEditing = NO;
    [[self currentTab] keepSuspendedCore:_core];
    _core = NULL;
    _hasFrame = NO;
    _restoreScroll = 0;
    _thumbnailDue = 0;
    _lastLoadState = 0;
}

- (void)switchToTab:(NSUInteger)index {
    if (index >= [_tabs count] || index == _current)
        return;
    [self parkCoreKeepingTab:[_tabs objectAtIndex:index]];
    _current = index;
    [self createCore];
    [self saveTabs];
    [self updateChromeForced:YES];
    [self updateTranslationAnimated:NO];
    // the page of the chosen tab fades in over the tray that leaves
    _pageView.alpha = 0;
    [YZTheme animate:^{ _pageView.alpha = 1; } completion:nil];
}

- (void)addBlankTab {
    if ([_tabs count] >= YZTabLimit) {
        [self showError:YZT(@"Открыто слишком много вкладок")];
        return;
    }
    // a blank tab is already open, parking and rebuilding made the screen shake for nothing
    if (_current < [_tabs count] && [(YZTab *)[_tabs objectAtIndex:_current] isBlank] && !_editing) {
        [self dismissMenu];
        return;
    }
    [self parkCoreKeepingTab:nil];
    YZTab *blank = [[[YZTab alloc] init] autorelease];
    blank.isPrivate = [YZSettings incognito];
    [_tabs addObject:blank];
    _current = [_tabs count] - 1;
    [self createCore];
    [self saveTabs];
    [self updateChromeForced:YES];
}

- (void)closeTabAtIndex:(NSUInteger)index {
    if (index >= [_tabs count])
        return;
    // the person closed the tab of a sign in: the app that asked hears that it was cancelled
    YZSignIn *cancelled = nil;
    if (_signIn && [_tabs objectAtIndex:index] == _signInTab) {
        cancelled = [_signIn retain];
        _signInTab = nil;
        [_signIn release];
        _signIn = nil;
    }
    BOOL closingCurrent = index == _current;
    if (closingCurrent)
        [self destroyCore];
    [[_tabs objectAtIndex:index] removeStoredThumbnail];
    [_tabs removeObjectAtIndex:index];
    if (![_tabs count]) {
        YZTab *blank = [[[YZTab alloc] init] autorelease];
        blank.isPrivate = [YZSettings incognito];
        [_tabs addObject:blank];
    }
    if (index < _current)
        --_current;
    if (_current >= [_tabs count])
        _current = [_tabs count] - 1;
    if (closingCurrent)
        [self createCore];
    [self saveTabs];
    [self updateChromeForced:YES];
    [_tabsView showTabs:_tabs selected:_current];
    if ([YZSettings incognito])
        [self endPrivateSessionIfEmpty];
    if (cancelled) {
        [self leavePrivateAfterSignIn];
        [self answerSignIn:cancelled outcome:YOZORA_SIGNIN_CANCELLED];
        [cancelled release];
    }
}

#pragma mark private session

// park the shown page before the core learns the session and make the opened core after, so each page starts
// in its own session
- (void)setIncognito:(BOOL)incognito {
    if (incognito == [YZSettings incognito] || _popupMode)
        return;
    // a picture of the screen covers the swap and leaves through a circle from the tray switch, or the menu
    // button
    UIView *cover = YZMotionBeginReveal(self.view);
    CGPoint origin = !_tabsView.hidden ? [_tabsView modeSwitchCenterInView:self.view]
                                       : [self.view convertPoint:_menuButton.center fromView:_menuButton.superview];
    [self parkCoreKeepingTab:nil];
    NSMutableArray *shown = _tabs;
    NSUInteger shownCurrent = _current;
    if (!_otherTabs) {
        YZTab *blank = [[[YZTab alloc] init] autorelease];
        blank.isPrivate = incognito;
        _otherTabs = [[NSMutableArray alloc] initWithObjects:blank, nil];
        _otherCurrent = 0;
    }
    _tabs = _otherTabs;
    _current = _otherCurrent;
    _otherTabs = shown;
    _otherCurrent = shownCurrent;
    [YZSettings setIncognito:incognito];
    [self createCore];
    [self applyTheme];
    _tabsView.incognito = incognito;
    [_tabsView showTabs:_tabs selected:_current];
    // the new look is all there under the picture, which now opens away from the origin
    YZMotionFinishReveal(cover, origin);
    [self wobbleChrome];
    if (!_tabsView.hidden)
        [_tabsView present];
    [self saveTabs];
}

// the bars and the glyphs of the new look wobble into their places, one after the other from the top bar to the bottom bar
- (void)wobbleChrome {
    // the glyphs of the bars do not pop in the flat design, only the tiles of the start page settle
    if ([YZTheme isFlat]) {
        if (!_home.hidden)
            [_home animateContents];
        return;
    }
    YZMotionAnimateEnter(_field, CGAffineTransformMakeScale(0.9f, 0.9f), 0, YOZORA_MOTION_WOBBLE, 0.12);
    YZMotionAnimateEnter(_securityView, CGAffineTransformMakeScale(0.3f, 0.3f), 0, YOZORA_MOTION_WOBBLE, 0.2);
    NSArray *buttons = [self barButtons];
    for (NSUInteger i = 0; i < [buttons count]; ++i)
        YZMotionAnimateEnter([(UIButton *)[buttons objectAtIndex:i] imageView], CGAffineTransformMakeScale(0.4f, 0.4f), 0, YOZORA_MOTION_WOBBLE,
                             0.16 + i * 0.04);
    if (!_home.hidden)
        [_home animateContents];
}

// the session ends with its last page: cookies, local storage and databases it made are dropped. a blank tab is all that may be left
- (void)endPrivateSessionIfEmpty {
    NSArray *private = [YZSettings incognito] ? _tabs : _otherTabs;
    if (!private || ([private count] == 1 && [(YZTab *)[private objectAtIndex:0] isBlank]))
        yozora_clear_private_session();
}

#pragma mark loading

- (NSString *)currentURL {
    if (_core) {
        const char *url = yozora_core_url(_core);
        if (url && *url)
            return [NSString stringWithUTF8String:url];
    }
    return [[self currentTab] url];
}

- (void)loadURL:(NSString *)url {
    if (!_core)
        return;
    // the matches belong to the page that goes away
    [self closeFindBar];
    char error[256] = {0};
    if (!yozora_core_load(_core, [url UTF8String], error, sizeof(error))) {
        [self showError:YZTCore([NSString stringWithUTF8String:error])];
        return;
    }
    [self currentTab].url = url;
    [self showBanner:nil];
    [self updateChromeForced:YES];
}

- (void)openAddressText:(NSString *)text {
    char address[YOZORA_URL_CAP];
    yozora_address_kind kind = yozora_address_resolve([text UTF8String], [YZSettings searchEngine], address, sizeof address);
    if (kind == YOZORA_ADDRESS_INVALID) {
        [self showError:YZT(@"Этот адрес не поддерживается")];
        return;
    }
    [self loadURL:[NSString stringWithUTF8String:address]];
}

// ios 10 replaced openURL: with openURL:options:completionHandler: and added the universal links only mode, which opens
// the address in an app that claims it and reports failure otherwise. ios 5 to 9 have neither: openURL: on an https
// address would hand the page to Safari, so the universal links only request fails there at once
static void YZOpenInOtherApp(NSURL *url, BOOL universalOnly, void (^done)(BOOL opened)) {
    UIApplication *application = [UIApplication sharedApplication];
    SEL modern = NSSelectorFromString(@"openURL:options:completionHandler:");
    if ([application respondsToSelector:modern]) {
        // the value of UIApplicationOpenURLOptionUniversalLinksOnly is its own name, the constant is missing from the old sdk
        NSDictionary *options = universalOnly ? [NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES] forKey:@"UIApplicationOpenURLOptionUniversalLinksOnly"] : [NSDictionary dictionary];
        void (^handler)(BOOL) = [[done copy] autorelease];
        void (*open)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL)) = (void (*)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL)))(void *)objc_msgSend;
        open(application, modern, url, options, handler);
        return;
    }
    done(universalOnly ? NO : [application openURL:url]);
}

// the menu, the tray, a list, the settings or the player would cover the page a link opens
- (void)clearScreenForExternalLink {
    [_input resignFirstResponder];
    if (_menu)
        [self dismissMenu];
    if (!_tabsView.hidden)
        [self tabsViewDidFinish:_tabsView];
    [self dismissVideoAnimated:NO];
    // a popup releases its core and its owner link in closePopup, a plain dismiss would leave them behind
    if (_popupController)
        [_popupController closePopup];
    else if (self.presentedViewController)
        [self dismissViewControllerAnimated:NO completion:nil];
}

- (BOOL)openExternalURL:(NSURL *)url {
    NSString *scheme = [[url scheme] lowercaseString];
    if ([scheme isEqualToString:@"yozora-auth"])
        return [self beginSignInFromURL:url];
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"])
        return NO;
    NSString *text = [url absoluteString];
    if (![text length])
        return NO;
    [self clearScreenForExternalLink];
    if (![[self currentTab] isBlank])
        [self addBlankTab];
    [self openAddressText:text];
    return YES;
}

#pragma mark sign in for another app

// the person is asked first: any app can send this link, and the answer carries the cookies of the page
- (BOOL)beginSignInFromURL:(NSURL *)link {
    yozora_signin_status status = YOZORA_SIGNIN_OK;
    YZSignIn *request = [YZSignIn signInForLink:link status:&status];
    if (!request) {
        [self showError:[YZSignIn reasonForStatus:status]];
        return NO;
    }
    [self clearScreenForExternalLink];
    // a request that arrives while the earlier one is still asked about replaces it
    [_signInDialog dismissSilently];
    [_signInDialog release];
    _signInDialog = nil;
    NSString *message = [NSString stringWithFormat:YZT(@"Приложение «%@:» просит открыть %@ в приватной вкладке и вернуть ему адрес страницы и cookies, когда вход закончится."),
                                                   [request callbackScheme], [request host]];
    __block YZBrowserController *me = self;
    _signInDialog = [[YZDialog dialogWithTitle:YZT(@"Вход для другого приложения") message:message cancelTitle:YZT(@"Отмена") confirmTitle:YZT(@"Открыть")
                                   destructive:NO handler:^(NSInteger index, NSArray *texts) {
        (void)texts;
        [me->_signInDialog release];
        me->_signInDialog = nil;
        if (index == 0)
            [me answerSignIn:request outcome:YOZORA_SIGNIN_CANCELLED];
        else
            [me startSignIn:request];
    }] retain];
    [_signInDialog showInView:self.view];
    return YES;
}

// the sign in runs in a tab of the private session, which keeps its own cookies and drops them with its last tab
- (void)startSignIn:(YZSignIn *)request {
    [self closeSignInTab];
    if (![YZSettings incognito]) {
        [self setIncognito:YES];
        if (![YZSettings incognito]) {
            [self answerSignIn:request outcome:YOZORA_SIGNIN_CANCELLED];
            return;
        }
        _signInLeavesPrivate = YES;
    }
    if (![[self currentTab] isBlank]) {
        [self addBlankTab];
        // a full tray refused, addBlankTab told the person why
        if (![[self currentTab] isBlank]) {
            [self leavePrivateAfterSignIn];
            [self answerSignIn:request outcome:YOZORA_SIGNIN_CANCELLED];
            return;
        }
    }
    _signIn = [request retain];
    _signInTab = [self currentTab];
    [self openAddressText:[request startURL]];
}

// the sign in is over without an answer: the tab goes and the state with it
- (void)closeSignInTab {
    YZTab *tab = _signInTab;
    _signInTab = nil;
    [_signIn release];
    _signIn = nil;
    if (!tab)
        return;
    NSUInteger index = [_tabs indexOfObjectIdenticalTo:tab];
    if (index != NSNotFound) {
        [self closeTabAtIndex:index];
        return;
    }
    // the person went back to the normal tabs and the sign in tab waits in the other list
    [_otherTabs removeObjectIdenticalTo:tab];
    [tab removeStoredThumbnail];
    if (![_otherTabs count]) {
        YZTab *blank = [[[YZTab alloc] init] autorelease];
        blank.isPrivate = YES;
        [_otherTabs addObject:blank];
        _otherCurrent = 0;
    } else if (_otherCurrent >= [_otherTabs count])
        _otherCurrent = [_otherTabs count] - 1;
    if ([_otherTabs count] == 1 && [(YZTab *)[_otherTabs objectAtIndex:0] isBlank])
        yozora_clear_private_session();
}

// back to the normal tabs when the sign in is what switched to the private ones and nothing else is open in them
- (void)leavePrivateAfterSignIn {
    BOOL leave = _signInLeavesPrivate;
    _signInLeavesPrivate = NO;
    if (leave && [YZSettings incognito] && [_tabs count] == 1 && [(YZTab *)[_tabs objectAtIndex:0] isBlank])
        [self setIncognito:NO];
}

// opens the link of the app that asked, with the answer on it
- (void)answerSignIn:(YZSignIn *)signIn outcome:(yozora_signin_outcome)outcome {
    [self sendSignIn:signIn outcome:outcome address:nil cookies:nil];
}

- (void)sendSignIn:(YZSignIn *)signIn outcome:(yozora_signin_outcome)outcome address:(NSString *)address cookies:(NSString *)cookies {
    NSURL *result = [signIn resultURLForOutcome:outcome address:address cookies:cookies];
    if (!result) {
        [self showError:YZT(@"Не удалось вернуться в приложение")];
        return;
    }
    __block YZBrowserController *me = self;
    YZOpenInOtherApp(result, NO, ^(BOOL opened) {
        if (!opened)
            [me showError:YZT(@"Не удалось вернуться в приложение")];
    });
}

// every frame: the address is the cheap check, the cookies are read at most once a second away from this thread
- (void)checkSignInAtTime:(CFTimeInterval)now {
    YZSignIn *signIn = _signIn;
    if (signIn.finishing)
        return;
    NSString *address = [self currentURL];
    __block YZBrowserController *me = self;
    if ([signIn finishedAtAddress:address cookies:nil]) {
        signIn.finishing = YES;
        [signIn readCookiesForAddress:address completion:^(NSString *cookies, BOOL tooLarge) {
            [me finishSignIn:signIn address:address cookies:cookies tooLarge:tooLarge];
        }];
        return;
    }
    if ([signIn watchesCookie] && [signIn shouldPollAt:now]) {
        [signIn readCookiesForAddress:address completion:^(NSString *cookies, BOOL tooLarge) {
            if (me->_signIn != signIn || signIn.finishing)
                return;
            if (tooLarge || [signIn finishedAtAddress:address cookies:cookies]) {
                signIn.finishing = YES;
                [me finishSignIn:signIn address:address cookies:cookies tooLarge:tooLarge];
            }
        }];
    }
}

// the cookies are read before the tab closes: the private session drops them with its last tab
- (void)finishSignIn:(YZSignIn *)signIn address:(NSString *)address cookies:(NSString *)cookies tooLarge:(BOOL)tooLarge {
    if (_signIn != signIn)
        return;
    [signIn retain];
    [self closeSignInTab];
    [self leavePrivateAfterSignIn];
    [self sendSignIn:signIn outcome:tooLarge ? YOZORA_SIGNIN_TOO_LARGE : YOZORA_SIGNIN_DONE address:address cookies:cookies];
    [signIn release];
}

- (void)watchExternalLinks {
    char text[YOZORA_URL_CAP];
    int universal = 0;
    if (!_core || !yozora_core_take_external(_core, text, sizeof text, &universal))
        return;
    yozora_core *core = _core;
    NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:text]];
    if (!url) {
        // the page waits for an answer to a universal link, an address that is no url loads in the page like before
        if (universal)
            yozora_core_answer_external(core, 0);
        else
            [self showBanner:YZT(@"Неподдерживаемый адрес страницы")];
        return;
    }
    [self retain];
    YZOpenInOtherApp(url, universal != 0, ^(BOOL opened) {
        // a core that left the screen meanwhile (another tab, a closed popup) has resolved its held link by itself
        // and may be destroyed, so only the core still on screen is answered
        if (_core == core) {
            if (universal)
                yozora_core_answer_external(core, opened ? 1 : 0);
            else if (!opened)
                [self showBanner:YZT(@"Нет приложения для этой ссылки")];
        }
        [self release];
    });
}

- (void)showBanner:(NSString *)text {
    if (text == _shownBanner || [text isEqualToString:_shownBanner])
        return;
    [_shownBanner release];
    _shownBanner = [text retain];
    CGAffineTransform away = CGAffineTransformConcat(CGAffineTransformMakeScale(0.96f, 0.96f), CGAffineTransformMakeTranslation(0, -16));
    if ([text length]) {
        _banner.text = text;
        _banner.hidden = NO;
        _banner.alpha = 1;
        _banner.transform = CGAffineTransformIdentity;
        YZMotionAnimateEnter(_banner, away, 0, YOZORA_MOTION_WOBBLE, 0);
    } else {
        YZMotionAnimateView(_banner, away, 0, YOZORA_MOTION_DISMISS, 0, ^(BOOL finished) {
            (void)finished;
            // a new message that came while this one left keeps the banner
            if (![_shownBanner length]) {
                _banner.hidden = YES;
                _banner.alpha = 1;
                _banner.transform = CGAffineTransformIdentity;
            }
        });
    }
}

// an error stays until closed, the same text is not shown twice and a different one replaces it
- (void)showError:(NSString *)text {
    if (![text length])
        return;
    if (_errorPopup && _errorPopup.isShown) {
        _errorPopup.messageText = text;
        return;
    }
    [_errorPopup release];
    [_translateBar release];
    _errorPopup = [[YZErrorPopup alloc] initWithFrame:self.view.bounds];
    _errorPopup.titleText = YZT(@"Ошибка");
    _errorPopup.messageText = text;
    [_errorPopup showInView:self.view];
}

#pragma mark translation

- (YZTranslation *)currentTranslation {
    return _core ? [self currentTab].translation : nil;
}

- (void)translationDidChange:(YZTranslation *)translation {
    if (translation == [self currentTranslation])
        [self updateTranslationAnimated:YES];
}

- (BOOL)translationMayStartAlone:(YZTranslation *)translation {
    (void)translation;
    // the text of a private tab goes to the service only when the person asks for it
    return ![[self currentTab] isPrivate];
}

// the card follows the phase of the translation of the page that is shown
- (void)updateTranslationAnimated:(BOOL)animated {
    YZTranslation *translation = [self currentTranslation];
    YZTranslationPhase phase = translation ? translation.phase : YZTranslationIdle;
    BOOL visible = phase != YZTranslationIdle && ![[self currentTab] isBlank];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideFinishedTranslateBar) object:nil];
    // a card that was closed stays closed until the phase changes
    if ((int)phase != _translateBarDismissedPhase)
        _translateBarDismissedPhase = -1;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(translateOfferTimedOut) object:nil];
    // an offer the person keeps closing is not made again by itself, the menu still translates
    BOOL muted = phase == YZTranslationOffered && [self translateOffersMuted];
    BOOL showBar = visible && !_editing && !muted && (int)phase != _translateBarDismissedPhase;
    if (showBar) {
        [_translateBar applyTheme];
        [_translateBar showTranslation:translation animated:animated && _translateBarShown];
        [self setTranslateBarShown:YES animated:animated];
        if (phase == YZTranslationDone)
            [self performSelector:@selector(hideFinishedTranslateBar) withObject:nil afterDelay:4];
        // an offer that nobody answered leaves by itself after a while
        else if (phase == YZTranslationOffered)
            [self performSelector:@selector(translateOfferTimedOut) withObject:nil afterDelay:10];
    } else
        [self setTranslateBarShown:NO animated:animated];
}

// the card of a finished translation and the card of an offer nobody answered slide down and stay away until the phase changes
- (void)hideFinishedTranslateBar {
    _translateBarDismissedPhase = YZTranslationDone;
    [self setTranslateBarShown:NO animated:YES];
}

- (void)translateOfferTimedOut {
    if ([self currentTranslation].phase != YZTranslationOffered)
        return;
    _translateBarDismissedPhase = YZTranslationOffered;
    [self setTranslateBarShown:NO animated:YES];
}

// three closes of the offer within ten minutes: the person does not want it
- (BOOL)translateOffersMuted {
    CFTimeInterval now = CACurrentMediaTime();
    NSUInteger recent = 0;
    for (NSNumber *time in _translateCloses) {
        if (now - [time doubleValue] < 600)
            ++recent;
    }
    return recent >= 3;
}

- (void)setTranslateBarShown:(BOOL)shown animated:(BOOL)animated {
    if (shown == _translateBarShown)
        return;
    _translateBarShown = shown;
    if (shown) {
        _translateBar.hidden = NO;
        _translateBar.alpha = 1;
        _translateBar.transform = CGAffineTransformIdentity;
        [self.view bringSubviewToFront:_translateBar];
        // in as the card of the menu: from a small scale with a fade and the wobble
        if (animated)
            YZMotionAnimateEnter(_translateBar, CGAffineTransformMakeScale(0.4f, 0.4f), 0, YOZORA_MOTION_WOBBLE, 0);
        return;
    }
    if (!animated) {
        _translateBar.hidden = YES;
        return;
    }
    // out: down and away on a plain curve, with no spring, so it never hops on the way out
    YZMotionAnimateView(_translateBar, CGAffineTransformMakeTranslation(0, [YZTranslateBar height] + 28), 0, YOZORA_MOTION_EXIT, 0, ^(BOOL finished) {
        (void)finished;
        // a card that came back while this one left stays
        if (!_translateBarShown) {
            _translateBar.hidden = YES;
            _translateBar.alpha = 1;
            _translateBar.transform = CGAffineTransformIdentity;
        }
    });
}

- (void)presentTranslateSheet {
    YZTranslation *translation = [self currentTranslation];
    if (!translation)
        return;
    [_input resignFirstResponder];
    [YZTranslateSheet presentInView:self.view bottomInset:[self chromeInsets].bottom translation:translation
                         completion:^(NSString *source, NSString *target, BOOL showOriginal) {
        if (showOriginal)
            [translation showOriginal];
        else
            [translation translateFrom:source to:target];
    }];
}

- (void)translateBarDidPressTranslate:(YZTranslateBar *)bar {
    (void)bar;
    YZTranslation *translation = [self currentTranslation];
    [translation translateFrom:nil to:translation.target ? translation.target : [YZSettings translateTarget]];
}

- (void)translateBarDidPressOptions:(YZTranslateBar *)bar {
    (void)bar;
    [self presentTranslateSheet];
}

- (void)translateBarDidPressOriginal:(YZTranslateBar *)bar {
    (void)bar;
    [[self currentTranslation] showOriginal];
}

- (void)translateBarDidPressRetry:(YZTranslateBar *)bar {
    (void)bar;
    YZTranslation *translation = [self currentTranslation];
    [translation translateFrom:translation.source to:translation.target ? translation.target : [YZSettings translateTarget]];
}

- (void)translateBarDidPressClose:(YZTranslateBar *)bar {
    (void)bar;
    YZTranslation *translation = [self currentTranslation];
    // closing a running translation gives the page back as it was
    if (translation.phase == YZTranslationWorking) {
        [translation showOriginal];
        return;
    }
    _translateBarDismissedPhase = (int)translation.phase;
    if (translation.phase == YZTranslationOffered) {
        if (!_translateCloses)
            _translateCloses = [[NSMutableArray alloc] init];
        [_translateCloses addObject:[NSNumber numberWithDouble:CACurrentMediaTime()]];
        // only the last few closes matter
        while ([_translateCloses count] > 6)
            [_translateCloses removeObjectAtIndex:0];
    }
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(translateOfferTimedOut) object:nil];
    [self setTranslateBarShown:NO animated:YES];
}

#pragma mark bottom bar

- (void)setBottomBarShown:(BOOL)shown animated:(BOOL)animated {
    if (shown == _bottomBarShown || [self isWide])
        return;
    _bottomBarShown = shown;
    _barLeaving = NO;
    CGFloat away = [self bottomBlockHeight] + [self chromeInsets].bottom + 6;
    CGAffineTransform gone = CGAffineTransformMakeTranslation(0, away);
    if (!shown) {
        // the bar covers the strip until the core paints a frame of the grown size, unpainted it showed as a
        // white band
        _pageReservesBar = NO;
        [self layoutChrome];
        if (!animated) {
            _bottomBar.transform = gone;
            return;
        }
        _barLeaving = YES;
        // a heavy page needs over a second for that, a covered strip beats an empty one
        _barLeaveDeadline = CACurrentMediaTime() + 2.5;
        return;
    }
    // the bar comes back over the page with a wobble, and the page gives the room up when it is there
    YZMotionAnimateView(_bottomBar, CGAffineTransformIdentity, 1, YOZORA_MOTION_WOBBLE, 0, ^(BOOL finished) {
        (void)finished;
        if (_bottomBarShown && (!_pageReservesBar || !_pageReservesTop)) {
            [self givePageRoomBack];
        }
    });
    if (!_pageReservesTop)
        [self moveTopBarAway:NO animated:animated];
    if (!animated) {
        _bottomBar.transform = CGAffineTransformIdentity;
        [self givePageRoomBack];
    }
}

// the bars are back over the page and the page starts under the address bar again. from the top of the page
// nothing scrolls, further down the rows stay where they are
- (void)givePageRoomBack {
    _pageReservesBar = YES;
    if (!_pageReservesTop) {
        _pageReservesTop = YES;
        if (_core && yozora_core_scroll_y(_core) > 8) {
            yozora_core_scroll(_core, (int)[self barHeight]);
            [_pageView syncScrollOffset];
        }
    }
    [self layoutChrome];
}

// the address bar leaves upward and the status strip stays where it is, the field slides under the strip
- (void)moveTopBarAway:(BOOL)away animated:(BOOL)animated {
    CGFloat shift = [self barHeight];
    UIView *strip = [_topBar viewWithTag:2];
    CGAffineTransform bar = away ? CGAffineTransformMakeTranslation(0, -shift) : CGAffineTransformIdentity;
    // the same curve moves both, so the strip does not move on the screen
    CGAffineTransform kept = away ? CGAffineTransformMakeTranslation(0, shift) : CGAffineTransformIdentity;
    [_topBar bringSubviewToFront:strip];
    if (!animated) {
        _topBar.transform = bar;
        strip.transform = kept;
        return;
    }
    yozora_motion_curve curve = away ? YOZORA_MOTION_DISMISS : YOZORA_MOTION_POPUP_ENTER;
    YZMotionAnimateView(_topBar, bar, 1, curve, 0, nil);
    YZMotionAnimateView(strip, kept, 1, curve, 0, nil);
}

- (void)slideBottomBarAway {
    _barLeaving = NO;
    CGFloat away = [self bottomBlockHeight] + [self chromeInsets].bottom + 6;
    YZMotionAnimateView(_bottomBar, CGAffineTransformMakeTranslation(0, away), 1, YOZORA_MOTION_DISMISS, 0, nil);
    if (!_pageReservesTop)
        [self moveTopBarAway:YES animated:YES];
}

// the first layer is as tall as the layout, page height over zoom (a page at 50 percent has a layer twice the
// view)
- (BOOL)sceneFillsPage:(yozora_scene *)scene {
    if (!scene || *yozora_scene_error(scene) || !_core)
        return NO;
    int zoom = yozora_core_page_zoom(_core);
    if (zoom <= 0)
        zoom = 100;
    CGFloat expected = _pageView.bounds.size.height * 100 / zoom;
    const yozora_scene_layer *layers = yozora_scene_layers(scene);
    unsigned count = yozora_scene_layer_count(scene);
    for (unsigned i = 0; i < count; ++i) {
        if (!layers[i].parent && layers[i].height >= expected - 1)
            return YES;
    }
    return NO;
}

- (void)showHome {
    YZTab *tab = [self currentTab];
    BOOL failed = _core && yozora_core_state(_core) == YOZORA_LOAD_FAILED;
    BOOL blank = [tab isBlank] && !failed;
    BOOL appearing = _home.hidden && blank;
    [YZTheme setView:_home shown:blank scale:1];
    [YZTheme setView:_home.groundView shown:blank scale:1];
    [self paintBarsOverHome:blank force:NO];
    _errorPage.hidden = !failed;
    if (failed) {
        const char *status = yozora_core_status(_core);
        [_errorPage showError:yozora_core_page_error(_core) address:[self currentURL] reason:status ? [NSString stringWithUTF8String:status] : nil];
    }
    if (blank) {
        NSMutableArray *sites = [NSMutableArray arrayWithArray:[_store recentHistory]];
        [sites sortUsingComparator:^NSComparisonResult(YZRecord *a, YZRecord *b) {
            if (a.visits == b.visits)
                return NSOrderedSame;
            return a.visits > b.visits ? NSOrderedAscending : NSOrderedDescending;
        }];
        [_home showSites:sites bookmarks:[_store bookmarks]];
        if (appearing)
            [_home animateContents];
    }
}

#pragma mark layout

// an ipad window of 700 points or more shows a tab strip over one toolbar, not slide over or half a split
// view
- (BOOL)isWide {
    return !_popupMode && [YZTheme isPad] && self.view.bounds.size.width >= 700;
}

static const CGFloat YZTabStripHeight = 44;

// the floating bar of the modern design stands in one of two places on a phone, a wide screen has its toolbar at the top whatever was chosen
- (BOOL)layoutAtBottom { return ![self isWide] && [YZTheme barAtBottom]; }
- (BOOL)layoutAtTop { return ![self isWide] && [YZTheme barAtTop]; }

// the height of what stands at the foot of a phone without the home indicator: the keys, and over them the address row in the bottom layout.
// nothing in the top layout and on a wide screen
- (CGFloat)bottomBlockHeight {
    if ([self isWide] || [self layoutAtTop])
        return 0;
    return [self layoutAtBottom] ? 2 * [self barHeight] : [self barHeight];
}

// where the thin line of the load stands, in the coordinates of the bar that holds it: under the address row
- (CGFloat)progressY {
    CGFloat bar = [self barHeight];
    if ([self layoutAtBottom])
        return bar - 3;
    return [self chromeInsets].top + ([self isWide] ? YZTabStripHeight : 0) + bar - 3;
}

- (CGFloat)barHeight {
    BOOL landscape = self.view.bounds.size.width > self.view.bounds.size.height;
    // the bars of ios 7 are 44 points, 32 on a phone on its side, a little more here to keep the glyphs apart
    if ([YZTheme isFlat])
        return (landscape && ![YZTheme isPad]) ? 36 : 44;
    if ([self isWide])
        return 52;
    return (landscape && ![YZTheme isPad]) ? 40 : 56;
}

// the download line sits on the bottom bar on a phone and on the toolbar on a wide screen
- (void)layoutDownloadLine {
    if (!_downloadLine)
        return;
    BOOL wide = [self isWide];
    UIView *host = (wide || [self layoutAtTop]) ? _topBar : _bottomBar;
    if (_downloadLine.superview != host)
        [host addSubview:_downloadLine];
    CGFloat y = (wide || [self layoutAtTop]) ? [self chromeInsets].top + (wide ? YZTabStripHeight : 0) : 0;
    _downloadLine.frame = CGRectMake(0, y, host.bounds.size.width * MAX((CGFloat)0.04, MIN((CGFloat)1, _downloadShare)), 3);
}

- (void)refreshTabStrip {
    if (![self isWide]) {
        [_tabStripSignature release];
        _tabStripSignature = nil;
        return;
    }
    NSMutableString *signature = [NSMutableString stringWithFormat:@"%lu:%d:", (unsigned long)_current, [YZSettings incognito] ? 1 : 0];
    for (YZTab *tab in _tabs)
        [signature appendFormat:@"%@\n%@\n", tab.title ? tab.title : @"", tab.url ? tab.url : @""];
    if ([signature isEqualToString:_tabStripSignature ? _tabStripSignature : @""])
        return;
    [_tabStripSignature release];
    _tabStripSignature = [signature copy];
    [_tabStrip showTabs:_tabs selected:_current];
}

// insets: none on ios 5 and 6 (the view starts below the status bar), the status bar on 7 to 10, notch,
// corners and home indicator from 11
- (UIEdgeInsets)chromeInsets {
    UIEdgeInsets insets = UIEdgeInsetsZero;
    SEL safeArea = NSSelectorFromString(@"safeAreaInsets");
    if ([self.view respondsToSelector:safeArea]) {
        return [[self.view valueForKey:@"safeAreaInsets"] UIEdgeInsetsValue];
    }
    SEL topGuide = NSSelectorFromString(@"topLayoutGuide");
    if ([self respondsToSelector:topGuide]) {
        // the guide is nil in loadView on ios 9 and nsinvocation raises on a nil target,
        // viewDidLayoutSubviews lays out again with the real length
        id guide = [self performSelector:topGuide];
        SEL length = NSSelectorFromString(@"length");
        if (guide && [guide respondsToSelector:length])
            insets.top = ((CGFloat (*)(id, SEL))(void *)objc_msgSend)(guide, length);
    }
    return insets;
}

- (void)layoutChrome {
    CGRect bounds = self.view.bounds;
    CGFloat width = bounds.size.width, height = bounds.size.height, bar = [self barHeight];
    UIEdgeInsets insets = [self chromeInsets];
    CGFloat top = insets.top, bottom = insets.bottom, inner = width - insets.left - insets.right;
    BOOL wide = [self isWide];
    BOOL atBottom = [self layoutAtBottom], atTop = [self layoutAtTop];
    CGFloat strip = wide ? YZTabStripHeight : 0;
    CGFloat toolTop = top + strip;
    // the bottom layout has nothing at the top but the strip under the status line
    CGFloat topRow = atBottom ? 0 : bar;
    // bounds and center, a frame set under the leaving transform lands in the wrong place
    _topBar.bounds = CGRectMake(0, 0, width, toolTop + topRow);
    _topBar.center = CGPointMake(width / 2, (toolTop + topRow) / 2);
    UIView *statusStrip = [_topBar viewWithTag:2];
    statusStrip.bounds = CGRectMake(0, 0, width, top);
    statusStrip.center = CGPointMake(width / 2, top / 2);
    // the side that has no bar takes the color of the page as in Safari: the strip behind the notch in the bottom layout, the strip over
    // the home indicator in the top one. the side with the bar keeps the color of the bar. until the color is known the bottom layout
    // shows the surface of the page
    UIColor *stripColor = [YZTheme statusStripColor];
    if (_barsOverHome)
        stripColor = [UIColor clearColor];
    else if (atBottom && ![YZTheme isClassic])
        stripColor = _edgeColor ? _edgeColor : [YZTheme surfaceColor];
    statusStrip.backgroundColor = stripColor;
    _home.groundView.frame = bounds;
    [_home groundResized];
    // the page ends above the home indicator in the top layout
    BOOL footShown = !_barsOverHome && atTop && ![YZTheme isClassic] && _edgeBottomColor && bottom > 0 && _keyboardHeight <= 0 && !_editing;
    if (footShown && !_footStrip) {
        _footStrip = [[UIView alloc] initWithFrame:CGRectZero];
        _footStrip.userInteractionEnabled = NO;
        [self.view insertSubview:_footStrip aboveSubview:_bottomBar];
    }
    _footStrip.hidden = !footShown;
    if (footShown) {
        _footStrip.backgroundColor = _edgeBottomColor;
        _footStrip.frame = CGRectMake(0, height - bottom, width, bottom);
    }
    _tabStrip.hidden = !wide;
    _tabStrip.frame = CGRectMake(insets.left, top, inner, strip);
    // the buttons live in the bottom bar of a phone, in the toolbar of a wide screen and in the one row of the top layout
    UIView *host = (wide || atTop) ? _topBar : _bottomBar;
    NSArray *buttons = [self barButtons];
    for (UIButton *button in [NSArray arrayWithObjects:_backButton, _forwardButton, _starButton, _shareButton, _tabsButton, _menuButton, nil])
        button.hidden = ![buttons containsObject:button];
    for (UIButton *button in buttons) {
        if (button.superview != host)
            [host addSubview:button];
    }
    // the address, its cancel key and the line of the load stand with the keys in the bottom layout and in the top bar in every other
    UIView *addressHost = atBottom ? _bottomBar : _topBar;
    for (UIView *piece in [NSArray arrayWithObjects:_field, _cancelButton, _progress, nil]) {
        if (piece.superview != addressHost)
            [addressHost addSubview:piece];
    }
    _bottomBar.hidden = wide || atTop;
    // the address field is the search bar of Material 3: a pill that leaves room for the cancel button while it is edited
    CGFloat cancelWidth = _editing ? 80 : 0;
    CGFloat fieldHeight = [YZTheme isFlat] ? MIN(bar - 14, (CGFloat)30) : [YZTheme isFloatingBar] ? bar - 10 : bar - 16;
    CGFloat fieldLeft = insets.left + 12, fieldRight = insets.right + 12;
    if (wide) {
        // back and forward left, bookmark, tabs and menu right, cancel takes the right while the address is
        // edited
        CGFloat slot = 48;
        for (NSUInteger i = 0; i < [buttons count]; ++i) {
            UIButton *button = [buttons objectAtIndex:i];
            CGFloat x = i < 2 ? insets.left + 8 + slot * i : width - insets.right - 8 - slot * ([buttons count] - i);
            button.frame = CGRectMake(x, toolTop, slot, bar);
            if (i >= 2)
                button.hidden = _editing;
        }
        fieldLeft = insets.left + 8 + 2 * slot + 4;
        fieldRight = _editing ? insets.right + 12 : insets.right + 8 + 3 * slot + 4;
        _bottomBar.transform = CGAffineTransformIdentity;
        _bottomBar.frame = CGRectMake(0, height, width, 0);
    } else if (atTop) {
        // the tabs and the menu close the row on the right, the cancel key takes their place while the address is edited
        CGFloat slot = 48;
        for (NSUInteger i = 0; i < [buttons count]; ++i) {
            UIButton *button = [buttons objectAtIndex:i];
            button.frame = CGRectMake(width - insets.right - 8 - slot * ([buttons count] - i), toolTop, slot, bar);
            button.hidden = _editing;
        }
        fieldRight = _editing ? insets.right + 12 : insets.right + 8 + [buttons count] * slot + 4;
        _bottomBar.transform = CGAffineTransformIdentity;
        _bottomBar.frame = CGRectMake(0, height, width, 0);
    } else {
        // the keys are the lower row of the bottom layout, under the address. while the address is edited only its row stays, over the keyboard
        BOOL addressOnly = atBottom && _editing;
        CGFloat slot = inner / [buttons count];
        for (NSUInteger i = 0; i < [buttons count]; ++i) {
            [[buttons objectAtIndex:i] setFrame:CGRectMake(insets.left + slot * i, atBottom ? bar : 0, slot, bar)];
            [[buttons objectAtIndex:i] setHidden:addressOnly];
        }
        CGFloat rows = atBottom ? (addressOnly ? bar : 2 * bar) : bar;
        BOOL lifted = addressOnly && _keyboardHeight > 0;
        CGFloat foot = lifted ? 0 : bottom;
        // bounds and center, a frame set under the leaving transform lands in the wrong place
        CGRect barFrame = CGRectMake(0, height - rows - foot - (lifted ? _keyboardHeight : 0), width, rows + foot);
        _bottomBar.bounds = CGRectMake(0, 0, barFrame.size.width, barFrame.size.height);
        _bottomBar.center = CGPointMake(CGRectGetMidX(barFrame), CGRectGetMidY(barFrame));
        [_bottomBar viewWithTag:YZBottomSkirtTag].frame = CGRectMake(0, barFrame.size.height, barFrame.size.width, 120);
    }
    CGFloat addressTop = atBottom ? 0 : toolTop;
    _field.frame = CGRectMake(fieldLeft, addressTop + floor((bar - fieldHeight) / 2), MAX((CGFloat)0, width - fieldLeft - fieldRight - cancelWidth), fieldHeight);
    // the classic well carries its own corners in its picture
    _field.layer.cornerRadius = [YZTheme isClassic] ? 0 : [YZTheme isFlat] ? 8 : fieldHeight / 2;
    // a shadow without a path is rendered offscreen from the alpha of the layer on every frame, a slow thing on an old phone
    _field.layer.shadowPath = [YZTheme isFloatingBar]
        ? [[UIBezierPath bezierPathWithRoundedRect:_field.bounds cornerRadius:fieldHeight / 2] CGPath] : NULL;
    _securityView.frame = _securityView.contentMode == UIViewContentModeScaleAspectFit ? CGRectMake(14, floor((fieldHeight - 22) / 2), 22, 22)
                                                                                         : CGRectMake(10, 0, 28, fieldHeight);
    // the classic field is a pill with a round end: the keys in it are a little smaller and stand off the end
    BOOL classicField = [YZTheme isClassic];
    CGFloat key = classicField ? fieldHeight - 6 : fieldHeight;
    CGFloat endPad = classicField ? 8 : 4;
    CGFloat keyTop = (fieldHeight - key) / 2;
    _reloadButton.frame = CGRectMake(_field.bounds.size.width - key - endPad, keyTop, key, key);
    // the microphone stands where the reload key does when the page is blank and while the address is typed. there it also keeps the end of the text
    if (!_voiceKnown) {
        _voiceKnown = YES;
        _voiceAvailable = [YZVoiceInput available];
    }
    _micButton.hidden = !_voiceAvailable || !([[self currentTab] isBlank] || _editing);
    _micButton.frame = _reloadButton.frame;
    CGFloat inputLeft = 40, inputRight = _editing ? (_micButton.hidden ? 14 : key + 14) : (_field.bounds.size.width - CGRectGetMinX(_reloadButton.frame));
    if (!_editing) {
        // the address is centered in the field, so it keeps the same room on both sides and does not move when the translate key comes
        inputLeft = MAX(inputLeft, inputRight);
        inputRight = inputLeft;
    }
    _input.frame = CGRectMake(inputLeft, 0, MAX((CGFloat)0, _field.bounds.size.width - inputLeft - inputRight), fieldHeight);
    _cancelButton.frame = CGRectMake(width - insets.right - 84, addressTop, 84, bar);
    _progress.frame = CGRectMake(0, [self progressY], width * (_shownProgress / 100.0f), 3);
    [self layoutDownloadLine];
    // the keyboard of a page field covers the bottom bar and the page ends above it
    CGFloat reserved = wide ? 0 : atTop ? bottom : (_pageReservesBar ? [self bottomBlockHeight] + bottom : 0);
    CGFloat covered = (_pageEditing || [self findBarOpen]) ? MAX(reserved, _keyboardHeight) : reserved;
    // with the address bar gone the page starts under the status strip, which stays
    CGFloat pageTop = atBottom ? top : ((_pageReservesTop || wide) ? toolTop + bar : top);
    // the page stands between the notch insets, the bars keep the full width
    CGRect page = CGRectMake(insets.left, pageTop, MAX((CGFloat)0, inner), MAX((CGFloat)0, height - pageTop - covered));
    _home.frame = page;
    _backgroundEditor.frame = page;
    _elementsEditor.frame = page;
    _errorPage.frame = page;
    _banner.frame = CGRectMake(insets.left + 12, pageTop + 8, MAX((CGFloat)0, inner - 24), 44);
    if (_debugOverlay) {
        // the corner of the page, under the bar, off the notch of a phone on its side
        CGSize overlay = [YZDebugOverlay preferredSize];
        _debugOverlay.frame = CGRectMake(MAX((CGFloat)0, width - overlay.width - 8 - insets.right), pageTop + 8, overlay.width, overlay.height);
    }
    // the card of the translation stands at the bottom of the page, a column on a wide screen
    CGFloat barWidth = MIN(MAX((CGFloat)0, inner - 24), (CGFloat)560);
    // the card follows the bottom edge of the page with a slide so it does not jump by the bar height. placed
    // by bounds and center, its anchor is the bottom edge
    CGPoint translateBottom = CGPointMake(insets.left + floor((inner - barWidth) / 2) + barWidth / 2, CGRectGetMaxY(page) - 10);
    CGRect translateBounds = CGRectMake(0, 0, barWidth, [YZTranslateBar height]);
    if (!CGPointEqualToPoint(_translateBar.center, translateBottom) || !CGRectEqualToRect(_translateBar.bounds, translateBounds)) {
        BOOL slides = _translateBarShown && !_translateBar.hidden && _translateBar.bounds.size.width == barWidth && [YZTheme animationsEnabled];
        void (^place)(void) = ^{
            _translateBar.bounds = translateBounds;
            _translateBar.center = translateBottom;
        };
        if (slides)
            [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut animations:place completion:nil];
        else
            place();
    }
    // the address row of the bottom layout stands over the keyboard, the suggestions end above it
    CGFloat suggestionsBottom = atBottom && _editing ? (_keyboardHeight > 0 ? _keyboardHeight : bottom) + bar : MAX((CGFloat)0, _keyboardHeight);
    _suggestionsTable.frame = CGRectMake(insets.left, pageTop, MAX((CGFloat)0, inner), MAX((CGFloat)0, height - pageTop - suggestionsBottom));
    if (_findBar) {
        // on a phone the bar covers the strip under the status bar too, on a wide screen the tabs stay visible above it
        if (wide)
            [_findBar layoutInRect:CGRectMake(0, toolTop, width, bar) topInset:0 barHeight:bar leftInset:insets.left rightInset:insets.right];
        else
            [_findBar layoutInRect:CGRectMake(0, 0, width, top + bar) topInset:top barHeight:bar leftInset:insets.left rightInset:insets.right];
    }
    _tabsView.edgeInsets = insets;
    _tabsView.frame = bounds;
    [_tabsView setNeedsLayout];
    if (_menu)
        _menu.frame = bounds;
    // bounds and center, the page carries a transform while an edge swipe is on and a frame set under it lands in the wrong place
    CGRect pageBounds = CGRectMake(0, 0, page.size.width, page.size.height);
    CGPoint pageCenter = CGPointMake(CGRectGetMidX(page), CGRectGetMidY(page));
    if (!CGRectEqualToRect(_pageView.bounds, pageBounds) || !CGPointEqualToPoint(_pageView.center, pageCenter)) {
        // another width replaces the surfaces, so old pixels must go. a keyboard only takes height and the
        // tiles stay, clearing them flashed white on a heavy page
        if (fabs(_pageView.bounds.size.width - page.size.width) >= 1)
            [_pageView clearFrame];
        _pageView.bounds = pageBounds;
        _pageView.center = pageCenter;
    }
    if (_core && page.size.width >= 1 && page.size.height >= 1) {
        if (!yozora_core_resize(_core, (unsigned)page.size.width, (unsigned)page.size.height, (float)[[UIScreen mainScreen] scale] * _pageView.rasterFactor))
            [self showError:YZT(@"Не удалось выделить память для страницы")];
        if (_pageEditing)
            yozora_core_reveal_input(_core);
    }
}

// iOS 11 calls this when the notch or the home indicator move, for example on rotation
- (void)viewSafeAreaInsetsDidChange {
    if ([UIViewController instancesRespondToSelector:@selector(viewSafeAreaInsetsDidChange)])
        [super viewSafeAreaInsetsDidChange];
    [self layoutChrome];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutChrome];
}

- (void)keyboardChanged:(NSNotification *)note {
    NSValue *value = [[note userInfo] objectForKey:UIKeyboardFrameEndUserInfoKey];
    CGRect frame = [self.view convertRect:[value CGRectValue] fromView:nil];
    BOOL showing = [[note name] isEqualToString:UIKeyboardWillShowNotification];
    _keyboardHeight = showing ? MAX((CGFloat)0, self.view.bounds.size.height - frame.origin.y) : 0;
    [self layoutChrome];
}

#pragma mark chrome state

- (void)setBarButton:(UIButton *)button enabled:(BOOL)enabled {
    if (button.enabled != enabled)
        button.enabled = enabled;
}

- (void)updateAddressDisplay {
    if (_editing)
        return;
    NSString *url = [self currentURL];
    char host[256];
    NSString *shown = @"";
    if ([url length]) {
        if (yozora_address_host([url UTF8String], host, sizeof host))
            shown = [NSString stringWithUTF8String:host];
        else
            shown = url;
    }
    if ([YZTheme isFloatingBar]) {
        // the pill shows the host and, lighter, the title of the page after it, as Safari does. the field gets plain text again when it is edited
        NSString *title = [[self currentTab] title];
        NSString *tail = [shown length] && ![title isEqualToString:shown] ? title : nil;
        YZSetAddressText(_input, shown, tail, [YZTheme fieldInkColor], [YZTheme fieldHintColor]);
        return;
    }
    if (![_input.text isEqualToString:shown])
        _input.text = shown;
}

- (void)updateChromeForced:(BOOL)forced {
    YZTab *tab = [self currentTab];
    BOOL blank = [tab isBlank];
    yozora_load_state state = _core ? yozora_core_state(_core) : YOZORA_LOAD_IDLE;
    const char *coreURL = _core ? yozora_core_url(_core) : NULL;
    NSString *url = (coreURL && *coreURL) ? YZStringReusing(coreURL, _shownURL) : tab.url;
    NSString *title = _core ? YZStringReusing(yozora_core_title(_core), _shownTitle) : tab.title;
    if (!title)
        title = @"";
    BOOL blankChanged = blank != _shownBlank;
    BOOL back = _core && yozora_core_can_go_back(_core);
    BOOL forward = _core && yozora_core_can_go_forward(_core);
    BOOL secure = _core && yozora_core_is_secure(_core);
    BOOL bookmarked = !blank && [_store isBookmarked:url];
    int progress = (_core && state == YOZORA_LOAD_LOADING) ? (int)(yozora_core_progress(_core) * 100) : 0;

    if (forced || !YZSameString(url, _shownURL)) {
        // the string may be the one already held, so it is retained before the old reference goes
        NSString *previousURL = _shownURL;
        _shownURL = [url retain];
        if ([url length]) {
            NSString *host = [[NSURL URLWithString:url] host];
            [YZCrash note:[NSString stringWithFormat:@"page %@", host ? host : @"-"]];
        }
        [previousURL release];
        if (url && ![url isEqualToString:tab.url] && state != YOZORA_LOAD_IDLE)
            tab.url = url;
        [self updateAddressDisplay];
    }
    if (forced || ![title isEqualToString:_shownTitle]) {
        NSString *previousTitle = _shownTitle;
        _shownTitle = [title retain];
        [previousTitle release];
        if ([title length])
            tab.title = title;
        // the title is part of the address pill of the floating bar
        if ([YZTheme isFloatingBar])
            [self updateAddressDisplay];
    }
    if (forced || (int)state != _shownState || blank != _shownBlank || secure != _shownSecure) {
        _shownState = state;
        _shownBlank = blank;
        _shownSecure = secure;
        // the key of the translation belongs to a page: the start page has none, whatever was offered before
        [self updateTranslationAnimated:NO];
        BOOL loading = state == YOZORA_LOAD_LOADING;
        [_reloadButton setImage:[YZTheme chromeIcon:(loading ? YZIconStop : YZIconReload) size:[YZTheme isFlat] ? 18 : 20 color:[YZTheme fieldHintColor]]
                       forState:UIControlStateNormal];
        _reloadButton.hidden = blank || _editing;
        // the microphone takes the place of the reload key on a blank page
        [self.view setNeedsLayout];
        _reloadButton.accessibilityLabel = loading ? YZT(@"Остановить") : YZT(@"Обновить");
        // a blank private tab shows the mask of the private session where a blank tab shows the search glass
        _securityView.image = [YZTheme chromeIcon:(blank ? ([YZSettings incognito] ? YZIconIncognito : YZIconSearch) : YZIconLock) size:[YZTheme isFlat] ? 16 : 20
                                      color:(secure || (blank && [YZSettings incognito])) ? [YZTheme fieldAccentColor] : [YZTheme fieldHintColor]];
        // the floating bar shows the mark of the search engine on a blank page, small, in place of the glass
        _securityView.contentMode = UIViewContentModeCenter;
        if (blank && [YZTheme isFloatingBar] && ![YZSettings incognito]) {
            NSArray *logos = [NSArray arrayWithObjects:@"google", @"duckduckgo", @"yandex", nil];
            NSUInteger engine = (NSUInteger)[YZSettings searchEngine];
            UIImage *mark = engine < [logos count] ? [YZTheme logoNamed:[logos objectAtIndex:engine]] : nil;
            if (mark) {
                _securityView.image = mark;
                _securityView.contentMode = UIViewContentModeScaleAspectFit;
            }
        }
        _securityView.hidden = !blank && !secure;
        if (state != YOZORA_LOAD_FAILED)
            [self showBanner:nil];
        [self showHome];
    }
    if (forced || back != _shownBack || forward != _shownForward || blankChanged) {
        _shownBack = back;
        _shownForward = forward;
        [self setBarButton:_backButton enabled:back];
        [self setBarButton:_forwardButton enabled:forward];
    }
    if (forced || bookmarked != _shownBookmarked || blankChanged) {
        _shownBookmarked = bookmarked;
        UIImage *star = [YZTheme chromeIcon:(bookmarked ? YZIconStarFilled : YZIconStar) size:24
                                color:bookmarked ? [YZTheme barHighlightColor] : [YZTheme barInkColor]];
        if ([YZTheme isClassic])
            star = [YZClassic stampedImage:star];
        [_starButton setImage:star forState:UIControlStateNormal];
        [self setBarButton:_starButton enabled:!blank];
        [self setBarButton:_shareButton enabled:!blank && !_popupMode && [self canShare]];
    }
    [self refreshTabStrip];
    if (forced || (int)[_tabs count] != _shownTabCount) {
        BOOL changed = _shownTabCount > 0 && (int)[_tabs count] != _shownTabCount;
        _shownTabCount = (int)[_tabs count];
        [_tabsButton setImage:_popupMode ? [YZTheme barIcon:YZIconClose size:24 disabled:NO]
                                       : [YZTheme barTabsIconWithCount:[_tabs count] size:24]
                       forState:UIControlStateNormal];
        if (changed && !_popupMode)
            [YZTheme animateFeedbackOfView:_tabsButton.imageView];
    }
    if (forced || progress != _shownProgress) {
        int previous = _shownProgress;
        _shownProgress = progress;
        CGFloat full = self.view.bounds.size.width, y = [self progressY];
        if (progress == 0 && previous > 0 && !_progress.hidden) {
            // a finished load runs the bar to the end and lets it fade
            [UIView animateWithDuration:[YZTheme animationsEnabled] ? 0.25 : 0 delay:0
                                options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                             animations:^{
                _progress.frame = CGRectMake(0, y, full, 3);
                _progress.alpha = 0;
            } completion:^(BOOL finished) {
                (void)finished;
                if (_shownProgress == 0) {
                    _progress.hidden = YES;
                    _progress.alpha = 1;
                }
            }];
        } else if (progress > 0) {
            if (_progress.hidden || _progress.alpha < 1) {
                _progress.hidden = NO;
                _progress.alpha = 1;
                _progress.frame = CGRectMake(0, y, 0, 3);
            }
            [UIView animateWithDuration:[YZTheme animationsEnabled] ? 0.2 : 0 delay:0
                                options:UIViewAnimationOptionCurveLinear | UIViewAnimationOptionBeginFromCurrentState
                             animations:^{ _progress.frame = CGRectMake(0, y, full * (progress / 100.0f), 3); } completion:nil];
        } else {
            _progress.hidden = YES;
        }
    }
}

#pragma mark display link

// a site asks for a name and a password: the question is shown once, the page waits for the answer
- (void)watchAuthQuestions {
    if (_authAlert || !_core)
        return;
    yozora_auth_request question;
    if (!yozora_core_take_auth(_core, &question))
        return;
    _authID = question.id;
    NSString *site = [NSString stringWithUTF8String:question.host];
    NSMutableString *message = [NSMutableString stringWithString:site];
    if (question.realm[0])
        [message appendFormat:@"\n%s", question.realm];
    if (question.failures)
        [message appendFormat:@"\n%@", YZT(@"Имя или пароль не подошли.")];
    // basic authentication sends the password as it is, which a plain connection shows to everyone on the way
    if (!question.secure)
        [message appendFormat:@"\n%@", YZT(@"Соединение не защищено, пароль передаётся открытым текстом.")];
    __block YZBrowserController *me = self;
    unsigned authID = _authID;
    _authAlert = [[YZDialog dialogWithTitle:YZT(@"Требуется вход") message:message cancelTitle:YZT(@"Отмена") confirmTitle:YZT(@"Войти") destructive:NO
                                    handler:^(NSInteger index, NSArray *texts) {
        [me->_authAlert release];
        me->_authAlert = nil;
        if (!me->_core)
            return;
        if (index == 0)
            yozora_core_auth_respond(me->_core, authID, NULL, NULL);
        else
            yozora_core_auth_respond(me->_core, authID, [[texts objectAtIndex:0] UTF8String], [[texts objectAtIndex:1] UTF8String]);
    }] retain];
    [_authAlert setFieldPlaceholders:[NSArray arrayWithObjects:YZT(@"Имя"), YZT(@"Пароль"), nil] secureIndex:1];
    [_authAlert showInView:self.view];
}

// ask only sites without a decision, the location manager runs while a page watches
- (void)watchGeolocation {
    if (!_core)
        return;
    if (!_geoAlert) {
        yozora_geolocation_request question;
        if (yozora_core_take_geolocation_request(_core, &question)) {
            unsigned geoID = question.id;
            NSString *site = [NSString stringWithUTF8String:question.origin];
            __block YZBrowserController *me = self;
            _geoAlert = [[YZDialog dialogWithTitle:YZT(@"Определить местоположение?") message:site cancelTitle:YZT(@"Запретить") confirmTitle:YZT(@"Разрешить")
                                       destructive:NO handler:^(NSInteger index, NSArray *texts) {
                (void)texts;
                [me->_geoAlert release];
                me->_geoAlert = nil;
                if (me->_core)
                    yozora_core_geolocation_answer(me->_core, geoID, index != 0);
            }] retain];
            [_geoAlert showInView:self.view];
        }
    }
    if (!_location)
        _location = [[YZLocation alloc] init];
    int accuracy = 0;
    int wanted = yozora_core_geolocation_wanted(_core, &accuracy);
    [_location updateForCore:_core wanted:wanted != 0 highAccuracy:accuracy != 0];
}

// ask once per site, the core keeps the answer. nothing shows while the app is hidden, the core thread is
// paused then
- (void)watchNotifications {
    if (!_core)
        return;
    if (!_notificationAlert) {
        yozora_notification_request question;
        if (yozora_core_take_notification_request(_core, &question)) {
            unsigned requestID = question.id;
            NSString *site = [NSString stringWithUTF8String:question.origin];
            __block YZBrowserController *me = self;
            _notificationAlert = [[YZDialog dialogWithTitle:YZT(@"Показывать уведомления?") message:site ? site : @"" cancelTitle:YZT(@"Запретить") confirmTitle:YZT(@"Разрешить")
                                                destructive:NO handler:^(NSInteger index, NSArray *texts) {
                (void)texts;
                [me->_notificationAlert release];
                me->_notificationAlert = nil;
                if (me->_core)
                    yozora_core_notification_answer(me->_core, requestID, index != 0);
            }] retain];
            [_notificationAlert showInView:self.view];
        }
    }
    yozora_notification shown;
    while (yozora_core_take_notification(_core, &shown)) {
        NSString *title = [NSString stringWithUTF8String:shown.title];
        NSString *body = [NSString stringWithUTF8String:shown.body];
        NSString *text = [body length] ? [NSString stringWithFormat:@"%@\n%@", title ? title : @"", body] : title;
        if (![text length])
            continue;
        [_notificationText release];
        _notificationText = [text copy];
        [self showBanner:text];
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideNotificationBanner) object:nil];
        [self performSelector:@selector(hideNotificationBanner) withObject:nil afterDelay:5];
    }
}

// the banner goes unless something else has taken it over in the meantime
- (void)hideNotificationBanner {
    if ([_shownBanner isEqualToString:_notificationText])
        [self showBanner:nil];
    [_notificationText release];
    _notificationText = nil;
}

#pragma mark developer settings

// follow their switches at start and after every settings change
- (void)applyDeveloperSettings {
    [YZLog setCapturing:[YZSettings logging]];
    if ([YZSettings debugOverlay]) {
        if (!_debugOverlay) {
            CGSize size = [YZDebugOverlay preferredSize];
            _debugOverlay = [[YZDebugOverlay alloc] initWithFrame:CGRectMake(0, 0, size.width, size.height)];
            [self.view addSubview:_debugOverlay];
            [self layoutChrome];
        }
        _debugOverlay.hidden = NO;
        [self.view bringSubviewToFront:_debugOverlay];
    } else if (_debugOverlay) {
        [_debugOverlay removeFromSuperview];
        [_debugOverlay release];
        _debugOverlay = nil;
    }
}

// once for every frame of the display link: the frames are counted, and the overlay reads the system twice a second
- (void)noteDisplayFrame {
    if (!_debugOverlay)
        return;
    [_debugOverlay noteFrame];
    NSString *url = [self currentURL];
    _debugOverlay.site = [url length] ? [[NSURL URLWithString:url] host] : nil;
    [_debugOverlay refreshWithCore:_core];
}

- (void)pumpCore:(CADisplayLink *)link {
    if (!_core)
        return;
    [self watchAuthQuestions];
    [self watchGeolocation];
    [self watchNotifications];
    [self watchPageControls];
    [self watchExternalLinks];
    [self watchLongPresses];
    [self updateFindState];
    [self watchDownloadsAt:link.timestamp];
    if (_popupMode && yozora_core_close_requested(_core)) {
        [self closePopup];
        return;
    }
    yozora_core *popup = yozora_core_take_popup(_core);
    if (popup) {
        if (_popupController || self.presentedViewController) {
            yozora_core_destroy(popup);
            [self showBanner:YZT(@"Всплывающее окно заблокировано")];
        } else {
            _popupController = [[YZBrowserController alloc] init];
            _popupController->_initialPopupCore = popup;
            _popupController->_popupMode = YES;
            _popupController->_popupOwner = self;
            [self presentViewController:_popupController animated:YES completion:nil];
        }
    }
    yozora_media_request media;
    while (_core && yozora_core_take_media(_core, &media))
        [self handleMedia:&media];
    [_pageView advanceFlingAtTime:link.timestamp];
    [self trackEdgeColorAtTime:link.timestamp];
    [_pageView updateInput];
    if ([_pageView isFirstResponder] != _pageEditing) {
        _pageEditing = [_pageView isFirstResponder];
        [self layoutChrome];
    }
    yozora_scene *scene = yozora_core_take_scene(_core);
    if (scene) {
        _lastSceneTime = link.timestamp;
        _hasFrame = YES;
        [_debugOverlay noteScene];
        [_pageView showScene:scene];
        if (_barLeaving && [self sceneFillsPage:scene])
            [self slideBottomBarAway];
        yozora_scene_release(scene);
    } else
        [_pageView syncScrollOffset];
    if (_barLeaving && CACurrentMediaTime() >= _barLeaveDeadline)
        [self slideBottomBarAway];
    [_pageView showMediaPlayers:[_mediaPlayers allValues] excluding:_videoController ? _videoController.mediaID : _leavingVideoID];
    [_pageView updateSelection];
    yozora_record visit;
    BOOL visited = NO;
    while (yozora_core_take_visit(_core, &visit)) {
        // with the history switched off, or in the private session, the visit is dropped, tabs are still saved
        if ([YZSettings saveHistory] && ![YZSettings incognito]) {
            [_store recordVisit:&visit failure:^(NSString *reason) {
                [self showError:[NSString stringWithFormat:YZT(@"История не сохранена: %@"), reason]];
            }];
        }
        visited = YES;
    }
    if (_signIn && _signInTab == [self currentTab])
        [self checkSignInAtTime:link.timestamp];
    yozora_load_state state = yozora_core_state(_core);
    // a page that has just finished is photographed after a moment, once its first frames are on screen
    if ((int)state != _lastLoadState) {
        if (state == YOZORA_LOAD_COMPLETE) {
            _thumbnailDue = link.timestamp + 1.2;
            // the language of the page is found once it has loaded
            if (![[self currentTab] isBlank])
                [[self currentTab].translation pageDidLoad];
            [self fillPasswordOfLoadedPage];
            _edgeSampleDue = link.timestamp + 0.3;
        } else if (state == YOZORA_LOAD_LOADING) {
            [self capturePasswordOfLeavingPage];
            [self setEdgeColor:nil bottom:nil];
            [[self currentTab].translation cancel];
            // a new page starts at its own size, like in Safari
            [_pageView resetZoom];
            // a page that starts to load shows the bar it came with
            [self setBottomBarShown:YES animated:YES];
        }
        _lastLoadState = (int)state;
    }
    if (_thumbnailDue && link.timestamp >= _thumbnailDue && !_pageView.active) {
        _thumbnailDue = 0;
        [self captureCurrentTab];
    }
    if (_restoreScroll && state == YOZORA_LOAD_COMPLETE) {
        yozora_core_scroll(_core, _restoreScroll);
        _restoreScroll = 0;
    } else if (state == YOZORA_LOAD_FAILED)
        _restoreScroll = 0;
    [self updateChromeForced:NO];
    // keep moving pages at display rate, quiet pages still notice a new scene within two display frames
    if (link.timestamp - _lastSceneTime < 0.2 || _pageView.active || state == YOZORA_LOAD_LOADING || yozora_core_painting(_core))
        YZSetLinkDivisor(link, 1);
    else
        YZSetLinkDivisor(link, [[self currentTab] isBlank] && state == YOZORA_LOAD_IDLE ? 6 : 2);
    if (_popupMode) {
        _menuButton.enabled = NO;
        _starButton.enabled = NO;
        _shareButton.enabled = NO;
    }
    if (visited)
        [self saveTabs];
}

#pragma mark video and audio of pages

// the page asked the player of the interface to play, pause, seek, close or show the full screen player
- (void)handleMedia:(const yozora_media_request *)request {
    if (!_mediaPlayers)
        _mediaPlayers = [[NSMutableDictionary alloc] init];
    NSNumber *key = [NSNumber numberWithUnsignedInt:request->id];
    YZMediaPlayer *player = [_mediaPlayers objectForKey:key];
    if (request->command == YOZORA_MEDIA_OPEN) {
        [YZCrash note:[NSString stringWithFormat:@"media %u open", request->id]];
        [player shutDown];
        player = [[[YZMediaPlayer alloc] initWithRequest:request core:_core] autorelease];
        [_mediaPlayers setObject:player forKey:key];
        return;
    }
    [player handleRequest:request];
    // a video plays on the page, the full screen player comes only when the page asks for it
    if (request->command == YOZORA_MEDIA_FULLSCREEN) {
        if (request->value > 0)
            [self presentVideoOfPlayer:player];
        else if (_videoController.mediaID == request->id)
            [self dismissVideoAnimated:YES];
    }
    if (request->command == YOZORA_MEDIA_CLOSE) {
        [YZCrash note:[NSString stringWithFormat:@"media %u close", request->id]];
        if (_videoController.mediaID == request->id)
            [self dismissVideoAnimated:YES];
        [_mediaPlayers removeObjectForKey:key];
    }
}

// the player, or the answer that the page stays as it was: sound has no picture and a sheet may be up
- (void)presentVideoOfPlayer:(YZMediaPlayer *)player {
    if (!player || !player.videoLayer || _videoController || self.presentedViewController) {
        if (player && _core)
            yozora_core_media_event(_core, player.mediaID, YOZORA_MEDIA_FULLSCREEN_LEFT, 0, 0);
        return;
    }
    _videoController = [[YZVideoController alloc] initWithPlayer:player title:player.title];
    _videoController.delegate = self;
    [self presentViewController:_videoController animated:YES completion:nil];
}

// no event goes back to the page: it asked for this itself or its core is going away
- (void)dismissVideoAnimated:(BOOL)animated {
    if (!_videoController)
        return;
    YZVideoController *controller = _videoController;
    _videoController = nil;
    controller.delegate = nil;
    [controller shutDown];
    unsigned mediaID = controller.mediaID;
    _leavingVideoID = mediaID;
    [self dismissViewControllerAnimated:animated completion:^{
        if (_leavingVideoID == mediaID)
            _leavingVideoID = 0;
        [controller release];
    }];
}

- (void)videoControllerFinished:(YZVideoController *)controller failed:(BOOL)failed {
    if (controller != _videoController)
        return;
    unsigned mediaID = controller.mediaID;
    [self dismissVideoAnimated:YES];
    // the element leaves its full screen state, whether the person closed the player or the stream failed
    if (_core)
        yozora_core_media_event(_core, mediaID, YOZORA_MEDIA_FULLSCREEN_LEFT, 0, 0);
    if (failed)
        [self showError:YZT(@"Видео не удалось воспроизвести")];
}

- (void)closePopup {
    YZBrowserController *owner = _popupOwner;
    if (!owner)
        return;
    [self destroyCore];
    _popupOwner = nil;
    [owner dismissViewControllerAnimated:YES completion:^{
        [owner->_popupController release];
        owner->_popupController = nil;
        [owner updateChromeForced:YES];
    }];
}

#pragma mark passwords

// a page that starts to load may be leaving a login form that was just sent: the old document and the typed fields stay until the answer of
// the new page commits, and the script runs on the core thread before that answer is handled. an answer that commits first leaves nothing
// to read and nothing is offered
- (void)capturePasswordOfLeavingPage {
    YZTab *tab = [self currentTab];
    YZTranslation *runner = tab.translation;
    if (!runner || !_core)
        return;
    [runner runScript:[YZPasswords captureScript] completion:^(NSString *answer) {
        YZPasswordCapture *capture = [YZPasswords captureFromAnswer:answer];
        if (capture && tab == [self currentTab])
            [self offerToSavePassword:capture];
    }];
}

// asks as Safari does: save (or update a changed password), never for this site, not now. an offer that meets another sheet is dropped
- (void)offerToSavePassword:(YZPasswordCapture *)capture {
    if (_controlSheet || _targetMenu || _filePicker || _menu || self.presentedViewController || !_tabsView.hidden)
        return;
    BOOL never = [YZPasswords neverSavesForSite:capture.site];
    NSString *stored = never ? nil : [YZPasswords passwordForSite:capture.site user:capture.user];
    yozora_password_offer offer = yozora_password_decide([capture.user UTF8String], [capture.password UTF8String], [stored UTF8String], never);
    if (offer == YOZORA_PASSWORD_IGNORE)
        return;
    BOOL update = offer == YOZORA_PASSWORD_UPDATE;
    NSString *who = [capture.user length] ? [NSString stringWithFormat:@"%@ (%@)", capture.site, capture.user] : capture.site;
    NSString *title = [NSString stringWithFormat:update ? YZT(@"Обновить пароль для %@?") : YZT(@"Сохранить пароль для %@?"), who];
    NSMutableArray *texts = [NSMutableArray arrayWithObject:update ? YZT(@"Обновить пароль") : YZT(@"Сохранить пароль")];
    NSMutableArray *icons = [NSMutableArray arrayWithObject:[NSNumber numberWithInt:YZIconLock]];
    if (!update) {
        [texts addObject:YZT(@"Никогда для этого сайта")];
        [icons addObject:[NSNumber numberWithInt:YZIconDelete]];
    }
    [texts addObject:YZT(@"Не сейчас")];
    [icons addObject:[NSNumber numberWithInt:YZIconClose]];
    [_input resignFirstResponder];
    NSInteger neverIndex = update ? -1 : 1;
    _controlSheet = [[YZPickers presentActionsInView:self.view title:title texts:texts icons:icons bottomInset:[self chromeInsets].bottom
                                          completion:^(NSInteger index) {
        [_controlSheet release];
        _controlSheet = nil;
        if (index == 0) {
            NSString *reason = nil;
            if (![YZPasswords savePassword:capture.password site:capture.site user:capture.user error:&reason])
                [self showError:[NSString stringWithFormat:YZT(@"Пароль не сохранён: %@"), reason]];
        } else if (index == neverIndex) {
            [YZPasswords setNeverSaves:YES site:capture.site];
        }
    }] retain];
}

// a loaded https page with one empty password field takes the login saved last for its site, as the keychain of Safari fills it. the page
// sees the values like typed ones, so only the exact site of the top frame gets them
- (void)fillPasswordOfLoadedPage {
    YZTranslation *runner = [self currentTab].translation;
    NSString *site = [YZPasswords siteOfAddress:[self currentURL]];
    if (!runner || !site)
        return;
    NSArray *accounts = [YZPasswords accountsForSite:site];
    if (![accounts count])
        return;
    YZPasswordAccount *account = [accounts objectAtIndex:0];
    NSString *password = [YZPasswords passwordForSite:site user:account.user];
    NSString *script = password ? [YZPasswords fillScriptWithUser:account.user password:password] : nil;
    if (script)
        [runner runScript:script completion:^(NSString *answer) { (void)answer; }];
}

#pragma mark page and home delegates

- (void)pageView:(YZPageView *)view tappedAtPoint:(CGPoint)point {
    (void)view;
    [_input resignFirstResponder];
    if (_core)
        yozora_core_tap(_core, (int)point.x, (int)point.y);
}

- (void)pageViewDidScroll:(YZPageView *)view {
    (void)view;
}

// an enlarged page is painted at more pixels so its text stays sharp, the layout keeps its size
- (void)pageViewDidChangeRasterFactor:(YZPageView *)view {
    CGSize size = view.bounds.size;
    if (!_core || size.width < 1 || size.height < 1)
        return;
    if (!yozora_core_resize(_core, (unsigned)size.width, (unsigned)size.height, (float)[[UIScreen mainScreen] scale] * view.rasterFactor))
        [self showError:YZT(@"Не удалось выделить память для страницы")];
}

- (void)homeView:(YZHomeView *)view didSelectURL:(NSString *)url {
    (void)view;
    [self loadURL:url];
}

typedef enum { YZHomeActionBackground, YZHomeActionAdd, YZHomeActionRemove, YZHomeActionReset, YZHomeActionElements } YZHomeAction;

// a held finger on the start page: the background, a new site, the tile under the finger, the order of the blocks back to the default once it
// was changed, and the parts of the page. a favorite taken off the page leaves the favorites, a visited site is only hidden from the page and
// stays in the history
- (void)homeView:(YZHomeView *)view didHoldAt:(CGPoint)point siteURL:(NSString *)siteURL favorite:(BOOL)favorite {
    (void)view;
    if (_targetMenu || _menu || _controlSheet || _filePicker || self.presentedViewController || !_tabsView.hidden)
        return;
    NSMutableArray *texts = [NSMutableArray array], *icons = [NSMutableArray array], *actions = [NSMutableArray array];
    void (^add)(YZHomeAction, NSString *, YZIcon) = ^(YZHomeAction action, NSString *title, YZIcon icon) {
        [texts addObject:title];
        [icons addObject:[NSNumber numberWithInt:icon]];
        [actions addObject:[NSNumber numberWithInt:action]];
    };
    add(YZHomeActionBackground, YZT(@"Фон"), YZIconImage);
    add(YZHomeActionAdd, YZT(@"Добавить веб-сайт"), YZIconPlus);
    if ([siteURL length])
        add(YZHomeActionRemove, YZT(@"Убрать с главного экрана"), YZIconDelete);
    NSArray *order = [YZSettings homeOrder];
    uint8_t standard[YOZORA_HOME_BLOCKS];
    yozora_home_order_default(standard);
    BOOL custom = NO;
    for (NSUInteger i = 0; i < [order count]; ++i)
        custom = custom || [[order objectAtIndex:i] intValue] != standard[i];
    if (custom)
        add(YZHomeActionReset, YZT(@"Вернуть порядок"), YZIconSwap);
    add(YZHomeActionElements, YZT(@"Настроить элементы"), YZIconSettings);
    [_input resignFirstResponder];
    __block YZPopupMenu *menu = nil;
    NSString *held = [[siteURL copy] autorelease];
    menu = [[YZPopupMenu alloc] initWithTitles:texts icons:icons handler:^(NSInteger index) {
        if (_targetMenu == menu) {
            [_targetMenu release];
            _targetMenu = nil;
        }
        if (index < 0 || index >= (NSInteger)[actions count])
            return;
        switch ((YZHomeAction)[[actions objectAtIndex:index] intValue]) {
        case YZHomeActionBackground:
            [self presentHomeBackground];
            break;
        case YZHomeActionAdd:
            [self askForSiteToAdd];
            break;
        case YZHomeActionRemove:
            if (!favorite)
                [YZSettings hideHomeSite:held];
            else if (![_store removeBookmarkWithURL:held])
                [self showError:YZT(@"Не удалось убрать сайт")];
            [self showHome];
            break;
        case YZHomeActionElements:
            [self presentHomeElements];
            break;
        case YZHomeActionReset:
            [YZSettings setHomeOrder:[NSArray arrayWithObjects:[NSNumber numberWithInt:YOZORA_HOME_BRAND], [NSNumber numberWithInt:YOZORA_HOME_SITES],
                                      [NSNumber numberWithInt:YOZORA_HOME_FAVORITES], nil]];
            [_home relayoutAnimated];
            break;
        }
    }];
    menu.bottomInset = [self chromeInsets].bottom + (_bottomBarShown ? [self bottomBlockHeight] : 0);
    _targetMenu = menu;
    [menu showInView:self.view anchor:point];
}

// the controls of the background stand on the start page itself, over its foot, and the page shows the change under them
- (void)presentHomeBackground {
    if (_backgroundEditor)
        return;
    _backgroundEditor = [[YZHomeBackgroundEditor alloc] initWithHome:_home host:self changed:^{ [_home applyTheme]; } finished:^{
        [_backgroundEditor release];
        _backgroundEditor = nil;
    }];
    [_backgroundEditor presentInView:self.view];
    _backgroundEditor.frame = _home.frame;
}

// the switches of the parts of the page stand on the page itself over its foot and the page shows every change under them
- (void)presentHomeElements {
    if (_elementsEditor)
        return;
    _elementsEditor = [[YZHomeElementsEditor alloc] initWithHome:_home changed:^{ [_home relayoutAnimated]; } finished:^{
        [_elementsEditor release];
        _elementsEditor = nil;
    }];
    [_elementsEditor presentInView:self.view];
    _elementsEditor.frame = _home.frame;
}

// the search line of the start page opens the address field as a tap on the address bar does
- (void)homeViewDidTapSearch:(YZHomeView *)view {
    (void)view;
    [_input becomeFirstResponder];
}

// the plus tile: a card with one field. only an address of a site is kept, the text that would be searched for is refused
- (void)homeViewDidTapAdd:(YZHomeView *)view {
    (void)view;
    [self askForSiteToAdd];
}

- (void)askForSiteToAdd {
    if (_addSiteDialog || self.presentedViewController)
        return;
    __block YZBrowserController *me = self;
    _addSiteDialog = [[YZDialog dialogWithTitle:YZT(@"Добавить веб-сайт") message:nil cancelTitle:YZT(@"Отмена") confirmTitle:YZT(@"Добавить") destructive:NO
                                        handler:^(NSInteger index, NSArray *texts) {
        [me->_addSiteDialog release];
        me->_addSiteDialog = nil;
        if (index != 1 || ![texts count])
            return;
        [me addSiteWithText:[texts objectAtIndex:0]];
    }] retain];
    [_addSiteDialog setFieldPlaceholders:[NSArray arrayWithObject:YZT(@"Адрес сайта")] secureIndex:-1];
    [_addSiteDialog showInView:self.view];
}

- (void)addSiteWithText:(NSString *)text {
    NSString *typed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    char address[YOZORA_URL_CAP], host[256];
    if (![typed length] || yozora_address_resolve([typed UTF8String], [YZSettings searchEngine], address, sizeof address) != YOZORA_ADDRESS_URL) {
        [self showError:YZT(@"Этот адрес не поддерживается")];
        return;
    }
    NSString *url = [NSString stringWithUTF8String:address];
    NSString *title = yozora_address_host(address, host, sizeof host) ? [NSString stringWithUTF8String:host] : url;
    if (![_store addBookmarkWithURL:url title:title]) {
        [self showError:YZT(@"Не удалось добавить сайт")];
        return;
    }
    [self showHome];
    [_home relayoutAnimated];
}

#pragma mark bottom bar actions

- (void)backPressed {
    if (_core && !yozora_core_back(_core))
        [self showBanner:YZT(@"Назад перейти нельзя")];
}

- (void)forwardPressed {
    if (_core && !yozora_core_forward(_core))
        [self showBanner:YZT(@"Вперёд перейти нельзя")];
}

#pragma mark edge swipes

static const CGFloat YZEdgeKeySize = 44;

// UIScreenEdgePanGestureRecognizer exists from ios 7: older systems keep the keys of the bar
- (void)installEdgeSwipes {
    Class edge = NSClassFromString(@"UIScreenEdgePanGestureRecognizer");
    if (!edge)
        return;
    _edgeBack = [[edge alloc] initWithTarget:self action:@selector(edgeSwiped:)];
    _edgeForward = [[edge alloc] initWithTarget:self action:@selector(edgeSwiped:)];
    // UIRectEdgeLeft and UIRectEdgeRight
    [_edgeBack setValue:[NSNumber numberWithUnsignedInteger:1 << 1] forKey:@"edges"];
    [_edgeForward setValue:[NSNumber numberWithUnsignedInteger:1 << 3] forKey:@"edges"];
    for (UIPanGestureRecognizer *recognizer in [NSArray arrayWithObjects:_edgeBack, _edgeForward, nil]) {
        recognizer.delegate = self;
        [self.view addGestureRecognizer:recognizer];
    }
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (recognizer != _edgeBack && recognizer != _edgeForward)
        return YES;
    if (!_core || _editing || _pageEditing || [self findBarOpen] || !_tabsView.hidden || _menu || _controlSheet || _targetMenu || _filePicker
        || self.presentedViewController || [[self currentTab] isBlank])
        return NO;
    return recognizer == _edgeBack ? yozora_core_can_go_back(_core) != 0 : yozora_core_can_go_forward(_core) != 0;
}

// a drag on the page waits until the edge swipe has failed, which it does at once for a touch that did not start at the edge
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    return (recognizer == _edgeBack || recognizer == _edgeForward) && [other isKindOfClass:[UIPanGestureRecognizer class]]
        && other.view && [other.view isDescendantOfView:_pageView];
}

- (CGFloat)edgeThreshold {
    return MIN(self.view.bounds.size.width * 0.3f, (CGFloat)120);
}

- (void)placeEdgeKeyForPull:(CGFloat)pull back:(BOOL)back y:(CGFloat)y {
    CGFloat width = self.view.bounds.size.width;
    CGFloat progress = MIN((CGFloat)1, pull / [self edgeThreshold]);
    CGFloat reveal = progress * (YZEdgeKeySize + 12);
    _edgeKey.center = CGPointMake(back ? reveal - YZEdgeKeySize / 2 : width - reveal + YZEdgeKeySize / 2, y);
    _edgeKey.alpha = progress;
    CGFloat scale = 0.6f + 0.4f * progress;
    _edgeKey.transform = CGAffineTransformMakeScale(scale, scale);
}

- (void)setEdgeKeyArmed:(BOOL)armed {
    if (armed == _edgeArmed)
        return;
    _edgeArmed = armed;
    _edgeKey.backgroundColor = armed ? [YZTheme barHighlightColor] : [UIColor colorWithWhite:0.22f alpha:0.92f];
    if (armed && [YZTheme animationsEnabled]) {
        UIView *key = _edgeKey;
        CGAffineTransform rest = key.transform;
        [UIView animateWithDuration:0.1 animations:^{ key.transform = CGAffineTransformScale(rest, 1.15f, 1.15f); }
                         completion:^(BOOL finished) {
            (void)finished;
            [UIView animateWithDuration:0.12 animations:^{ key.transform = rest; }];
        }];
    }
}

- (void)endEdgeSwipe {
    [_edgeKey removeFromSuperview];
    [_edgeKey release];
    _edgeKey = nil;
    _edgeArmed = NO;
    _pageView.transform = CGAffineTransformIdentity;
    _pageView.alpha = 1;
    _pageView.layer.cornerRadius = 0;
    _pageView.layer.masksToBounds = _edgeClipped;
}

- (void)edgeSwiped:(UIPanGestureRecognizer *)gesture {
    BOOL back = gesture == _edgeBack;
    CGFloat direction = back ? 1 : -1;
    CGFloat width = self.view.bounds.size.width;
    CGFloat pull = MAX((CGFloat)0, direction * [gesture translationInView:self.view].x);
    CGFloat progress = MIN((CGFloat)1, pull / [self edgeThreshold]);
    switch (gesture.state) {
    case UIGestureRecognizerStateBegan: {
        if (_edgeKey)
            [self endEdgeSwipe];
        _edgeKey = [[UIView alloc] initWithFrame:CGRectMake(0, 0, YZEdgeKeySize, YZEdgeKeySize)];
        _edgeKey.userInteractionEnabled = NO;
        _edgeKey.layer.cornerRadius = YZEdgeKeySize / 2;
        _edgeKey.backgroundColor = [UIColor colorWithWhite:0.22f alpha:0.92f];
        _edgeKey.alpha = 0;
        UIImageView *arrow = [[UIImageView alloc] initWithImage:[YZTheme chromeIcon:(back ? YZIconBack : YZIconForward) size:24 color:[UIColor whiteColor]]];
        arrow.contentMode = UIViewContentModeCenter;
        arrow.frame = _edgeKey.bounds;
        [_edgeKey addSubview:arrow];
        [arrow release];
        [self.view addSubview:_edgeKey];
        _edgeClipped = _pageView.layer.masksToBounds;
        _pageView.layer.masksToBounds = YES;
        _edgeArmed = NO;
    }
        // fall through: the first change is part of the same gesture
    case UIGestureRecognizerStateChanged: {
        CGFloat shift = MIN(pull * 0.5f, (CGFloat)64);
        CGFloat scale = 1 - 0.05f * progress;
        _pageView.transform = CGAffineTransformScale(CGAffineTransformMakeTranslation(direction * shift, 0), scale, scale);
        _pageView.layer.cornerRadius = 20 * progress;
        [self placeEdgeKeyForPull:pull back:back y:[gesture locationInView:self.view].y];
        [self setEdgeKeyArmed:pull >= [self edgeThreshold]];
        break;
    }
    case UIGestureRecognizerStateEnded: {
        BOOL commit = pull >= [self edgeThreshold] || direction * [gesture velocityInView:self.view].x > 700;
        if (!commit) {
            [self cancelEdgeSwipe];
            break;
        }
        if (![YZTheme animationsEnabled]) {
            [self endEdgeSwipe];
            back ? [self backPressed] : [self forwardPressed];
            break;
        }
        // the page leaves on the side the finger pulled to, the next one comes from the other side
        [UIView animateWithDuration:0.14 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
            _pageView.transform = CGAffineTransformMakeTranslation(direction * width * 0.2f, 0);
            _pageView.alpha = 0;
            _edgeKey.alpha = 0;
        } completion:^(BOOL finished) {
            (void)finished;
            [self endEdgeSwipe];
            back ? [self backPressed] : [self forwardPressed];
            _pageView.transform = CGAffineTransformMakeTranslation(-direction * width * 0.06f, 0);
            _pageView.alpha = 0;
            [UIView animateWithDuration:0.24 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                _pageView.transform = CGAffineTransformIdentity;
                _pageView.alpha = 1;
            } completion:nil];
        }];
        break;
    }
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed:
        [self cancelEdgeSwipe];
        break;
    default:
        break;
    }
}

- (void)cancelEdgeSwipe {
    if (![YZTheme animationsEnabled]) {
        [self endEdgeSwipe];
        return;
    }
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        _pageView.transform = CGAffineTransformIdentity;
        _pageView.layer.cornerRadius = 0;
        _edgeKey.alpha = 0;
        _edgeKey.transform = CGAffineTransformMakeScale(0.6f, 0.6f);
    } completion:^(BOOL finished) {
        (void)finished;
        [self endEdgeSwipe];
    }];
}

#pragma mark edge color

// the colors the page has at the top and at the bottom of the screen, one on each line: the theme-color of the page for the top, else the
// first background that is not transparent from the element at the edge up to the root. an unknown color is an empty line
static NSString *const YZEdgeColorScript =
    @"(function(){function ok(c){return c&&c!=='transparent'&&!/^rgba\\(\\s*\\d+\\s*,\\s*\\d+\\s*,\\s*\\d+\\s*,\\s*0\\s*\\)$/.test(c);}"
    "function at(y){var e=document.elementFromPoint(Math.floor(innerWidth/2),y);while(e){var c=getComputedStyle(e).backgroundColor;if(ok(c))return c;e=e.parentElement;}return '';}"
    "var m=document.querySelector('meta[name=\"theme-color\"]');"
    "return ((m&&m.content)?m.content:at(1))+'\\n'+at(innerHeight-2);})()";

// rgb(), rgba() and hex forms, what a computed style and a theme-color give. a color that is mostly transparent is not one
static UIColor *YZColorFromCSS(NSString *text) {
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([text length] < 4 || [text length] > 64)
        return nil;
    if ([text hasPrefix:@"#"]) {
        NSString *hex = [text substringFromIndex:1];
        if ([hex length] == 3) {
            NSMutableString *wide = [NSMutableString string];
            for (NSUInteger i = 0; i < 3; ++i)
                [wide appendFormat:@"%C%C", [hex characterAtIndex:i], [hex characterAtIndex:i]];
            hex = wide;
        }
        uint8_t rgb[3];
        if ([hex length] != 6 || !yozora_color_parse_hex([[@"#" stringByAppendingString:hex] UTF8String], 7, rgb))
            return nil;
        return [UIColor colorWithRed:rgb[0] / 255.0f green:rgb[1] / 255.0f blue:rgb[2] / 255.0f alpha:1];
    }
    if (![text hasPrefix:@"rgb"])
        return nil;
    NSMutableArray *numbers = [NSMutableArray array];
    NSScanner *scanner = [NSScanner scannerWithString:text];
    [scanner scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:NULL];
    while (![scanner isAtEnd] && [numbers count] < 4) {
        double value;
        if (![scanner scanDouble:&value])
            break;
        [numbers addObject:[NSNumber numberWithDouble:value]];
        [scanner scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:NULL];
    }
    if ([numbers count] < 3)
        return nil;
    double alpha = [numbers count] > 3 ? [[numbers objectAtIndex:3] doubleValue] : 1;
    if (alpha < 0.5)
        return nil;
    return [UIColor colorWithRed:MIN(255.0, [[numbers objectAtIndex:0] doubleValue]) / 255.0f
                           green:MIN(255.0, [[numbers objectAtIndex:1] doubleValue]) / 255.0f
                            blue:MIN(255.0, [[numbers objectAtIndex:2] doubleValue]) / 255.0f alpha:1];
}

- (void)setEdgeColor:(UIColor *)top bottom:(UIColor *)bottom {
    BOOL same = (top == _edgeColor || (top && _edgeColor && [top isEqual:_edgeColor]))
        && (bottom == _edgeBottomColor || (bottom && _edgeBottomColor && [bottom isEqual:_edgeBottomColor]));
    if (same)
        return;
    NSLog(@"yozora: page edge colors top %@ bottom %@", top, bottom);
    [top retain];
    [_edgeColor release];
    _edgeColor = top;
    [bottom retain];
    [_edgeBottomColor release];
    _edgeBottomColor = bottom;
    [UIView animateWithDuration:[YZTheme animationsEnabled] ? 0.2 : 0 animations:^{ [self layoutChrome]; }];
    // the clock and the icons follow the page: dark over a light color, light over a dark one. ios before 13 take the style from the
    // application, later ones ask the controller
    [[UIApplication sharedApplication] setStatusBarStyle:[self preferredStatusBarStyle]];
    SEL update = NSSelectorFromString(@"setNeedsStatusBarAppearanceUpdate");
    if ([self respondsToSelector:update])
        [self performSelector:update];
}

// the page is asked after a load and a moment after the scroll stopped, a page is not asked while it moves
- (void)trackEdgeColorAtTime:(CFTimeInterval)now {
    // the start page is no site to ask: it says itself what stands at its edges, the surface, the gradient or the photo
    if (!_home.hidden && ![YZTheme isClassic]) {
        _edgeSampleDue = 0;
        [self setEdgeColor:_home.topEdgeColor bottom:_home.bottomEdgeColor];
        return;
    }
    if (!_core || [YZTheme isClassic] || [[self currentTab] isBlank]) {
        _edgeSampleDue = 0;
        [self setEdgeColor:nil bottom:nil];
        return;
    }
    int scroll = yozora_core_scroll_y(_core);
    if (scroll != _edgeScroll) {
        _edgeScroll = scroll;
        _edgeSampleDue = now + 0.35;
    }
    if (!_edgeSampleDue || now < _edgeSampleDue || _edgeSampling || yozora_core_state(_core) != YOZORA_LOAD_COMPLETE)
        return;
    _edgeSampleDue = 0;
    YZTab *tab = [[self currentTab] retain];
    if (!tab.translation) {
        [tab release];
        return;
    }
    _edgeSampling = YES;
    [tab.translation runScript:YZEdgeColorScript completion:^(NSString *answer) {
        _edgeSampling = NO;
        if (tab == [self currentTab] && _core && yozora_core_state(_core) == YOZORA_LOAD_COMPLETE)
        {
            NSArray *lines = [answer componentsSeparatedByString:@"\n"];
            UIColor *top = [lines count] > 0 ? YZColorFromCSS([lines objectAtIndex:0]) : nil;
            UIColor *bottom = [lines count] > 1 ? YZColorFromCSS([lines objectAtIndex:1]) : nil;
            [self setEdgeColor:top bottom:bottom];
        }
        [tab release];
    }];
}

- (void)reloadPressed {
    if (!_core)
        return;
    if (yozora_core_state(_core) == YOZORA_LOAD_LOADING)
        yozora_core_stop(_core);
    else if (!yozora_core_reload(_core))
        [self loadURL:[self currentURL]];
}

- (void)retryPagePressed {
    NSString *url = [[self currentURL] copy];
    [self loadURL:url];
    [url release];
}

- (void)starPressed {
    NSString *url = [self currentURL];
    if (![url length] || !_store)
        return;
    BOOL ok = [_store isBookmarked:url] ? [_store removeBookmarkWithURL:url]
                                        : [_store addBookmarkWithURL:url title:[[self currentTab] title]];
    if (!ok)
        [self showError:YZT(@"Не удалось сохранить в избранное")];
    else {
        // the star wobbles when a bookmark is made or removed
        [self updateChromeForced:YES];
        [YZTheme animateFeedbackOfView:_starButton.imageView];
        return;
    }
    [self updateChromeForced:YES];
}

- (void)sharePressed {
    [self shareText:[self currentURL] fromRect:_shareButton.bounds inView:_shareButton];
}

- (void)tabsPressed {
    [_input resignFirstResponder];
    [self captureCurrentTab];
    _tabsView.incognito = [YZSettings incognito];
    [_tabsView showTabs:_tabs selected:_current];
    // the tray only fades, its cards wobble in themselves. growing as a whole showed page strips at the sides
    [YZTheme setView:_tabsView shown:YES scale:1];
    [_tabsView present];
}

// the host without www so both spellings are one decision. a one label host (localhost) has no parent to
// match, so no entry
- (NSString *)adblockSite {
    NSString *url = [self currentURL];
    NSString *host = [url length] ? [[[NSURL URLWithString:url] host] lowercaseString] : nil;
    if ([host hasPrefix:@"www."])
        host = [host substringFromIndex:4];
    return [host rangeOfString:@"."].location == NSNotFound ? nil : host;
}

- (void)toggleAdblockForSite {
    NSString *site = [self adblockSite];
    if (!site || !_core)
        return;
    yozora_adblock_set_site_paused([site UTF8String], yozora_adblock_site_paused([site UTF8String]) ? 0 : 1);
    // the page loads again: what was blocked or hidden on it comes back, or goes
    if (!yozora_core_reload(_core))
        NSLog(@"yozora: the page could not be loaded again after the blocker changed for %@", site);
    [self showBanner:yozora_adblock_site_paused([site UTF8String]) ? YZT(@"Блокировщик выключен на этом сайте") : YZT(@"Блокировщик включён на этом сайте")];
}

- (void)menuPressed {
    [_input resignFirstResponder];
    if (_menu)
        return;
    BOOL blank = [[self currentTab] isBlank];
    BOOL incognito = [YZSettings incognito];
    NSMutableArray *items = [NSMutableArray array], *titles = [NSMutableArray array], *icons = [NSMutableArray array];
    void (^add)(YZMenuItem, NSString *, YZIcon) = ^(YZMenuItem item, NSString *title, YZIcon icon) {
        [items addObject:[NSNumber numberWithInt:item]];
        [titles addObject:title];
        [icons addObject:[NSNumber numberWithInt:icon]];
    };
    if (incognito) {
        add(YZMenuNewTab, YZT(@"Новая приватная вкладка"), YZIconPlus);
        add(YZMenuLeavePrivate, YZT(@"Выйти из инкогнито"), YZIconClose);
    } else {
        add(YZMenuNewTab, YZT(@"Новая вкладка"), YZIconPlus);
    }
    add(YZMenuBookmarks, YZT(@"Избранное"), YZIconBookmarks);
    // the history of the profile is not shown in the private session
    if (!incognito)
        add(YZMenuHistory, YZT(@"История"), YZIconHistory);
    add(YZMenuDownloads, YZT(@"Загрузки"), YZIconDownload);
    if (!blank) {
        // the flat and the floating bar have no star, the page is kept and dropped from the menu
        if ([YZTheme barKeepsStarInMenu]) {
            BOOL bookmarked = [_store isBookmarked:[self currentURL]];
            add(YZMenuBookmarkPage, bookmarked ? YZT(@"Убрать из избранного") : YZT(@"Добавить в избранное"), bookmarked ? YZIconStarFilled : YZIconStar);
        }
        add(YZMenuCopyAddress, YZT(@"Скопировать адрес"), YZIconCopy);
        if ([self canShare])
            add(YZMenuShare, YZT(@"Поделиться"), YZIconShare);
        add(YZMenuFindInPage, YZT(@"Найти на странице"), YZIconSearch);
        add(YZMenuTranslate, YZT(@"Перевести страницу"), YZIconTranslate);
        // the pause of a site is kept for the profile, the private session keeps nothing
        NSString *site = incognito || ![YZSettings blockTrackers] ? nil : [self adblockSite];
        if (site) {
            if (yozora_adblock_site_paused([site UTF8String]))
                add(YZMenuAdblock, YZT(@"Включить блокировщик на сайте"), YZIconShield);
            else
                add(YZMenuAdblock, [NSString stringWithFormat:@"%@: %u", YZT(@"Блокировщик на сайте"), _core ? yozora_core_blocked_on_page(_core) : 0u], YZIconShield);
        }
    }
    add(YZMenuSettings, YZT(@"Настройки"), YZIconSettings);
    _menu = [[YZMenuView alloc] initWithFrame:self.view.bounds];
    _menu.delegate = self;
    // the card stands on the bottom bar, above the menu button at its right end. with the menu button in the top row (a wide screen, the top layout)
    // it hangs from there
    BOOL hangs = [self isWide] || [self layoutAtTop];
    _menu.anchorsTop = hangs;
    _menu.topInset = [self chromeInsets].top + ([self isWide] ? YZTabStripHeight : 0) + [self barHeight] + 4;
    _menu.bottomInset = hangs ? [self chromeInsets].bottom + 4 : [self chromeInsets].bottom + [self bottomBlockHeight] + 4;
    _menu.rightInset = MAX((CGFloat)12, [self chromeInsets].right + 12);
    [_menu showItems:items titles:titles icons:icons];
    [self.view addSubview:_menu];
    [_menu present];
}

#pragma mark menu, tabs and lists

- (void)dismissMenu {
    // the field is released at once so a new menu can open, the old one slides away on its own
    YZMenuView *menu = _menu;
    _menu = nil;
    [menu dismissWithCompletion:^{
        [menu removeFromSuperview];
        [menu release];
    }];
}

- (void)menuViewDidDismiss:(YZMenuView *)view {
    (void)view;
    [self dismissMenu];
}

// the lists, the downloads and the settings stand as a card in the middle of an ipad, a column of 540 points. full width
// rows over a screen of 1024 points are a line the eye cannot follow. a phone has them over the whole screen
- (void)presentPanel:(YZPanelNavigationController *)navigation {
    if ([YZTheme isPad])
        navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)presentList:(YZListKind)kind {
    YZListController *list = [[YZListController alloc] initWithStore:_store kind:kind];
    list.listDelegate = self;
    YZPanelNavigationController *navigation = [[YZPanelNavigationController alloc] initWithRootViewController:list];
    [self presentPanel:navigation];
    [navigation release];
    [list release];
}

- (void)menuView:(YZMenuView *)view didSelectItem:(YZMenuItem)item {
    (void)view;
    [self dismissMenu];
    switch (item) {
    case YZMenuNewTab:
        [self addBlankTab];
        break;
    case YZMenuLeavePrivate:
        [self setIncognito:NO];
        [self endPrivateSessionIfEmpty];
        break;
    case YZMenuBookmarks:
        [self presentList:YZListBookmarks];
        break;
    case YZMenuHistory:
        [self presentList:YZListHistory];
        break;
    case YZMenuDownloads: {
        YZDownloadsController *downloads = [[YZDownloadsController alloc] init];
        downloads.downloadsDelegate = self;
        YZPanelNavigationController *navigation = [[YZPanelNavigationController alloc] initWithRootViewController:downloads];
        [self presentPanel:navigation];
        [navigation release];
        [downloads release];
        break;
    }
    case YZMenuCopyAddress:
        [self copyText:[self currentURL] banner:YZT(@"Адрес скопирован")];
        break;
    case YZMenuShare:
        [self shareText:[self currentURL] fromRect:_menuButton.bounds inView:_menuButton];
        break;
    case YZMenuBookmarkPage:
        [self starPressed];
        break;
    case YZMenuFindInPage:
        [self showFindBar];
        break;
    case YZMenuTranslate:
        [self presentTranslateSheet];
        break;
    case YZMenuAdblock:
        [self toggleAdblockForSite];
        break;
    case YZMenuSettings:
        [self presentSettings];
        break;
    }
}

// ios 13 and later ignore UIApplication setStatusBarStyle when the controller owns the status bar
// the start page of the modern design shows its ground under every bar: the bars and the skirt under the bottom one are clear while it is
// shown and take the color of the theme again when a site is
- (void)paintBarsOverHome:(BOOL)home force:(BOOL)force {
    BOOL over = home && [YZTheme isFloatingBar];
    if (over == _barsOverHome && !force)
        return;
    _barsOverHome = over;
    UIColor *clear = [UIColor clearColor];
    if (over) {
        [(YZSystemBarView *)_topBar setTop:clear bottom:clear];
        [(YZSystemBarView *)_bottomBar setTop:clear bottom:clear];
        [_bottomBar viewWithTag:YZBottomSkirtTag].backgroundColor = clear;
    } else if (!force) {
        [(YZSystemBarView *)_topBar applyTheme];
        [(YZSystemBarView *)_bottomBar applyTheme];
        [_bottomBar viewWithTag:YZBottomSkirtTag].backgroundColor = [YZTheme toolbarColor];
    }
    [self.view setNeedsLayout];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    if (_edgeColor && ([self layoutAtBottom] || _barsOverHome) && ![YZTheme isClassic]) {
        CGFloat red, green, blue, alpha;
        if ([_edgeColor getRed:&red green:&green blue:&blue alpha:&alpha])
            return YZStatusBarStyle(0.299f * red + 0.587f * green + 0.114f * blue <= 0.55f);
    }
    return [YZTheme statusBarStyle];
}

// every view that took a theme color or a text when it was built takes it again
- (void)applyTheme {
    [[UIApplication sharedApplication] setStatusBarStyle:[YZTheme statusBarStyle]];
    SEL update = NSSelectorFromString(@"setNeedsStatusBarAppearanceUpdate");
    if ([self respondsToSelector:update])
        [self performSelector:update];
    // a panel that is open (settings changing the theme) keeps its own status bar
    UIViewController *panel = self.presentedViewController;
    if ([panel isKindOfClass:[YZPanelNavigationController class]] && [panel respondsToSelector:update])
        [panel performSelector:update];
    self.view.window.backgroundColor = [YZTheme toolbarColor];
    self.view.backgroundColor = [YZTheme surfaceColor];
    [(YZSystemBarView *)_topBar applyTheme];
    [_findBar applyTheme];
    [_tabStrip applyTheme];
    [_tabStripSignature release];
    _tabStripSignature = nil;
    [self refreshTabStrip];
    [self.view setNeedsLayout];
    [(YZSystemBarView *)_bottomBar applyTheme];
    [_bottomBar viewWithTag:YZBottomSkirtTag].backgroundColor = [YZTheme toolbarColor];
    [self paintBarsOverHome:!_home.hidden force:YES];
    [self styleField];
    _progress.backgroundColor = [YZTheme barHighlightProgressColor];
    _banner.backgroundColor = [YZTheme cardColor];
    _banner.textColor = [YZTheme textColor];
    _input.textColor = [YZTheme fieldInkColor];
    YZSetPlaceholder(_input, YZT(@"Поиск или адрес"), [YZTheme fieldHintColor]);
    _input.accessibilityLabel = YZT(@"Адрес страницы");
    _input.keyboardAppearance = [YZTheme isDark] ? UIKeyboardAppearanceAlert : UIKeyboardAppearanceDefault;
    [_cancelButton setTitle:YZT(@"Отмена") forState:UIControlStateNormal];
    [self styleCancelButton];
    NSArray *buttons = [NSArray arrayWithObjects:_backButton, _forwardButton, _starButton, _shareButton, _tabsButton, _menuButton, nil];
    NSArray *labels = [NSArray arrayWithObjects:@"Назад", @"Вперёд", @"Избранное", @"Поделиться", @"Вкладки", @"Меню", nil];
    for (NSUInteger i = 0; i < [buttons count]; ++i) {
        UIButton *button = [buttons objectAtIndex:i];
        [self styleBarButton:button icon:(YZIcon)button.tag];
        button.accessibilityLabel = YZT([labels objectAtIndex:i]);
    }
    _suggestionsTable.backgroundColor = [YZTheme surfaceColor];
    _suggestionsTable.separatorStyle = UITableViewCellSeparatorStyleNone;
    _suggestionsTable.rowHeight = 62;
    [_suggestionsTable reloadData];
    [_home applyTheme];
    [_errorPage applyTheme];
    [_tabsView applyTheme];
    // the field and the bars take their corners and colors from the design in the next layout
    [self.view setNeedsLayout];
    [self updateChromeForced:YES];
}

- (YZSettingsController *)presentSettings {
    YZSettingsController *settings = [[[YZSettingsController alloc] initWithStore:_store] autorelease];
    settings.settingsDelegate = self;
    YZPanelNavigationController *navigation = [[YZPanelNavigationController alloc] initWithRootViewController:settings];
    navigation.view.backgroundColor = [YZTheme surfaceColor];
    [self presentPanel:navigation];
    [navigation release];
    return settings;
}

- (void)settingsControllerDidFinish:(YZSettingsController *)controller {
    (void)controller;
    [YZCrash note:@"settings: dismissed"];
    [self dismissViewControllerAnimated:YES completion:nil];
    [self updateChromeForced:YES];
}

// the theme, the language and the text size show on the screens that are open
- (void)settingsControllerDidChange:(YZSettingsController *)controller {
    (void)controller;
    [YZCrash note:@"settings: applying"];
    [self applyTheme];
    [YZCrash note:@"settings: theme applied"];
    [self applyDeveloperSettings];
    [YZCrash note:@"settings: developer applied"];
}

- (void)settingsController:(YZSettingsController *)controller openAddress:(NSString *)address {
    (void)controller;
    [self dismissViewControllerAnimated:YES completion:nil];
    [self openExternalURL:[NSURL URLWithString:address]];
}

- (void)checkForUpdate {
    [YZUpdate check:^(YZRelease *release, BOOL failed) {
        (void)failed;
        if ([YZUpdate isNewer:release])
            [YZUpdateCard presentInView:self.view openPage:^{ [self openExternalURL:[NSURL URLWithString:YZReleasePageAddress]]; }];
    }];
}

- (void)listController:(YZListController *)controller didSelectURL:(NSString *)url {
    (void)controller;
    [self dismissViewControllerAnimated:YES completion:nil];
    [self loadURL:url];
}

- (void)downloadsControllerDidFinish:(YZDownloadsController *)controller {
    (void)controller;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)listControllerDidFinish:(YZListController *)controller {
    (void)controller;
    [self dismissViewControllerAnimated:YES completion:nil];
    [self updateChromeForced:YES];
}

- (void)tabsView:(YZTabsView *)view didSelectIndex:(NSUInteger)index {
    (void)view;
    [YZTheme setView:_tabsView shown:NO scale:1];
    if (index != _current)
        [self switchToTab:index];
}

- (CGRect)tabsViewPageFrame:(YZTabsView *)view {
    (void)view;
    return [view convertRect:_pageView.frame fromView:self.view];
}

- (void)tabsView:(YZTabsView *)view didCloseIndex:(NSUInteger)index {
    (void)view;
    [self closeTabAtIndex:index];
}

- (void)tabsViewDidRequestNewTab:(YZTabsView *)view {
    (void)view;
    [self addBlankTab];
    // the flat stack brings the new page in and opens it, the others fade out as they did
    if (![_tabsView presentNewTab:_tabs selected:_current])
        [YZTheme setView:_tabsView shown:NO scale:1];
}

- (void)tabsView:(YZTabsView *)view didChooseIncognito:(BOOL)incognito {
    (void)view;
    [self setIncognito:incognito];
}

- (void)tabsViewDidFinish:(YZTabsView *)view {
    (void)view;
    [YZTheme setView:_tabsView shown:NO scale:1];
}

#pragma mark tab strip

- (void)tabStrip:(YZTabStrip *)strip didSelectIndex:(NSUInteger)index {
    (void)strip;
    if (index != _current)
        [self switchToTab:index];
}

- (void)tabStrip:(YZTabStrip *)strip didCloseIndex:(NSUInteger)index {
    (void)strip;
    [self closeTabAtIndex:index];
}

- (void)tabStripDidRequestNewTab:(YZTabStrip *)strip {
    (void)strip;
    [self addBlankTab];
}

#pragma mark find in page and the desktop site

- (BOOL)findBarOpen { return _findBar && !_findBar.hidden; }

- (void)showFindBar {
    if (!_core || [[self currentTab] isBlank])
        return;
    if (!_findBar) {
        _findBar = [[YZFindBar alloc] initWithFrame:CGRectZero];
        _findBar.delegate = self;
        _findBar.hidden = YES;
        [self.view insertSubview:_findBar aboveSubview:_topBar];
    }
    [_findBar showIndex:0 count:0 searching:NO];
    // the match is painted by the page as a selection, which would also grow handles and a menu
    _pageView.selectionHidden = YES;
    [self layoutChrome];
    [YZTheme setView:_findBar shown:YES scale:1];
    [_findBar focus];
}

- (void)closeFindBar {
    if (![self findBarOpen])
        return;
    [_findBar blur];
    if (_core)
        yozora_core_find_clear(_core);
    _pageView.selectionHidden = NO;
    [YZTheme setView:_findBar shown:NO scale:1];
    [self layoutChrome];
}

// called once for each display frame: the place of the current match comes from the core thread
- (void)updateFindState {
    if (![self findBarOpen] || !_core)
        return;
    yozora_find_state state;
    yozora_core_find_state(_core, &state);
    [_findBar showIndex:state.index count:state.count searching:state.active];
}

- (void)findBar:(YZFindBar *)bar didChangeText:(NSString *)text {
    if (!_core)
        return;
    if ([text length])
        yozora_core_find(_core, [text UTF8String], 0);
    else
        yozora_core_find_clear(_core);
    (void)bar;
}

- (void)findBar:(YZFindBar *)bar didStep:(int)direction {
    if (_core && [[bar text] length])
        yozora_core_find(_core, [[bar text] UTF8String], direction);
}

- (void)findBarDidClose:(YZFindBar *)bar {
    (void)bar;
    [self closeFindBar];
}

#pragma mark downloads in the chrome

// twice a second: draw the share of known size downloads over the bottom bar and announce one that ended. the
// list is readable from any thread
- (void)watchDownloadsAt:(CFTimeInterval)time {
    if (time - _downloadsPolled < 0.5)
        return;
    _downloadsPolled = time;
    if (!_watchedDownloads)
        _watchedDownloads = [[NSMutableSet alloc] init];
    yozora_download list[50];
    int count = yozora_downloads_list(list, 50);
    long long received = 0, total = 0;
    BOOL active = NO;
    NSMutableSet *now = [NSMutableSet set];
    NSUInteger activeCount = 0;
    for (int i = 0; i < count; ++i) {
        NSNumber *key = [NSNumber numberWithUnsignedInt:list[i].id];
        int state = list[i].state;
        if (state == YOZORA_DOWNLOAD_QUEUED || state == YOZORA_DOWNLOAD_RUNNING || state == YOZORA_DOWNLOAD_PAUSED) {
            active = YES;
            ++activeCount;
            [now addObject:key];
            if (list[i].total > 0) {
                received += MIN(list[i].received, list[i].total);
                total += list[i].total;
            }
        } else if ([_watchedDownloads containsObject:key]) {
            if (state == YOZORA_DOWNLOAD_DONE) {
                NSString *message = [NSString stringWithFormat:@"%@: %s", YZT(@"Загружено"), list[i].name];
                [self showBanner:message];
                // the page load that would clear a banner may be far away
                [self performSelector:@selector(clearBannerIfShowing:) withObject:message afterDelay:4];
            } else if (state == YOZORA_DOWNLOAD_FAILED) {
                [self showError:[NSString stringWithFormat:@"%@: %s", YZT(@"Не загружено"), list[i].name]];
            }
        }
    }
    // an entry that left the list while it was unfinished was forgotten or cancelled, nothing to announce
    [_watchedDownloads setSet:now];
    // spinner and icon number, the first download asks for the permission ios 8 needs for notifications while
    // hidden
    [YZSystemNotifier setActivity:active];
    [YZSystemNotifier setBadge:(NSInteger)activeCount];
    if (active)
        [YZSystemNotifier askPermission];
    if (!_downloadLine) {
        _downloadLine = [[UIView alloc] initWithFrame:CGRectZero];
        _downloadLine.hidden = YES;
    }
    _downloadLine.backgroundColor = [YZTheme barHighlightProgressColor];
    // a download of an unknown size has no share to show: a short stub says that something runs
    _downloadShare = total > 0 ? (CGFloat)received / (CGFloat)total : 0.04f;
    [self layoutDownloadLine];
    if (_downloadLine.hidden == active)
        [YZTheme setView:_downloadLine shown:active scale:1];
}

- (void)clearBannerIfShowing:(NSString *)text {
    if ([_shownBanner isEqualToString:text])
        [self showBanner:nil];
}

#pragma mark share and the sheet of a link

typedef enum {
    YZTargetOpenTab,
    YZTargetOpenPrivateTab,
    YZTargetCopyLink,
    YZTargetShareLink,
    YZTargetOpenImage,
    YZTargetCopyImage,
    YZTargetShareImage,
    YZTargetDownloadLink,
    YZTargetDownloadImage,
    YZTargetDownloadMedia,
    YZTargetCopyMedia
} YZTargetAction;

// the share sheet exists from ios 6, an older system gets no share entries at all
- (BOOL)canShare {
    return NSClassFromString(@"UIActivityViewController") != nil;
}

- (void)closeSharePopover {
    _sharePopover.delegate = nil;
    [_sharePopover dismissPopoverAnimated:NO];
    [_sharePopover release];
    _sharePopover = nil;
}

- (void)popoverControllerDidDismissPopover:(UIPopoverController *)popover {
    if (popover == _sharePopover)
        [self closeSharePopover];
}

// an address goes as NSURL so mail and messages make a link, text as a string. an ipad shows a popover at the
// source rect
- (void)shareText:(NSString *)text fromRect:(CGRect)rect inView:(UIView *)source {
    Class activityClass = NSClassFromString(@"UIActivityViewController");
    if (!activityClass || ![text length])
        return;
    BOOL address = [text hasPrefix:@"http://"] || [text hasPrefix:@"https://"];
    NSURL *url = address ? [NSURL URLWithString:text] : nil;
    NSArray *items = [NSArray arrayWithObject:url ? (id)url : (id)text];
    id activity = ((id (*)(id, SEL, id, id))objc_msgSend)([activityClass alloc], @selector(initWithActivityItems:applicationActivities:), items, nil);
    if (!activity)
        return;
    [activity autorelease];
    [_input resignFirstResponder];
    if ([YZTheme isPad] && NSClassFromString(@"UIPopoverController")) {
        [self closeSharePopover];
        _sharePopover = [[UIPopoverController alloc] initWithContentViewController:activity];
        _sharePopover.delegate = self;
        [_sharePopover presentPopoverFromRect:rect inView:source permittedArrowDirections:UIPopoverArrowDirectionAny animated:YES];
    } else {
        [self presentViewController:activity animated:YES completion:nil];
    }
}

- (void)pageView:(YZPageView *)view shareText:(NSString *)text fromRect:(CGRect)rect {
    [self shareText:text fromRect:rect inView:view];
}

// a short message that goes away by itself
- (void)showTransientBanner:(NSString *)text {
    [self showBanner:text];
    [self performSelector:@selector(clearBannerIfShowing:) withObject:text afterDelay:2];
}

- (void)copyText:(NSString *)text banner:(NSString *)banner {
    [UIPasteboard generalPasteboard].string = text;
    [self showTransientBanner:banner];
}

// a blank tab is reused, a full tray refuses with its own message, a private one switches the session first
// the address goes to a tab behind the page that is open: the page stays under the finger and more links of it can be held the same way. the tab has
// no core until it is chosen, then createCore loads its address. a private tab changes the session, which shows another set of tabs, so it opens
// in front as before
- (void)openURLInBackgroundTab:(NSString *)url {
    char address[YOZORA_URL_CAP], host[256];
    if (yozora_address_resolve([url UTF8String], [YZSettings searchEngine], address, sizeof address) != YOZORA_ADDRESS_URL) {
        [self showError:YZT(@"Этот адрес не поддерживается")];
        return;
    }
    if ([_tabs count] >= YZTabLimit) {
        [self showError:YZT(@"Открыто слишком много вкладок")];
        return;
    }
    YZTab *tab = [[[YZTab alloc] init] autorelease];
    tab.url = [NSString stringWithUTF8String:address];
    tab.title = yozora_address_host(address, host, sizeof host) ? [NSString stringWithUTF8String:host] : tab.url;
    tab.isPrivate = [YZSettings incognito];
    [_tabs addObject:tab];
    [self saveTabs];
    [self updateChromeForced:YES];
    [self showTransientBanner:YZT(@"Открыто в новой вкладке")];
}

- (void)openURLInNewTab:(NSString *)url private:(BOOL)private {
    if (!private) {
        [self openURLInBackgroundTab:url];
        return;
    }
    if (![YZSettings incognito]) {
        [self setIncognito:YES];
        if (![YZSettings incognito])
            return;
    }
    if (![[self currentTab] isBlank]) {
        NSUInteger before = [_tabs count];
        [self addBlankTab];
        if ([_tabs count] == before)
            return;
    }
    [self openAddressText:url];
}

// the menu of a long press on a link, an image or a video: it grows out of the finger and it closes with the
// page, like the page controls. the files go to the downloads list
- (void)presentTargetSheetForHit:(const yozora_hit *)hit {
    NSString *link = hit->link[0] ? [NSString stringWithUTF8String:hit->link] : nil;
    NSString *image = hit->image[0] ? [NSString stringWithUTF8String:hit->image] : nil;
    NSString *media = hit->media[0] ? [NSString stringWithUTF8String:hit->media] : nil;
    if (!link && !image && !media)
        return;
    BOOL share = [self canShare];
    NSMutableArray *actions = [NSMutableArray array], *texts = [NSMutableArray array], *icons = [NSMutableArray array];
    void (^add)(YZTargetAction, NSString *, YZIcon) = ^(YZTargetAction action, NSString *text, YZIcon icon) {
        [actions addObject:[NSNumber numberWithInt:action]];
        [texts addObject:text];
        [icons addObject:[NSNumber numberWithInt:icon]];
    };
    if (link) {
        add(YZTargetOpenTab, YZT(@"Открыть в новой вкладке"), YZIconTabNew);
        // inside the private session every tab is private already
        if (![YZSettings incognito])
            add(YZTargetOpenPrivateTab, YZT(@"Открыть в приватной вкладке"), YZIconIncognito);
        add(YZTargetDownloadLink, YZT(@"Скачать файл по ссылке"), YZIconDownload);
        add(YZTargetCopyLink, YZT(@"Скопировать ссылку"), YZIconLink);
        if (share)
            add(YZTargetShareLink, YZT(@"Поделиться ссылкой"), YZIconShare);
    }
    if (image) {
        add(YZTargetOpenImage, YZT(@"Открыть картинку в новой вкладке"), YZIconImage);
        add(YZTargetDownloadImage, YZT(@"Скачать картинку"), YZIconDownload);
        add(YZTargetCopyImage, YZT(@"Скопировать адрес картинки"), YZIconCopy);
        if (share)
            add(YZTargetShareImage, YZT(@"Поделиться адресом картинки"), YZIconShare);
    }
    if (media) {
        add(YZTargetDownloadMedia, YZT(@"Скачать видео"), YZIconDownload);
        add(YZTargetCopyMedia, YZT(@"Скопировать адрес видео"), YZIconCopy);
    }
    [_input resignFirstResponder];
    CGPoint touch = [_pageView convertPoint:[_pageView screenPointForViewportPoint:CGPointMake(hit->x, hit->y)] toView:self.view];
    CGRect place = CGRectMake(touch.x, touch.y, 1, 1);
    __block YZPopupMenu *menu = nil;
    menu = [[YZPopupMenu alloc] initWithTitles:texts icons:icons handler:^(NSInteger index) {
        if (_targetMenu == menu) {
            [_targetMenu release];
            _targetMenu = nil;
        }
        if (index < 0 || index >= (NSInteger)[actions count])
            return;
        switch ((YZTargetAction)[[actions objectAtIndex:index] intValue]) {
        case YZTargetOpenTab:
            [self openURLInNewTab:link private:NO];
            break;
        case YZTargetOpenPrivateTab:
            [self openURLInNewTab:link private:YES];
            break;
        case YZTargetCopyLink:
            [self copyText:link banner:YZT(@"Ссылка скопирована")];
            break;
        case YZTargetShareLink:
            [self shareText:link fromRect:place inView:self.view];
            break;
        case YZTargetOpenImage:
            [self openURLInNewTab:image private:NO];
            break;
        case YZTargetCopyImage:
            [self copyText:image banner:YZT(@"Адрес скопирован")];
            break;
        case YZTargetShareImage:
            [self shareText:image fromRect:place inView:self.view];
            break;
        case YZTargetDownloadLink:
            [self downloadAddress:link];
            break;
        case YZTargetDownloadImage:
            [self downloadAddress:image];
            break;
        case YZTargetDownloadMedia:
            [self downloadAddress:media];
            break;
        case YZTargetCopyMedia:
            [self copyText:media banner:YZT(@"Адрес скопирован")];
            break;
        }
    }];
    menu.bottomInset = [self chromeInsets].bottom + (_bottomBarShown ? [self bottomBlockHeight] : 0);
    _targetMenu = menu;
    [menu showInView:self.view anchor:touch];
}

// the core asks for the file with the page as referrer. the bottom bar shows its progress from the list
- (void)downloadAddress:(NSString *)address {
    if (!_core || ![address length])
        return;
    yozora_core_download(_core, [address UTF8String]);
    [self showTransientBanner:YZT(@"Загрузка началась")];
}

// an answer that arrives while another screen is up is dropped, a sheet for a press from seconds ago would
// surprise
- (void)watchLongPresses {
    yozora_hit hit;
    if (!_core || !yozora_core_take_hit(_core, &hit))
        return;
    if (_controlSheet || _targetMenu || _filePicker || _menu || self.presentedViewController || !_tabsView.hidden)
        return;
    [self presentTargetSheetForHit:&hit];
}

#pragma mark controls of the page

// questions of the core are answered by id. the sheet closes unanswered when the page goes, an id of a gone
// page does nothing
- (void)closePageControls {
    // the menu of a long press answers -1 and lets go of itself
    [_targetMenu dismissAnimated:NO];
    if (_controlSheet) {
        _controlSheet.onCancel = nil;
        _controlSheet.onDone = nil;
        [_controlSheet dismissAnimated:NO];
        [_controlSheet release];
        _controlSheet = nil;
    }
    if (_filePicker) {
        YZFilePicker *picker = _filePicker;
        _filePicker = nil;
        [picker cancel];
        [picker release];
    }
}

- (void)watchPageControls {
    // one question at a time, and none under another screen: the rest waits in the core
    if (!_core || _controlSheet || _targetMenu || _filePicker || _menu || self.presentedViewController || !_tabsView.hidden)
        return;
    yozora_core *core = _core;
    CGFloat inset = [self chromeInsets].bottom;
    // this runs every display frame and a list is 33 KB, so the buffer is made once, on the main thread only
    static yozora_choice *choice;
    if (!choice)
        choice = (yozora_choice *)malloc(sizeof(yozora_choice));
    if (choice && yozora_core_take_choice(core, choice)) {
        NSMutableArray *texts = [NSMutableArray array], *flags = [NSMutableArray array];
        for (int i = 0; i < choice->count; ++i) {
            [texts addObject:[NSString stringWithUTF8String:choice->items[i].text]];
            [flags addObject:[NSNumber numberWithInt:choice->items[i].flags]];
        }
        unsigned identifier = choice->id;
        int selected = choice->selected;
        if (choice->multiple) {
            // a list with several choices: the answer is every item that stays chosen
            _controlSheet = [[YZPickers presentMultipleChoicesInView:self.view title:nil texts:texts flags:flags bottomInset:inset
                                                          completion:^(NSIndexSet *chosen) {
                [_controlSheet release];
                _controlSheet = nil;
                int indexes[YOZORA_CHOICE_MAX];
                int count = chosen ? 0 : -1;
                for (NSUInteger index = [chosen firstIndex]; index != NSNotFound && count < YOZORA_CHOICE_MAX; index = [chosen indexGreaterThanIndex:index])
                    indexes[count++] = (int)index;
                yozora_core_choices_respond(core, identifier, indexes, count);
            }] retain];
            return;
        }
        _controlSheet = [[YZPickers presentChoicesInView:self.view title:nil texts:texts flags:flags selected:selected bottomInset:inset
                                              completion:^(NSInteger index) {
            [_controlSheet release];
            _controlSheet = nil;
            yozora_core_choice_respond(core, identifier, (int)index);
        }] retain];
        return;
    }
    yozora_file_request file;
    if (yozora_core_take_files(core, &file)) {
        unsigned identifier = file.id;
        // the completion tells an answer from a page that went away by comparing with the picker the controller holds
        __block YZFilePicker *picker = nil;
        picker = [[YZFilePicker alloc] initWithHost:self accept:[NSString stringWithUTF8String:file.accept] multiple:file.multiple != 0 bottomInset:inset
                                         completion:^(NSArray *paths) {
            if (_filePicker != picker)
                return;
            YZFilePicker *done = _filePicker;
            _filePicker = nil;
            const char *list[64];
            int count = 0;
            for (NSString *path in paths) {
                if (count < 64)
                    list[count++] = [path fileSystemRepresentation];
            }
            yozora_core_files_respond(core, identifier, list, count);
            [done release];
        }];
        _filePicker = picker;
        [picker present];
        return;
    }
    yozora_color_request color;
    if (yozora_core_take_color(core, &color)) {
        unsigned identifier = color.id;
        _controlSheet = [[YZPickers presentColorInView:self.view value:[NSString stringWithUTF8String:color.value] bottomInset:inset
                                            completion:^(NSString *hex) {
            [_controlSheet release];
            _controlSheet = nil;
            yozora_core_color_respond(core, identifier, [hex UTF8String]);
        }] retain];
        return;
    }
    yozora_date_request date;
    if (yozora_core_take_date(core, &date)) {
        unsigned identifier = date.id;
        _controlSheet = [[YZPickers presentDateInView:self.view type:[NSString stringWithUTF8String:date.type] value:[NSString stringWithUTF8String:date.value]
                                              minimum:date.minimum maximum:date.maximum step:date.step bottomInset:inset
                                           completion:^(NSString *value) {
            [_controlSheet release];
            _controlSheet = nil;
            yozora_core_date_respond(core, identifier, [value UTF8String]);
        }] retain];
    }
}

#pragma mark address field

- (void)setEditing:(BOOL)editing {
    _editing = editing;
    // ios draws the caret over the first letter of an empty field's placeholder
    YZSetPlaceholder(_input, editing ? nil : YZT(@"Поиск или адрес"), [YZTheme fieldHintColor]);
    _input.textAlignment = editing ? YZTextAlignmentLeft : YZTextAlignmentCenter;
    _reloadButton.hidden = editing || [[self currentTab] isBlank];
    if (editing)
        [self setBottomBarShown:YES animated:YES];
    [self updateTranslationAnimated:YES];
    [YZTheme setView:_cancelButton shown:editing scale:1];
    [YZTheme setView:_suggestionsTable shown:editing scale:1];
    // the address field narrows to make room for the cancel button
    [YZTheme animate:^{ [self layoutChrome]; } completion:nil];
}

- (void)textFieldDidBeginEditing:(UITextField *)field {
    [self setEditing:YES];
    field.text = [self currentURL] ? [self currentURL] : @"";
    // the whole address is selected so a typed address replaces it, after the keyboard has appeared
    if ([field.text length])
        [field performSelector:@selector(selectAll:) withObject:nil afterDelay:0.1];
    [self refreshSuggestions];
}

- (void)textFieldDidEndEditing:(UITextField *)field {
    (void)field;
    [self setEditing:NO];
    [self updateAddressDisplay];
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    NSString *text = field.text;
    [field resignFirstResponder];
    if ([text length])
        [self openAddressText:text];
    return YES;
}

- (void)cancelPressed {
    [_input resignFirstResponder];
}

#pragma mark voice

// a microphone drawn here: a capsule, the arc that holds it and a stem, in the thin line of the other keys of the field
static UIImage *YZMicImage(CGFloat size, UIColor *color) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0);
    CGFloat unit = size / 24, line = 2 * unit;
    [color setStroke];
    UIBezierPath *capsule = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(9 * unit, 3 * unit, 6 * unit, 11 * unit) cornerRadius:3 * unit];
    capsule.lineWidth = line;
    [capsule stroke];
    UIBezierPath *arc = [UIBezierPath bezierPathWithArcCenter:CGPointMake(12 * unit, 11 * unit) radius:7 * unit startAngle:0 endAngle:(CGFloat)M_PI clockwise:YES];
    arc.lineWidth = line;
    arc.lineCapStyle = kCGLineCapRound;
    [arc stroke];
    UIBezierPath *stem = [UIBezierPath bezierPath];
    [stem moveToPoint:CGPointMake(12 * unit, 18 * unit)];
    [stem addLineToPoint:CGPointMake(12 * unit, 21 * unit)];
    [stem moveToPoint:CGPointMake(8.5f * unit, 21 * unit)];
    [stem addLineToPoint:CGPointMake(15.5f * unit, 21 * unit)];
    stem.lineWidth = line;
    stem.lineCapStyle = kCGLineCapRound;
    [stem stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

// the key is the accent while the phone listens
- (void)paintMic:(BOOL)listening {
    [_micButton setImage:YZMicImage(22, listening ? [YZTheme accentColor] : [YZTheme fieldHintColor]) forState:UIControlStateNormal];
}

// a press listens and the words are put in the field as they come, the last version is the search. a second press ends the listening
- (void)micPressed {
    if (!_voice)
        _voice = [[YZVoiceInput alloc] init];
    if ([_voice isListening]) {
        [_voice stop];
        return;
    }
    [self paintMic:YES];
    [_voice startWithPartial:^(NSString *text, BOOL final) {
        _input.text = text;
        if (!final)
            return;
        [self paintMic:NO];
        [_input resignFirstResponder];
        [self openAddressText:text];
    } failed:^(NSString *reason) {
        [self paintMic:NO];
        [self showError:reason];
    }];
}

// suggestions wait for a pause in typing, rebuilding per key held the next key back on an old phone
- (void)inputChanged {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(refreshSuggestions) object:nil];
    [self performSelector:@selector(refreshSuggestions) withObject:nil afterDelay:0.06];
}

#pragma mark suggestions

- (BOOL)text:(NSString *)text matches:(NSString *)query {
    return [text rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound;
}

- (void)refreshSuggestions {
    NSString *query = [_input.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [_suggestions removeAllObjects];
    NSMutableSet *seen = [NSMutableSet set];
    char address[YOZORA_URL_CAP];
    if ([query length] && yozora_address_resolve([query UTF8String], [YZSettings searchEngine], address, sizeof address) != YOZORA_ADDRESS_INVALID) {
        YZRecord *typed = [[[YZRecord alloc] init] autorelease];
        typed.url = [NSString stringWithUTF8String:address];
        typed.title = [NSString stringWithFormat:YZT(@"Перейти или искать: %@"), query];
        [_suggestions addObject:typed];
        [seen addObject:typed.url];
    }
    NSMutableArray *sources = [NSMutableArray arrayWithArray:[_store bookmarks]];
    [sources addObjectsFromArray:[_store recentHistory]];
    for (YZRecord *record in sources) {
        if ([_suggestions count] > YZSuggestionLimit)
            break;
        if ([seen containsObject:record.url])
            continue;
        if ([query length] && ![self text:record.url matches:query] && ![self text:record.title matches:query])
            continue;
        [seen addObject:record.url];
        [_suggestions addObject:record];
    }
    [_suggestionsTable reloadData];
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    (void)table;
    (void)section;
    return [_suggestions count];
}

// the mark at the head of every suggestion, as Firefox has it: a magnifier on a tonal disc. drawn once for the colors of the theme in use
static UIImage *YZSuggestionMark(void) {
    static UIImage *mark;
    static NSString *markKey;
    UIColor *plate = [YZTheme stateColor], *ink = [YZTheme accentColor];
    NSString *key = [NSString stringWithFormat:@"%@|%@", plate, ink];
    if (mark && [key isEqualToString:markKey])
        return mark;
    CGFloat side = 36;
    UIImage *glyph = [YZTheme icon:YZIconSearch size:20 color:ink];
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, 0);
    [plate setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, side, side)] fill];
    [glyph drawInRect:CGRectMake((side - 20) / 2, (side - 20) / 2, 20, 20)];
    UIImage *drawn = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    [mark release];
    mark = [drawn retain];
    [markKey release];
    markKey = [key copy];
    return mark;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    static NSString *identifier = @"suggestion";
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier] autorelease];
        cell.textLabel.font = [YZTheme systemFontOfSize:15];
        cell.detailTextLabel.font = [YZTheme systemFontOfSize:12];
    }
    cell.backgroundColor = [YZTheme surfaceColor];
    [YZTheme styleSelectionOfCell:cell];
    cell.textLabel.textColor = [YZTheme textColor];
    cell.textLabel.backgroundColor = [UIColor clearColor];
    cell.detailTextLabel.textColor = [YZTheme subtleTextColor];
    cell.detailTextLabel.backgroundColor = [UIColor clearColor];
    YZRecord *record = [_suggestions objectAtIndex:path.row];
    cell.textLabel.text = [record displayTitle];
    cell.detailTextLabel.text = record.url;
    cell.imageView.image = YZSuggestionMark();
    return cell;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:NO];
    NSString *url = [[(YZRecord *)[_suggestions objectAtIndex:path.row] url] retain];
    [_input resignFirstResponder];
    [self loadURL:url];
    [url release];
}

#pragma mark system

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return YZRootOrientation();
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    (void)orientation;
    return YES;
}

// ios 5 launched in landscape keeps the launch orientation for the status bar and keyboard after the browser replaces the splash
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if ([UIViewController instancesRespondToSelector:NSSelectorFromString(@"preferredInterfaceOrientationForPresentation")])
        return;
    UIApplication *application = [UIApplication sharedApplication];
    UIInterfaceOrientation shown = (UIInterfaceOrientation)[[self valueForKey:@"interfaceOrientation"] integerValue];
    if (shown == application.statusBarOrientation)
        return;
    NSLog(@"yozora: the application is in orientation %d and the screen in %d, the application follows the screen", (int)application.statusBarOrientation, (int)shown);
    [application setStatusBarOrientation:shown animated:NO];
}

- (void)didRotateFromInterfaceOrientation:(UIInterfaceOrientation)orientation {
    (void)orientation;
    [_tabsView setNeedsLayout];
    [self updateChromeForced:YES];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    [YZCrash note:@"memory warning"];
    NSLog(@"yozora: memory warning");
    _memoryWarningTime = CACurrentMediaTime();
    for (NSUInteger i = 0; i < [_tabs count]; ++i) {
        YZTab *tab = [_tabs objectAtIndex:i];
        [tab discardSuspendedCore];
        // the stored preview of a tab is read again when the tray shows it, a private one has none and goes for good
        if (i != _current)
            [tab dropThumbnailFromMemory];
    }
    for (YZTab *tab in _otherTabs) {
        [tab discardSuspendedCore];
        [tab dropThumbnailFromMemory];
    }
    [_tabsView refreshThumbnails];
    if (_core) {
        yozora_release_memory_async();
    }
}

#pragma mark the jit question

// the jit is chosen while JavaScriptCore starts, before any screen exists, so the answer counts at the next launch.
// the arm64 jit has not run on a device: it is asked about once and a start that died turns it off by itself
- (void)offerJit {
    if (_jitDialog)
        return;
    __block YZBrowserController *me = self;
    if ([YZSettings jitStartMarkUnavailable]) {
        _jitDialog = [[YZDialog dialogWithTitle:YZT(@"JIT выключен") message:YZT(@"Не удалось сохранить защиту запуска JIT. В этом запуске используется интерпретатор.")
                                    cancelTitle:nil confirmTitle:YZT(@"Понятно") destructive:NO handler:^(NSInteger index, NSArray *texts) {
            (void)index; (void)texts;
            [me->_jitDialog release];
            me->_jitDialog = nil;
        }] retain];
        [_jitDialog showInView:self.view];
        return;
    }
    if ([YZSettings jitDisabledAfterFailedStart]) {
        _jitDialog = [[YZDialog dialogWithTitle:YZT(@"JIT выключен") message:YZT(@"Прошлый запуск с JIT оборвался, поэтому он выключен. Включить его снова можно в настройках разработчика.")
                                    cancelTitle:nil confirmTitle:YZT(@"Понятно") destructive:NO handler:^(NSInteger index, NSArray *texts) {
            (void)index; (void)texts;
            [me->_jitDialog release];
            me->_jitDialog = nil;
        }] retain];
        [_jitDialog showInView:self.view];
        return;
    }
#if defined(__arm64__)
    if ([YZSettings jitAnswered])
        return;
    _jitDialog = [[YZDialog dialogWithTitle:YZT(@"Включить JIT?")
                                    message:YZT(@"JIT ускоряет сайты с тяжёлым JavaScript. На некоторых версиях iOS с ним возникают трудности и запуск может оборваться: тогда при следующем запуске он выключится сам. Выбор вступит в силу после перезапуска приложения.")
                                cancelTitle:YZT(@"Не включать") confirmTitle:YZT(@"Включить") destructive:NO handler:^(NSInteger index, NSArray *texts) {
        (void)texts;
        [me->_jitDialog release];
        me->_jitDialog = nil;
        [YZSettings setJit:index != 0];
        if (index != 0)
            [me showTransientBanner:YZT(@"JIT включится после перезапуска")];
    }] retain];
    [_jitDialog showInView:self.view];
#endif
}

- (void)dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [_edgeColor release];
    [_edgeBottomColor release];
    [_footStrip release];
    _edgeBack.delegate = nil;
    _edgeForward.delegate = nil;
    [_edgeBack release];
    [_edgeForward release];
    [_edgeKey release];
    [self closePageControls];
    [self closeSharePopover];
    _findBar.delegate = nil;
    [_findBar release];
    [_downloadLine release];
    [_watchedDownloads release];
    _tabStrip.delegate = nil;
    [_tabStrip release];
    [_tabStripSignature release];
    [_authAlert dismissSilently];
    [_authAlert release];
    [_signInDialog dismissSilently];
    [_signInDialog release];
    [_jitDialog dismissSilently];
    [_jitDialog release];
    [_addSiteDialog dismissSilently];
    [_addSiteDialog release];
    [_backgroundEditor release];
    [_signIn release];
    [_geoAlert dismissSilently];
    [_geoAlert release];
    [_notificationAlert dismissSilently];
    [_notificationAlert release];
    [_videoController shutDown];
    _videoController.delegate = nil;
    [_videoController release];
    if (_popupController)
        _popupController->_popupOwner = nil;
    [_popupController release];
    if (_initialPopupCore)
        yozora_core_destroy(_initialPopupCore);
    if (_saveQueue) {
        dispatch_sync(_saveQueue, ^{ });
        dispatch_release(_saveQueue);
    }
    [_store flush];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_link invalidate];
    if (_linkTarget)
        ((YZCoreLinkTarget *)_linkTarget)->controller = nil;
    [_link release];
    [_linkTarget release];
    _input.delegate = nil;
    _suggestionsTable.dataSource = nil;
    _suggestionsTable.delegate = nil;
    [self destroyCore];
    [_topBar release];
    [_progress release];
    [_field release];
    [_securityView release];
    [_input release];
    [_reloadButton release];
    [_micButton release];
    [_voice release];
    [_cancelButton release];
    [_bottomBar release];
    [_backButton release];
    [_forwardButton release];
    [_starButton release];
    [_shareButton release];
    [_tabsButton release];
    [_menuButton release];
    [_pageView release];
    [_home release];
    [_errorPage release];
    [_banner release];
    [_errorPopup release];
    [_translateCloses release];
    [_debugOverlay release];
    [_suggestionsTable release];
    [_tabsView release];
    [_menu release];
    [_suggestions release];
    [_shownURL release];
    [_shownTitle release];
    [_shownBanner release];
    [_geoAlert release];
    [_notificationAlert release];
    [_notificationText release];
    [_location release];
    [_tabs release];
    [_otherTabs release];
    [_store release];
    [super dealloc];
}
@end
