#import <UIKit/UIKit.h>
#import "YZSettings.h"

typedef enum {
    YZIconBack,
    YZIconForward,
    YZIconChevron,
    YZIconReload,
    YZIconStop,
    YZIconMenu,
    YZIconLock,
    YZIconSearch,
    YZIconStar,
    YZIconStarFilled,
    YZIconPlus,
    YZIconClose,
    YZIconBookmarks,
    YZIconHistory,
    YZIconTabs,
    YZIconShield,
    YZIconSettings,
    YZIconPlay,
    YZIconPause,
    YZIconDownload,
    YZIconIncognito,
    YZIconCopy,
    YZIconCheck,
    YZIconDelete,
    YZIconLanguage,
    YZIconPalette,
    YZIconTextSize,
    YZIconCookie,
    YZIconSweep,
    YZIconCode,
    YZIconSpeed,
    YZIconAnimation,
    YZIconFont,
    YZIconInfo,
    YZIconDesktop,
    YZIconArrowUp,
    YZIconArrowDown,
    YZIconShare,
    YZIconTabNew,
    YZIconImage,
    YZIconLink,
    YZIconTranslate,
    YZIconSwap,
    YZIconHardware,
    YZIconBugReport,
    YZIconTerminal,
    YZIconReceiptLong,
    YZIconBolt,
    YZIconMemory,
    YZIconBrush
} YZIcon;

@interface YZTheme : NSObject
/* the classic design is on: lit glossy surfaces, an accent colored bar, small corners */
+ (BOOL)isClassic;
/* the flat design: the white bars of Safari on ios 7 with a gray field and the accent on the glyphs */
+ (BOOL)isFlat;
/* the floating bar: the bars of the modern design. they take the color of the page ground and the address stands in a white pill that casts a soft
   shadow */
+ (BOOL)isFloatingBar;
/* the places of the floating bar on a phone (see YZBarLayout): one bar at the foot with the address over the keys, or one row at the top */
+ (BOOL)barAtBottom;
+ (BOOL)barAtTop;
/* the bars that have no star key, the flat design and the floating bar: the page is kept and dropped from the menu */
+ (BOOL)barKeepsStarInMenu;
+ (UIColor *)addressFieldColor;
/* the ground of the start page in the classic design: white linen on the light theme, black linen on the dark ones, a
   tile that repeats. the modern design keeps the flat surface color */
+ (UIColor *)linenColor;
/* the ground of a screen with nothing on it but rows or a note: linen in the classic design, the surface color in the modern one */
+ (UIColor *)screenColor;
/* a soft round glow of the color, made once and kept: a shadow cast by the contour of a picture is drawn again by the render server whenever
   anything near it moves, a finished picture is only composed */
+ (UIImage *)glowImageWithColor:(UIColor *)color;
/* the text and the hint in the address field and the find field: the classic field is pale on every theme, so its ink is dark there */
+ (UIColor *)fieldInkColor;
+ (UIColor *)fieldHintColor;
/* the accent for a glyph that stands on that field */
+ (UIColor *)fieldAccentColor;
/* how far a screen's content has to reach under its navigation bar: the bar's height over a transparent bar of the modern design, nothing under the
   opaque bar of the classic one, which the system already lays the content below */
+ (CGFloat)barOverlap:(UINavigationBar *)bar;
/* the ink of what stands on a bar (the top and bottom bars, the find bar, the tab strip): white in the classic design,
   the text color in the modern one */
+ (UIColor *)barInkColor;
+ (UIColor *)barSubtleInkColor;
/* a glyph for a bar: the plain icon in the modern design, white with a dark stamp under it in the classic one */
+ (UIImage *)barIcon:(YZIcon)icon size:(CGFloat)size disabled:(BOOL)disabled;
/* the tab counter for a bar, the same way */
+ (UIImage *)barTabsIconWithCount:(NSUInteger)count size:(CGFloat)size;
/* what stands out on a bar: the accent in the modern design, which the accent bar of the classic one would swallow, a gold */
+ (UIColor *)barHighlightColor;
/* the load progress and the download line on a bar: the accent in the modern design, a light line on the accent bar of the classic one */
+ (UIColor *)barHighlightProgressColor;
/* the fill of a pressed row or card: the field color in the modern design, a darker grey in the classic one */
+ (UIColor *)pressedColor;
+ (UIColor *)toolbarColor;
+ (UIColor *)fieldColor;
+ (UIColor *)textColor;
+ (UIColor *)subtleTextColor;
+ (UIColor *)accentColor;
+ (UIColor *)separatorColor;
+ (UIColor *)backdropColor;
/* the ground of a page or a list: white in the light theme */
+ (UIColor *)surfaceColor;
+ (UIColor *)errorColor;
/* the pill behind a pressed or selected control */
+ (UIColor *)stateColor;
/* the container of a row in the settings, a little off the surface it lies on */
+ (UIColor *)cardColor;
/* a message that is an error: the container and the text on it */
+ (UIColor *)errorContainerColor;
+ (UIColor *)onErrorContainerColor;
/* the strip under the status bar, whose text is always light */
+ (UIColor *)statusStripColor;
/* what dims the page under a sheet */
+ (UIColor *)scrimColor;
/* the corners of Material 3: cards of the tab tray, tiles of the home page, the top of a sheet */
+ (CGFloat)cardRadius;
+ (CGFloat)tileRadius;
+ (CGFloat)sheetRadius;
/* the private session is on: the palette is purple and every theme is dark */
+ (BOOL)isIncognito;
/* shows the private palette whatever the session is, for the screen where its accent is chosen. set before
   the screen draws, put back when it leaves */
+ (void)setPrivatePalettePreview:(BOOL)on;
+ (BOOL)isPad;
/* the toolbars and lists of the chosen theme are dark: the status bar and keyboards follow */
/* interface text follows Settings > Text size a little less than pages do: rows and bars have a fixed height,
   so the scale stops at 1.3 and 0.85. a long lived view keeps its font until it asks again */
+ (CGFloat)textScale;
+ (UIFont *)systemFontOfSize:(CGFloat)size;
+ (UIFont *)boldSystemFontOfSize:(CGFloat)size;
+ (BOOL)isDark;
+ (UIStatusBarStyle)statusBarStyle;
/* the bar of a sheet takes the toolbar color and a title in the text color */
+ (void)styleNavigationBar:(UINavigationBar *)bar;
/* the same with nothing behind the buttons, the content shows through and the screen lays a fill behind the
   bar itself */
+ (void)styleTransparentNavigationBar:(UINavigationBar *)bar;
+ (void)styleSelectionOfCell:(UITableViewCell *)cell;
/* the large title above the rows of a screen, which scrolls away with them */
+ (UIView *)titleHeaderWithText:(NSString *)text width:(CGFloat)width;
/* a bar button that is a plain word in the accent color, the system buttons take a tint of the bar */
+ (UIBarButtonItem *)barButtonItemWithTitle:(NSString *)title bold:(BOOL)bold target:(id)target action:(SEL)action;
/* the chevron at the end of a row that opens another list */
+ (UIImageView *)disclosureView;
/* a square template icon drawn at the screen scale, cached by kind, size and color */
+ (UIImage *)icon:(YZIcon)icon size:(CGFloat)size color:(UIColor *)color;
/* a glyph of the bars and the address field: the thin outline of ios 7 in the flat design where one is drawn (back, forward, share,
   menu, close, plus, search, lock, star, bookmarks, the find arrows), the mask of the bundle elsewhere */
+ (UIImage *)chromeIcon:(YZIcon)icon size:(CGFloat)size color:(UIColor *)color;
/* the tab counter is a rounded square with the number inside */
+ (UIImage *)tabsIconWithCount:(NSUInteger)count size:(CGFloat)size color:(UIColor *)color;
/* a colored mark of a search engine (@"google", @"duckduckgo"), drawn as it is and not tinted, nil when the file is missing */
+ (UIImage *)logoNamed:(NSString *)name;
/* the app name in Metropolis Bold, the face of the Firefox wordmark, as a tinted picture of the given height */
+ (UIImage *)wordmarkWithHeight:(CGFloat)height color:(UIColor *)color;
/* the picture of the chosen mascot for a place: @"hero" (start page and splash), @"sticker" (about) or @"error" */
+ (UIImage *)mascotImage:(NSString *)place;
/* the same for a mascot that is not the chosen one, for the picker */
+ (UIImage *)mascotImage:(NSString *)place mascot:(YZMascot)mascot;
/* a stable pastel color for a site tile, from its host */
+ (UIColor *)tileColorForHost:(NSString *)host;
/* the interface animations of the chrome: they finish at once when the system asks for reduced motion (ios 8 and later) */
+ (BOOL)animationsEnabled;
+ (void)animate:(void (^)(void))animations completion:(void (^)(BOOL finished))completion;
/* bounded layer animations leave layout and touch handling unchanged */
+ (void)animateEntranceOfView:(UIView *)view offset:(CGPoint)offset delay:(NSTimeInterval)delay;
/* a picture stretched over a plain view through its layer: the corners of `caps` points keep their size and the middle
   takes the rest. a stretchable picture in a UIImageView is pretiled by UIKit into a cache of its own, and on ios 6 that
   cache kept freed keys (the zombie run named _UIImageViewPretiledImageCacheKey) and the app stopped in the next
   pool, so no picture of this kind goes into an image view */
+ (void)stretchImage:(UIImage *)image caps:(CGFloat)caps onView:(UIView *)view;
+ (void)animateFeedbackOfView:(UIView *)view;
/* a view that fades in or out, hidden is set once it is gone, a scale below 1 makes it grow into place or shrink away */
+ (void)setView:(UIView *)view shown:(BOOL)shown scale:(CGFloat)scale;
@end
