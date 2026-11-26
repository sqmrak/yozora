#import <Foundation/Foundation.h>
#include "yozora_accent.h"
#include "yozora_address.h"
#include "yozora_core.h"
#include "yozora_dns.h"

typedef enum {
    YZLanguageRussian,
    YZLanguageEnglish,
    YZLanguageJapanese
} YZLanguage;

/* the picture that stands for the app on the start page, the about screen and the error screens */
typedef enum {
    YZMascotSan,
    YZMascotFox,
    YZMascotSenko
} YZMascot;

/* the drawing of the interface: Material cards and pills, the bars and controls the system of ios 5 to 7 draws itself, or
   the flat bars of Safari on ios 7 in the colors of the app. every system starts with the modern one */
typedef enum {
    YZDesignModern,
    YZDesignClassic,
    YZDesignFlat
} YZDesign;

/* where the bars of the modern design stand (they are always the floating ones: the address in a white pill over the page ground). bottom: one
   bar at the foot, the pill over the keys back, forward, share, menu and tabs, nothing at the top. top: no bar at the foot, one row at the top as
   Firefox has it, the pill and two keys, tabs and menu. the classic and the flat design keep their own bars */
typedef enum {
    YZBarLayoutBottom,
    YZBarLayoutTop
} YZBarLayout;

/* how the tab tray shows the tabs: a grid of cards that scroll, as Firefox does, or pages that are paged sideways one at a time, as Safari does */
typedef enum {
    YZTabsLayoutGrid,
    YZTabsLayoutPages
} YZTabsLayout;

typedef enum {
    YZThemeLight,
    YZThemeDark,
    YZThemeBlack
} YZThemeKind;

/* posted after any setting changed, the object is the YZSettings class */
extern NSString *const YZSettingsDidChangeNotification;

/* what the user chose in the settings, kept in the user defaults */
@interface YZSettings : NSObject
+ (YZLanguage)language;
+ (void)setLanguage:(YZLanguage)language;
/* the classic design works on ios 5 to 7 only, the flat one on ios 5 to 15, elsewhere their options are shown locked */
+ (BOOL)classicDesignAvailable;
+ (BOOL)flatDesignAvailable;
+ (YZDesign)design;
+ (void)setDesign:(YZDesign)design;
/* an unset choice is the pages of Safari in the classic design and the grid of Firefox in the modern one */
/* the grid in the modern design whatever was chosen: the pages exist in the classic and the flat one */
+ (YZTabsLayout)tabsLayout;
+ (void)setTabsLayout:(YZTabsLayout)layout;
/* an unset choice is the bar at the bottom */
+ (YZBarLayout)barLayout;
+ (void)setBarLayout:(YZBarLayout)layout;
+ (YZMascot)mascot;
+ (void)setMascot:(YZMascot)mascot;
+ (YZThemeKind)theme;
+ (void)setTheme:(YZThemeKind)theme;
+ (yozora_search_engine)searchEngine;
+ (void)setSearchEngine:(yozora_search_engine)core;
+ (BOOL)blockTrackers;
+ (void)setBlockTrackers:(BOOL)enabled;
/* tiles of the page are drawn at one pixel for each point, which is faster and softer */
+ (BOOL)economyRaster;
+ (void)setEconomyRaster:(BOOL)enabled;
+ (BOOL)saveHistory;
+ (void)setSaveHistory:(BOOL)enabled;
+ (BOOL)javascript;
+ (void)setJavascript:(BOOL)enabled;
+ (BOOL)blockThirdPartyCookies;
+ (void)setBlockThirdPartyCookies:(BOOL)enabled;
/* pages are asked for fewer animations and run them at 30 frames a second, on by default for phones under a gigabyte */
+ (BOOL)reduceMotion;
/* the soft glow of the accent behind the mascot on the start page and in the preview of the mascots, on until it is turned off */
/* the picture behind the start page: how much it is blurred, 0 to 100 percent (see yozora_blur_radius), and the stamp of the stored file
   (0 without a file, the time it was stored otherwise: a changed stamp is what makes the screens take the new picture) */
+ (NSInteger)homeBackgroundBlur;
+ (void)setHomeBackgroundBlur:(NSInteger)percent;
+ (NSInteger)homeBackgroundStamp;
+ (void)noteHomeBackgroundChanged:(BOOL)present;
+ (BOOL)mascotGlow;
+ (void)setMascotGlow:(BOOL)enabled;
+ (void)setReduceMotion:(BOOL)enabled;
/* fonts that sites send are loaded and drawn */
+ (BOOL)webFonts;
+ (void)setWebFonts:(BOOL)enabled;
/* the size of page text in percent */
+ (NSInteger)textZoom;
+ (void)setTextZoom:(NSInteger)percent;
/* the range of the slider, in percent */
#define YZTextZoomMin 50
#define YZTextZoomMax 200
/* the accent chosen by the person, NO while the palette purple is kept. the private session keeps its own
   purple either way */
+ (BOOL)customAccent:(yozora_accent *)accent;
+ (void)setCustomAccent:(yozora_accent)accent;
+ (void)resetAccent;
/* the accent of the private session, NO while its deep purple is kept, the private palette turns to it as the
   normal one does */
+ (BOOL)customPrivateAccent:(yozora_accent *)accent;
+ (void)setCustomPrivateAccent:(yozora_accent)accent;
+ (void)resetPrivateAccent;
/* developer settings: the corner overlay, the log capture and the jit (on by default, read once at start, so
   a change counts at the next launch) */
+ (BOOL)debugOverlay;
+ (void)setDebugOverlay:(BOOL)enabled;
+ (BOOL)logging;
+ (void)setLogging:(BOOL)enabled;
/* freed objects are kept and named when a message reaches one: read at launch, a change counts at the next one */
+ (BOOL)zombies;
/* the designs of other systems work here too, with the bugs that come with it: a developer switch */
+ (BOOL)unlockAllDesigns;
+ (void)setUnlockAllDesigns:(BOOL)enabled;
+ (void)setZombies:(BOOL)enabled;
+ (BOOL)jit;
/* tiles painted by the gpu on arm64 from ios 11, on by default, applies at once */
+ (BOOL)metal;
+ (void)setMetal:(BOOL)enabled;
+ (void)setJit:(BOOL)enabled;
/* the person has answered the question about the jit, or set the switch */
+ (BOOL)jitAnswered;
/* returns whether this launch may start the jit after the recovery mark is saved */
+ (BOOL)beginJitStart;
+ (void)endJitStart;
+ (BOOL)jitDisabledAfterFailedStart;
+ (BOOL)jitStartMarkUnavailable;
/* not stored, the app starts in the normal profile. purples the interface, keeps pages out of the history and
   gives the core its private session. call it before the first private page is created and after the last
   profile page is parked */
+ (BOOL)incognito;
+ (void)setIncognito:(BOOL)enabled;
/* page translation: the target language (a code of core/yozora_translate.h, the device language until
   picked), the languages never offered and the ones translated at once */
+ (NSString *)translateTarget;
+ (void)setTranslateTarget:(NSString *)code;
+ (BOOL)translateNeverOffers:(NSString *)code;
+ (void)setTranslateNeverOffers:(BOOL)never language:(NSString *)code;
+ (BOOL)translatesAtOnce:(NSString *)code;
+ (void)setTranslatesAtOnce:(BOOL)always language:(NSString *)code;
/* the user's rules for the blocker in adblock plus syntax (core/yozora_filter.h), kept in
   Library/Yozora/adblock-rules.txt. setting them gives them to the core and fills the report. NO with an
   error text when the file cannot be written */
+ (NSString *)adblockRules;
+ (BOOL)setAdblockRules:(NSString *)text report:(yozora_adblock_report *)report error:(NSString **)error;
/* hands every setting that the page core knows to it, call once at start */
/* the server pages are resolved through, as the DNS over HTTPS address the core asks (@"" is the resolver of the system) */
+ (NSString *)dnsServer;
/* stores what a person typed: an empty text goes back to the system, a server is normalized by the core. anything else is refused and the
   stored server stays, the status says why */
+ (yozora_dns_status)setDnsServerText:(NSString *)text;
+ (void)applyToCore;
@end
