#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "YZHomeView.h"
#import "YZHomeBackgroundEditor.h"
#import "YZHomeElementsEditor.h"
#import "YZVoiceInput.h"
#import "YZListController.h"
#import "YZMenuView.h"
#import "YZPopupMenu.h"
#import "YZPageView.h"
#import "YZSettingsController.h"
#import "YZStore.h"
#import "YZTabsView.h"
#import "YZTabStrip.h"
#import "YZVideoController.h"
#import "YZDownloadsController.h"
#import "YZFindBar.h"
#import "YZSheets.h"
#import "YZErrorPopup.h"
#import "YZErrorPage.h"
#import "YZDialog.h"
#import "YZDebugOverlay.h"
#import "YZTranslateBar.h"
#import "YZTranslateSheet.h"
#import "YZTranslation.h"
#import "YZLocation.h"
#import "YZSignIn.h"
#import "YZTab.h"
#include "yozora_core.h"

@interface YZBrowserController : UIViewController <UITextFieldDelegate, UITableViewDataSource, UITableViewDelegate,
                                                   YZPageViewDelegate, YZHomeViewDelegate,
                                                   YZTabsViewDelegate, YZMenuViewDelegate, YZListControllerDelegate,
                                                   YZSettingsControllerDelegate, YZVideoControllerDelegate, YZDownloadsControllerDelegate, YZFindBarDelegate, YZTabStripDelegate, UIPopoverControllerDelegate, YZTranslationDelegate, YZTranslateBarDelegate, UIGestureRecognizerDelegate> {
    YZStore *_store;
    // the shown tabs and the open one, the other mode's tabs wait in _otherTabs
    NSMutableArray *_tabs;
    NSUInteger _current;
    NSMutableArray *_otherTabs;
    NSUInteger _otherCurrent;
    yozora_core *_core;
    yozora_core *_initialPopupCore;
    YZBrowserController *_popupController;
    YZBrowserController *_popupOwner;
    // the player of a video or audio of the page, there is at most one
    YZVideoController *_videoController;
    // the player that is sliding away: its picture is still in the full screen view, the page must not take it yet
    unsigned _leavingVideoID;
    NSMutableDictionary *_mediaPlayers;
    BOOL _popupMode;
    // the question for a name and a password that a site asked, and the number the core gave it
    YZDialog *_authAlert;
    unsigned _authID;
    // a sign in another app asked for: the question the person is asked, then the request and its private tab
    YZDialog *_signInDialog;
    // the question about the jit, asked once, and the notice that a failed start turned it off
    YZDialog *_jitDialog;
    // the question of the plus tile of the start page: the address of a site to keep there
    YZDialog *_addSiteDialog;
    // the controls of the photo behind the start page while they stand on it
    YZHomeBackgroundEditor *_backgroundEditor;
    YZHomeElementsEditor *_elementsEditor;
    YZSignIn *_signIn;
    YZTab *_signInTab;
    // the sign in switched to the private tabs, so it switches back when it ends
    BOOL _signInLeavesPrivate;
    // a page asks where the device is: the question of the person, and the location manager that runs while a page watches
    YZDialog *_geoAlert;
    // the question of a page that wants to show notifications, and the text of the notification that is on the banner now
    YZDialog *_notificationAlert;
    NSString *_notificationText;
    YZLocation *_location;
    // when the system asked for memory last
    CFTimeInterval _memoryWarningTime;
    CADisplayLink *_link;
    id _linkTarget;
    BOOL _hasFrame;
    CFTimeInterval _lastSceneTime;
    int _restoreScroll;
    // when a finished page is photographed for the preview of its tab, and the load state the last frame saw
    CFTimeInterval _thumbnailDue;
    int _lastLoadState;
    // the bottom bar leaves while the page is read down and returns on the way up, the page grows before it
    // leaves and shrinks after it arrives
    BOOL _bottomBarShown;
    // the page starts under the address bar. false while the bar has left with the hide on scroll setting
    BOOL _pageReservesTop;
    BOOL _pageReservesBar;
    BOOL _barLeaving;
    CFTimeInterval _barLeaveDeadline;
    yozora_core *_scrollCore;
    int _lastScrollY;
    int _scrollTravel;

    UIView *_topBar;
    UIView *_progress;
    UIView *_field;
    UIImageView *_securityView;
    UITextField *_input;
    UIButton *_reloadButton;
    // dictation in the address field, shown on a blank page and while the address is edited when the system can recognize speech
    UIButton *_micButton;
    YZVoiceInput *_voice;
    BOOL _voiceKnown;
    BOOL _voiceAvailable;
    UIButton *_cancelButton;
    UIView *_bottomBar;
    UIButton *_backButton;
    UIButton *_forwardButton;
    UIButton *_starButton;
    UIButton *_shareButton;
    UIButton *_tabsButton;
    UIButton *_menuButton;
    YZPageView *_pageView;
    YZHomeView *_home;
    YZErrorPage *_errorPage;
    UILabel *_banner;
    // the card of the last error, kept while it is on screen
    YZErrorPopup *_errorPopup;
    // the numbers of the process in a corner, made when the debug setting is on
    YZDebugOverlay *_debugOverlay;
    // page translation: the card at the bottom of the page, the button in the address field, and what the card was last told to hide
    YZTranslateBar *_translateBar;
    BOOL _translateBarShown;
    int _translateBarDismissedPhase;
    // close times of the translate offer, three in ten minutes stop it coming by itself
    NSMutableArray *_translateCloses;
    // find in page replaces the top bar while it is open
    YZFindBar *_findBar;
    // the sheet of a list or a date field of the page, and the picker of a file field: at most one of them is open
    YZSheet *_controlSheet;
    YZFilePicker *_filePicker;
    // the menu of a long press on a link, an image or a video
    YZPopupMenu *_targetMenu;
    // the share sheet of an ipad, which the system dismisses without a word when an activity is chosen
    UIPopoverController *_sharePopover;
    // a line on the bottom bar for download progress, and the downloads already announced
    UIView *_downloadLine;
    CGFloat _downloadShare;
    // the strip is redrawn only when its signature changes
    YZTabStrip *_tabStrip;
    NSString *_tabStripSignature;
    NSMutableSet *_watchedDownloads;
    CFTimeInterval _downloadsPolled;
    UITableView *_suggestionsTable;
    YZTabsView *_tabsView;
    YZMenuView *_menu;
    NSMutableArray *_suggestions;
    CGFloat _keyboardHeight;
    BOOL _editing;
    // a field of the page has the keyboard, which can lag behind isFirstResponder inside the show notification
    BOOL _pageEditing;
    // swipes from the side edges: back from the left one, forward from the right one (ios 7 and later). the page follows the finger
    // and a round key with the arrow grows at the edge until the pull is long enough
    UIPanGestureRecognizer *_edgeBack;
    UIPanGestureRecognizer *_edgeForward;
    UIView *_edgeKey;
    BOOL _edgeArmed;
    BOOL _edgeClipped;
    // the color of the page at the top of the screen, which the strip behind the notch takes in the bottom layout as it does in Safari
    UIColor *_edgeColor;
    // the same at the bottom edge, the strip over the home indicator takes it
    UIColor *_edgeBottomColor;
    UIView *_footStrip;
    // the start page is shown in the modern design: its ground fills the screen and the bars and strips over it are clear
    BOOL _barsOverHome;
    int _edgeScroll;
    CFTimeInterval _edgeSampleDue;
    BOOL _edgeSampling;
    dispatch_queue_t _saveQueue;

    // what the chrome currently shows, so a frame only touches views whose value changed
    NSString *_shownURL;
    NSString *_shownTitle;
    NSString *_shownBanner;
    int _shownState;
    int _shownProgress;
    int _shownTabCount;
    BOOL _shownBack;
    BOOL _shownForward;
    BOOL _shownSecure;
    BOOL _shownBookmarked;
    BOOL _shownBlank;
}
- (void)pumpCore:(CADisplayLink *)link;
- (void)noteDisplayFrame;
/* the tab list is written on a background queue, the call returns at once */
- (void)saveTabs;
/* writes the open tabs and the queued history rows and waits for the disk, for the moment the app leaves the foreground */
- (void)saveTabsAndWait;
/* a link another app handed over: only http and https, opened in the blank tab or in a new one. returns NO for anything else */
- (BOOL)openExternalURL:(NSURL *)url;
/* asks for the latest release and, when it is newer than this one, puts the update card over the page. every launch */
- (void)checkForUpdate;
/* asks about the jit once, or says that a failed start turned it off. the answer counts at the next launch */
- (void)offerJit;
@end
