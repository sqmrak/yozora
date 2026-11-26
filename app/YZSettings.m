#import <UIKit/UIKit.h>
#import "YZSettings.h"
#import "YZStrings.h"
#import "YZStore.h"
#import "YZCrash.h"
#include "yozora_core.h"
#include "yozora_translate.h"
#include <math.h>

NSString *const YZSettingsDidChangeNotification = @"YZSettingsDidChange";

static NSString *const YZLanguageKey = @"YZLanguage";
static NSString *const YZThemeKey = @"YZTheme";
static NSString *const AKSearchEngineKey = @"AKSearchEngine";
static NSString *const YZBlockTrackersKey = @"YZBlockTrackers";
static NSString *const YZEconomyRasterKey = @"YZEconomyRaster";
static NSString *const YZSaveHistoryKey = @"YZSaveHistory";
static NSString *const YZJavascriptKey = @"YZJavascript";
static NSString *const YZBlockThirdPartyCookiesKey = @"YZBlockThirdPartyCookies";
static NSString *const YZTextZoomKey = @"YZTextZoom";
static NSString *const YZReduceMotionKey = @"YZReduceMotion";
static NSString *const YZMascotKey = @"YZMascot";
static NSString *const YZTabsLayoutKey = @"YZTabsLayout";
static NSString *const YZDesignKey = @"YZDesign";
static NSString *const YZBarLayoutKey = @"YZBarLayout";
static NSString *const YZMascotGlowKey = @"YZMascotGlow";
static NSString *const YZDnsServerKey = @"YZDnsServer";
static NSString *const YZHomeBackgroundStampKey = @"YZHomeBackgroundStamp";
static NSString *const YZWebFontsKey = @"YZWebFonts";
static NSString *const YZTranslateTargetKey = @"YZTranslateTarget";
static NSString *const YZTranslateNeverKey = @"YZTranslateNever";
static NSString *const YZTranslateAlwaysKey = @"YZTranslateAlways";
static NSString *const YZAccentHueKey = @"YZAccentHue";
static NSString *const YZAccentSaturationKey = @"YZAccentSaturation";
static NSString *const YZAccentBrightnessKey = @"YZAccentBrightness";
static NSString *const YZPrivateAccentHueKey = @"YZPrivateAccentHue";
static NSString *const YZPrivateAccentSaturationKey = @"YZPrivateAccentSaturation";
static NSString *const YZPrivateAccentBrightnessKey = @"YZPrivateAccentBrightness";
static NSString *const YZDebugOverlayKey = @"YZDebugOverlay";
static NSString *const YZLoggingKey = @"YZLogging";
static NSString *const YZZombiesKey = @"YZZombies";
static NSString *const YZUnlockDesignsKey = @"YZUnlockDesigns";
static NSString *const YZJitKey = @"YZJit";
static NSString *const YZMetalKey = @"YZMetal";
// set while a launch with the jit has not reached the browser yet
static NSString *const YZJitStartingKey = @"YZJitStarting";
static BOOL YZJitDisabledByFailedStart;
static BOOL YZJitStartMarkUnavailable;

// colors ask for the accent on every call, so it is read once and kept until it changes. there are two
// accents, the normal profile's and the private session's, each under three keys
typedef struct {
    NSString *hueKey;
    NSString *saturationKey;
    NSString *brightnessKey;
    BOOL loaded;
    BOOL on;
    yozora_accent value;
} YZAccentSlot;

static YZAccentSlot YZNormalAccent;
static YZAccentSlot YZPrivateAccent;

// not a stored setting: a private session ends with the app
static BOOL YZIncognito = NO;

@implementation YZSettings

// a key that was never written has the default of its setting, which is not always off
+ (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)value {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults objectForKey:key] ? [defaults boolForKey:key] : value;
}

+ (NSInteger)integerForKey:(NSString *)key defaultValue:(NSInteger)value {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults objectForKey:key] ? [defaults integerForKey:key] : value;
}

+ (void)storeInteger:(NSInteger)value forKey:(NSString *)key {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:value forKey:key];
    [defaults synchronize];
    [self applyToCore];
    [[NSNotificationCenter defaultCenter] postNotificationName:YZSettingsDidChangeNotification object:self];
}

+ (void)storeBool:(BOOL)value forKey:(NSString *)key {
    [self storeInteger:value ? 1 : 0 forKey:key];
}

// until a language is picked the interface follows the first language of the device when supported
static YZLanguage YZDeviceLanguage(void) {
    NSArray *preferred = [NSLocale preferredLanguages];
    NSString *first = [preferred count] ? [preferred objectAtIndex:0] : nil;
    if ([first hasPrefix:@"ru"])
        return YZLanguageRussian;
    if ([first hasPrefix:@"ja"])
        return YZLanguageJapanese;
    return YZLanguageEnglish;
}

+ (YZLanguage)language {
    NSInteger value = [self integerForKey:YZLanguageKey defaultValue:YZDeviceLanguage()];
    switch (value) {
    case YZLanguageEnglish: return YZLanguageEnglish;
    case YZLanguageJapanese: return YZLanguageJapanese;
    default: return YZLanguageRussian;
    }
}
+ (void)setLanguage:(YZLanguage)language { [self storeInteger:language forKey:YZLanguageKey]; }

// the classic design is the system look of ios 5 to 7 and nothing else: a later system draws bars and controls flat, so
// there the option is shown locked and a stored classic choice is ignored, unless the developer switch unlocks it. an unset choice is the modern design everywhere.
// kept in memory because every color of the interface asks for it
static NSInteger YZDesignCurrent = -1;

+ (BOOL)unlockAllDesigns { return [self boolForKey:YZUnlockDesignsKey defaultValue:NO]; }
+ (void)setUnlockAllDesigns:(BOOL)enabled {
    [self storeBool:enabled forKey:YZUnlockDesignsKey];
    YZDesignCurrent = -1;
}

+ (BOOL)classicDesignAvailable {
    return [[[UIDevice currentDevice] systemVersion] floatValue] < 8.0f || [self unlockAllDesigns];
}

+ (BOOL)flatDesignAvailable {
    return [[[UIDevice currentDevice] systemVersion] floatValue] < 16.0f || [self unlockAllDesigns];
}

+ (YZDesign)design {
    if (YZDesignCurrent < 0) {
        NSInteger stored = [self integerForKey:YZDesignKey defaultValue:YZDesignModern];
        if (stored == YZDesignClassic && [self classicDesignAvailable])
            YZDesignCurrent = YZDesignClassic;
        else if (stored == YZDesignFlat && [self flatDesignAvailable])
            YZDesignCurrent = YZDesignFlat;
        else
            YZDesignCurrent = YZDesignModern;
    }
    return (YZDesign)YZDesignCurrent;
}
+ (void)setDesign:(YZDesign)design {
    YZDesignCurrent = design;
    [self storeInteger:design forKey:YZDesignKey];
}

+ (YZBarLayout)barLayout {
    return [self integerForKey:YZBarLayoutKey defaultValue:YZBarLayoutBottom] == YZBarLayoutTop ? YZBarLayoutTop : YZBarLayoutBottom;
}
+ (void)setBarLayout:(YZBarLayout)layout { [self storeInteger:layout forKey:YZBarLayoutKey]; }

// the girl that came with the app until the person picks the fox, a value of a later version counts as the girl
+ (YZMascot)mascot {
    NSInteger stored = [self integerForKey:YZMascotKey defaultValue:YZMascotSan];
    return stored == YZMascotFox || stored == YZMascotSenko ? (YZMascot)stored : YZMascotSan;
}
+ (void)setMascot:(YZMascot)mascot { [self storeInteger:mascot forKey:YZMascotKey]; }

+ (YZTabsLayout)tabsLayout {
    // the pages are the Safari look of the classic and the flat design, the modern one has the grid only. the choice stays stored for the others
    if ([self design] == YZDesignModern)
        return YZTabsLayoutGrid;
    YZTabsLayout fallback = [self design] != YZDesignModern ? YZTabsLayoutPages : YZTabsLayoutGrid;
    return [self integerForKey:YZTabsLayoutKey defaultValue:fallback] == YZTabsLayoutPages ? YZTabsLayoutPages : YZTabsLayoutGrid;
}
+ (void)setTabsLayout:(YZTabsLayout)layout { [self storeInteger:layout forKey:YZTabsLayoutKey]; }

+ (YZThemeKind)theme {
    NSInteger value = [self integerForKey:YZThemeKey defaultValue:YZThemeLight];
    return value == YZThemeDark ? YZThemeDark : (value == YZThemeBlack ? YZThemeBlack : YZThemeLight);
}
+ (void)setTheme:(YZThemeKind)theme { [self storeInteger:theme forKey:YZThemeKey]; }

+ (yozora_search_engine)searchEngine {
    NSInteger value = [self integerForKey:AKSearchEngineKey defaultValue:YOZORA_SEARCH_GOOGLE];
    return value == YOZORA_SEARCH_DUCKDUCKGO || value == YOZORA_SEARCH_YANDEX ? (yozora_search_engine)value : YOZORA_SEARCH_GOOGLE;
}
+ (void)setSearchEngine:(yozora_search_engine)core { [self storeInteger:core forKey:AKSearchEngineKey]; }

// blocking is on until the user turns it off, a missing key is not an off switch
+ (BOOL)blockTrackers { return [self boolForKey:YZBlockTrackersKey defaultValue:YES]; }
+ (void)setBlockTrackers:(BOOL)enabled { [self storeBool:enabled forKey:YZBlockTrackersKey]; }

+ (BOOL)economyRaster { return [self boolForKey:YZEconomyRasterKey defaultValue:NO]; }
+ (void)setEconomyRaster:(BOOL)enabled { [self storeBool:enabled forKey:YZEconomyRasterKey]; }

+ (BOOL)saveHistory { return [self boolForKey:YZSaveHistoryKey defaultValue:YES]; }
+ (void)setSaveHistory:(BOOL)enabled { [self storeBool:enabled forKey:YZSaveHistoryKey]; }

+ (BOOL)javascript { return [self boolForKey:YZJavascriptKey defaultValue:YES]; }
+ (void)setJavascript:(BOOL)enabled { [self storeBool:enabled forKey:YZJavascriptKey]; }

+ (BOOL)blockThirdPartyCookies { return [self boolForKey:YZBlockThirdPartyCookiesKey defaultValue:NO]; }
+ (void)setBlockThirdPartyCookies:(BOOL)enabled { [self storeBool:enabled forKey:YZBlockThirdPartyCookiesKey]; }

// full animations until the person asks for fewer. the setting makes WebCore think the phone is in low power
// mode (animation frames at 30 a second) and sends the reduced motion preference to every site
+ (BOOL)reduceMotion {
    return [self boolForKey:YZReduceMotionKey defaultValue:NO];
}
+ (void)setReduceMotion:(BOOL)enabled { [self storeBool:enabled forKey:YZReduceMotionKey]; }

// the bottom bar always leaves on a long scroll down, this adds the address bar to it. off until asked for: a
// page that grows under the finger is not what every person wants

+ (NSInteger)homeBackgroundStamp { return [self integerForKey:YZHomeBackgroundStampKey defaultValue:0]; }
+ (void)noteHomeBackgroundChanged:(BOOL)present {
    // seconds are not enough when two pictures are stored in one second, the stamp only has to differ from the last one
    NSInteger stamp = present ? MAX((NSInteger)[[NSDate date] timeIntervalSince1970], [self homeBackgroundStamp] + 1) : 0;
    [self storeInteger:stamp forKey:YZHomeBackgroundStampKey];
}

+ (BOOL)mascotGlow { return [self boolForKey:YZMascotGlowKey defaultValue:YES]; }
+ (void)setMascotGlow:(BOOL)enabled { [self storeBool:enabled forKey:YZMascotGlowKey]; }

+ (BOOL)webFonts { return [self boolForKey:YZWebFontsKey defaultValue:YES]; }
+ (void)setWebFonts:(BOOL)enabled { [self storeBool:enabled forKey:YZWebFontsKey]; }

+ (NSInteger)textZoom {
    NSInteger value = [self integerForKey:YZTextZoomKey defaultValue:100];
    // a value stored by an older build is one of its steps, all inside the range of the slider
    return value >= YZTextZoomMin && value <= YZTextZoomMax ? value : 100;
}
+ (void)setTextZoom:(NSInteger)percent { [self storeInteger:MIN((NSInteger)YZTextZoomMax, MAX((NSInteger)YZTextZoomMin, percent)) forKey:YZTextZoomKey]; }

+ (NSString *)translateTarget {
    NSString *stored = [[NSUserDefaults standardUserDefaults] stringForKey:YZTranslateTargetKey];
    int index = yozora_tr_language_find([stored UTF8String]);
    if (index < 0) {
        // the first language the device lists, or the language of the interface when the table has none of them
        NSArray *preferred = [NSLocale preferredLanguages];
        index = [preferred count] ? yozora_tr_language_find([[preferred objectAtIndex:0] UTF8String]) : -1;
        if (index < 0) {
            switch ([self language]) {
            case YZLanguageRussian: index = yozora_tr_language_find("ru"); break;
            case YZLanguageEnglish: index = yozora_tr_language_find("en"); break;
            case YZLanguageJapanese: index = yozora_tr_language_find("ja"); break;
            }
        }
    }
    return [NSString stringWithUTF8String:yozora_tr_language_code((size_t)index)];
}
+ (void)setTranslateTarget:(NSString *)code {
    [[NSUserDefaults standardUserDefaults] setObject:code forKey:YZTranslateTargetKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:YZSettingsDidChangeNotification object:self];
}

// a list of codes under one key: the base of a code is the language ("fr-CA" is "fr")
+ (NSString *)translateBase:(NSString *)code {
    int index = yozora_tr_language_find([code UTF8String]);
    return index < 0 ? nil : [NSString stringWithUTF8String:yozora_tr_language_code((size_t)index)];
}
+ (BOOL)translateList:(NSString *)key contains:(NSString *)code {
    NSString *base = [self translateBase:code];
    return base && [[[NSUserDefaults standardUserDefaults] arrayForKey:key] containsObject:base];
}
+ (void)translateList:(NSString *)key set:(BOOL)on code:(NSString *)code {
    NSString *base = [self translateBase:code];
    if (!base)
        return;
    NSMutableArray *list = [NSMutableArray arrayWithArray:[[NSUserDefaults standardUserDefaults] arrayForKey:key]];
    if (on && ![list containsObject:base])
        [list addObject:base];
    else if (!on)
        [list removeObject:base];
    [[NSUserDefaults standardUserDefaults] setObject:list forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:YZSettingsDidChangeNotification object:self];
}
+ (BOOL)translateNeverOffers:(NSString *)code { return [self translateList:YZTranslateNeverKey contains:code]; }
+ (void)setTranslateNeverOffers:(BOOL)never language:(NSString *)code {
    [self translateList:YZTranslateNeverKey set:never code:code];
    // the two choices exclude each other
    if (never)
        [self translateList:YZTranslateAlwaysKey set:NO code:code];
}
+ (BOOL)translatesAtOnce:(NSString *)code { return [self translateList:YZTranslateAlwaysKey contains:code]; }
+ (void)setTranslatesAtOnce:(BOOL)always language:(NSString *)code {
    [self translateList:YZTranslateAlwaysKey set:always code:code];
    if (always)
        [self translateList:YZTranslateNeverKey set:NO code:code];
}

static YZAccentSlot *YZSlot(BOOL isPrivate) {
    YZAccentSlot *slot = isPrivate ? &YZPrivateAccent : &YZNormalAccent;
    if (!slot->hueKey) {
        slot->hueKey = isPrivate ? YZPrivateAccentHueKey : YZAccentHueKey;
        slot->saturationKey = isPrivate ? YZPrivateAccentSaturationKey : YZAccentSaturationKey;
        slot->brightnessKey = isPrivate ? YZPrivateAccentBrightnessKey : YZAccentBrightnessKey;
    }
    return slot;
}

static BOOL YZReadAccent(BOOL isPrivate, yozora_accent *accent) {
    YZAccentSlot *slot = YZSlot(isPrivate);
    if (!slot->loaded) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        // all three keys are written together, a partial set is not an accent
        slot->on = [defaults objectForKey:slot->hueKey] && [defaults objectForKey:slot->saturationKey] && [defaults objectForKey:slot->brightnessKey];
        if (slot->on) {
            slot->value.hue = fminf(360, fmaxf(0, [defaults floatForKey:slot->hueKey]));
            slot->value.saturation = fminf(1, fmaxf(0, [defaults floatForKey:slot->saturationKey]));
            slot->value.brightness = fminf(1, fmaxf(0, [defaults floatForKey:slot->brightnessKey]));
        }
        slot->loaded = YES;
    }
    if (slot->on && accent)
        *accent = slot->value;
    return slot->on;
}

static void YZWriteAccent(BOOL isPrivate, yozora_accent accent) {
    // a nan from a control would reach every color of the interface
    if (!isfinite(accent.hue) || !isfinite(accent.saturation) || !isfinite(accent.brightness))
        return;
    YZAccentSlot *slot = YZSlot(isPrivate);
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setFloat:fminf(360, fmaxf(0, accent.hue)) forKey:slot->hueKey];
    [defaults setFloat:fminf(1, fmaxf(0, accent.saturation)) forKey:slot->saturationKey];
    [defaults setFloat:fminf(1, fmaxf(0, accent.brightness)) forKey:slot->brightnessKey];
    slot->loaded = NO;
    [defaults synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:YZSettingsDidChangeNotification object:[YZSettings class]];
}

static void YZClearAccent(BOOL isPrivate) {
    YZAccentSlot *slot = YZSlot(isPrivate);
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:slot->hueKey];
    [defaults removeObjectForKey:slot->saturationKey];
    [defaults removeObjectForKey:slot->brightnessKey];
    slot->loaded = NO;
    [defaults synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:YZSettingsDidChangeNotification object:[YZSettings class]];
}

+ (BOOL)customAccent:(yozora_accent *)accent { return YZReadAccent(NO, accent); }
+ (void)setCustomAccent:(yozora_accent)accent { YZWriteAccent(NO, accent); }
+ (void)resetAccent { YZClearAccent(NO); }
+ (BOOL)customPrivateAccent:(yozora_accent *)accent { return YZReadAccent(YES, accent); }
+ (void)setCustomPrivateAccent:(yozora_accent)accent { YZWriteAccent(YES, accent); }
+ (void)resetPrivateAccent { YZClearAccent(YES); }

// the overlay, the log capture and the jit. the jit is read once at start (core/core/yozora_core.h), so a
// change counts at the next launch
+ (BOOL)debugOverlay { return [self boolForKey:YZDebugOverlayKey defaultValue:NO]; }
+ (void)setDebugOverlay:(BOOL)enabled { [self storeBool:enabled forKey:YZDebugOverlayKey]; }
+ (BOOL)logging { return [self boolForKey:YZLoggingKey defaultValue:YES]; }
+ (void)setLogging:(BOOL)enabled { [self storeBool:enabled forKey:YZLoggingKey]; }
+ (BOOL)zombies { return [self boolForKey:YZZombiesKey defaultValue:NO]; }
+ (void)setZombies:(BOOL)enabled { [self storeBool:enabled forKey:YZZombiesKey]; }
// the armv7 jit ran pages on a phone. the arm64 one has not run on a device and ios 15 and later may refuse or
// kill the executable mapping while javascriptcore starts, before the crash recorder of a launch could say so,
// so a new install runs arm64 in the interpreter until the switch in developer settings is turned on
+ (BOOL)jit {
#if defined(__arm64__)
    return [self boolForKey:YZJitKey defaultValue:NO];
#else
    return [self boolForKey:YZJitKey defaultValue:YES];
#endif
}
+ (void)setJit:(BOOL)enabled { [self storeBool:enabled forKey:YZJitKey]; }
+ (BOOL)metal { return [self boolForKey:YZMetalKey defaultValue:YES]; }
+ (void)setMetal:(BOOL)enabled { [self storeBool:enabled forKey:YZMetalKey]; }
+ (BOOL)jitAnswered { return [[NSUserDefaults standardUserDefaults] objectForKey:YZJitKey] != nil; }

// a launch that died while JavaScriptCore started leaves the mark, and the executable mapping is the likely
// cause: the next launch runs without the jit instead of dying again before the person can reach the switch
+ (BOOL)beginJitStart {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // the start mark below only covers the start of the engine, and the generated code that does not run on a phone
    // fails later, after the browser is up. any crash of the run before turns the jit off, whatever the thread was doing
    if ([self jit] && [YZCrash previousRunCrashed]) {
        [defaults setBool:NO forKey:YZJitKey];
        [defaults removeObjectForKey:YZJitStartingKey];
        YZJitDisabledByFailedStart = YES;
        if (![defaults synchronize])
            NSLog(@"yozora: the disabled jit setting could not be saved");
        return NO;
    }
    if (![self jit]) {
        if ([defaults boolForKey:YZJitStartingKey]) {
            [defaults removeObjectForKey:YZJitStartingKey];
            if (![defaults synchronize])
                NSLog(@"yozora: the old jit start mark could not be cleared");
        }
        return NO;
    }
    if ([defaults boolForKey:YZJitStartingKey]) {
        [defaults setBool:NO forKey:YZJitKey];
        [defaults removeObjectForKey:YZJitStartingKey];
        YZJitDisabledByFailedStart = YES;
        if (![defaults synchronize])
            NSLog(@"yozora: the disabled jit setting could not be saved");
        return NO;
    }
    [defaults setBool:YES forKey:YZJitStartingKey];
    // ios may kill the process during the first jit write, before defaults flush on their own
    if (![defaults synchronize]) {
        YZJitStartMarkUnavailable = YES;
        NSLog(@"yozora: the jit start mark could not be saved, starting without the jit");
        return NO;
    }
    return YES;
}

+ (void)endJitStart {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults objectForKey:YZJitStartingKey])
        return;
    [defaults removeObjectForKey:YZJitStartingKey];
    if (![defaults synchronize])
        NSLog(@"yozora: the jit start mark could not be cleared");
}

+ (BOOL)jitDisabledAfterFailedStart { return YZJitDisabledByFailedStart; }
+ (BOOL)jitStartMarkUnavailable { return YZJitStartMarkUnavailable; }

+ (BOOL)incognito { return YZIncognito; }
+ (void)setIncognito:(BOOL)enabled {
    if (YZIncognito == enabled)
        return;
    YZIncognito = enabled;
    yozora_set_private_session(enabled ? 1 : 0);
    [self applyToCore];
    [[NSNotificationCenter defaultCenter] postNotificationName:YZSettingsDidChangeNotification object:self];
}

static const NSUInteger YZAdblockRulesLimit = 256 * 1024;

static NSString *YZAdblockRulesPath(void) {
    return [[YZStore profileDirectory] stringByAppendingPathComponent:@"adblock-rules.txt"];
}

+ (NSString *)adblockRules {
    NSData *data = [NSData dataWithContentsOfFile:YZAdblockRulesPath()];
    if (![data length] || [data length] > YZAdblockRulesLimit)
        return @"";
    NSString *text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    return text ? text : @"";
}

+ (BOOL)setAdblockRules:(NSString *)text report:(yozora_adblock_report *)report error:(NSString **)error {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data || [data length] > YZAdblockRulesLimit) {
        if (error)
            *error = YZT(@"Правил слишком много: предел 256 КБ");
        return NO;
    }
    NSString *path = YZAdblockRulesPath();
    NSError *failure = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:NULL];
    // the file is replaced whole, a half written list never loads
    if (![data writeToFile:path options:NSDataWritingAtomic error:&failure]) {
        if (error)
            *error = [failure localizedDescription];
        return NO;
    }
    yozora_adblock_set_rules([data bytes], [data length], report);
    return YES;
}

// a stored address is read through the core again, an edited preferences file cannot hand the loader anything the settings would refuse
+ (NSString *)dnsServer {
    NSString *stored = [[NSUserDefaults standardUserDefaults] stringForKey:YZDnsServerKey];
    char url[YOZORA_DNS_CAPACITY];
    if (![stored length] || yozora_dns_normalize([stored UTF8String], url, sizeof url) != YOZORA_DNS_OK)
        return @"";
    return [NSString stringWithUTF8String:url];
}

+ (yozora_dns_status)setDnsServerText:(NSString *)text {
    char url[YOZORA_DNS_CAPACITY];
    yozora_dns_status status = yozora_dns_normalize([(text ? text : @"") UTF8String], url, sizeof url);
    if (status != YOZORA_DNS_OK && status != YOZORA_DNS_EMPTY)
        return status;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (status == YOZORA_DNS_EMPTY)
        [defaults removeObjectForKey:YZDnsServerKey];
    else
        [defaults setObject:[NSString stringWithUTF8String:url] forKey:YZDnsServerKey];
    [defaults synchronize];
    [self applyToCore];
    [[NSNotificationCenter defaultCenter] postNotificationName:YZSettingsDidChangeNotification object:self];
    return status;
}

+ (void)applyToCore {
    static BOOL rulesGiven;
    if (!rulesGiven) {
        rulesGiven = YES;
        NSData *rules = [[self adblockRules] dataUsingEncoding:NSUTF8StringEncoding];
        yozora_adblock_set_rules([rules bytes], [rules length], NULL);
    }
    yozora_options options;
    options.javascript = [self javascript] ? 1 : 0;
    options.text_zoom_percent = (int)[self textZoom];
    options.block_third_party_cookies = [self blockThirdPartyCookies] ? 1 : 0;
    options.reduce_motion = [self reduceMotion] ? 1 : 0;
    options.web_fonts = [self webFonts] ? 1 : 0;
    // pages always get WebGL contexts, there is no setting for it
    options.webgl = 1;
    // links to other apps are always offered, there is no setting for it
    options.external_links = 1;
    // sites follow the dark themes of the browser when they have a dark design
    options.dark_appearance = ([self theme] != YZThemeLight || YZIncognito) ? 1 : 0;
    yozora_set_options(&options);
    yozora_set_tracker_blocking([self blockTrackers] ? 1 : 0);
    yozora_set_economy_raster([self economyRaster] ? 1 : 0);
    yozora_dns_set([[self dnsServer] UTF8String]);
}

@end
