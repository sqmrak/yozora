#import "YZPasswords.h"
#import <Security/Security.h>
#include "yozora_password.h"

static NSString *const YZPasswordNeverKey = @"YZPasswordNever";
// the sites said never for are kept up to this many, older ones are dropped
static const NSUInteger YZPasswordNeverMax = 256;

@implementation YZPasswordAccount
@synthesize site = _site, user = _user, modified = _modified;
- (void)dealloc {
    [_site release];
    [_user release];
    [_modified release];
    [super dealloc];
}
@end

@implementation YZPasswordCapture
@synthesize site = _site, user = _user, password = _password;
- (void)dealloc {
    [_site release];
    [_user release];
    [_password release];
    [super dealloc];
}
@end

// a status of the keychain as a short text for the person: the codes of SecBase.h, SecCopyErrorMessageString does not exist on ios
static NSString *YZKeychainReason(OSStatus status) {
    switch (status) {
    case errSecInteractionNotAllowed: return @"the device is locked";
    case errSecAuthFailed: return @"the keychain refused access";
    case -34018: return @"the app is signed without a keychain group";
    default: return [NSString stringWithFormat:@"keychain status %d", (int)status];
    }
}

@implementation YZPasswords

// the query that names one login of a site, or every login of the site when user is nil
+ (NSMutableDictionary *)queryForSite:(NSString *)site user:(NSString *)user {
    NSMutableDictionary *query = [NSMutableDictionary dictionaryWithObjectsAndKeys:(id)kSecClassInternetPassword, (id)kSecClass,
                                  site, (id)kSecAttrServer, (id)kSecAttrProtocolHTTPS, (id)kSecAttrProtocol, nil];
    if (user)
        [query setObject:user forKey:(id)kSecAttrAccount];
    return query;
}

+ (NSArray *)accountsMatching:(NSMutableDictionary *)query error:(NSString **)error {
    [query setObject:(id)kSecMatchLimitAll forKey:(id)kSecMatchLimit];
    [query setObject:(id)kCFBooleanTrue forKey:(id)kSecReturnAttributes];
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((CFDictionaryRef)query, &result);
    if (status == errSecItemNotFound)
        return [NSArray array];
    if (status != errSecSuccess) {
        NSLog(@"yozora: passwords could not be read: %d", (int)status);
        if (error)
            *error = YZKeychainReason(status);
        return nil;
    }
    NSMutableArray *accounts = [NSMutableArray array];
    id items = [(id)result autorelease];
    if (![items isKindOfClass:[NSArray class]])
        return accounts;
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:[NSDictionary class]])
            continue;
        NSString *site = [item objectForKey:(id)kSecAttrServer], *user = [item objectForKey:(id)kSecAttrAccount];
        NSDate *modified = [item objectForKey:(id)kSecAttrModificationDate];
        if (![site isKindOfClass:[NSString class]] || ![user isKindOfClass:[NSString class]])
            continue;
        YZPasswordAccount *account = [[[YZPasswordAccount alloc] init] autorelease];
        account.site = site;
        account.user = user;
        account.modified = [modified isKindOfClass:[NSDate class]] ? modified : nil;
        [accounts addObject:account];
    }
    return accounts;
}

+ (NSArray *)accountsWithError:(NSString **)error {
    NSMutableDictionary *query = [NSMutableDictionary dictionaryWithObjectsAndKeys:(id)kSecClassInternetPassword, (id)kSecClass,
                                  (id)kSecAttrProtocolHTTPS, (id)kSecAttrProtocol, nil];
    NSArray *accounts = [self accountsMatching:query error:error];
    return [accounts sortedArrayUsingComparator:^NSComparisonResult(YZPasswordAccount *a, YZPasswordAccount *b) {
        NSComparisonResult site = [a.site compare:b.site options:NSCaseInsensitiveSearch];
        return site != NSOrderedSame ? site : [a.user compare:b.user options:NSCaseInsensitiveSearch];
    }];
}

+ (NSArray *)accountsForSite:(NSString *)site {
    if (![site length])
        return [NSArray array];
    NSArray *accounts = [self accountsMatching:[self queryForSite:site user:nil] error:NULL];
    return [accounts sortedArrayUsingComparator:^NSComparisonResult(YZPasswordAccount *a, YZPasswordAccount *b) {
        NSDate *first = a.modified ? a.modified : [NSDate distantPast], *second = b.modified ? b.modified : [NSDate distantPast];
        return [second compare:first];
    }];
}

+ (NSString *)passwordForSite:(NSString *)site user:(NSString *)user {
    if (![site length] || !user)
        return nil;
    NSMutableDictionary *query = [self queryForSite:site user:user];
    [query setObject:(id)kSecMatchLimitOne forKey:(id)kSecMatchLimit];
    [query setObject:(id)kCFBooleanTrue forKey:(id)kSecReturnData];
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((CFDictionaryRef)query, &result);
    if (status != errSecSuccess) {
        if (status != errSecItemNotFound)
            NSLog(@"yozora: the password of %@ could not be read: %d", site, (int)status);
        return nil;
    }
    id data = [(id)result autorelease];
    if (![data isKindOfClass:[NSData class]])
        return nil;
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
}

+ (BOOL)savePassword:(NSString *)password site:(NSString *)site user:(NSString *)user error:(NSString **)error {
    NSData *data = [password dataUsingEncoding:NSUTF8StringEncoding];
    if (![site length] || !user || ![data length]) {
        if (error)
            *error = @"empty password";
        return NO;
    }
    NSMutableDictionary *query = [self queryForSite:site user:user];
    NSDictionary *change = [NSDictionary dictionaryWithObject:data forKey:(id)kSecValueData];
    OSStatus status = SecItemUpdate((CFDictionaryRef)query, (CFDictionaryRef)change);
    if (status == errSecItemNotFound) {
        [query setObject:data forKey:(id)kSecValueData];
        // only this device, and only while it is unlocked: a backup of the phone does not carry the passwords of sites
        [query setObject:(id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly forKey:(id)kSecAttrAccessible];
        [query setObject:[@"Yozora: " stringByAppendingString:site] forKey:(id)kSecAttrLabel];
        status = SecItemAdd((CFDictionaryRef)query, NULL);
    }
    if (status != errSecSuccess) {
        NSLog(@"yozora: the password of %@ could not be saved: %d", site, (int)status);
        if (error)
            *error = YZKeychainReason(status);
        return NO;
    }
    return YES;
}

+ (BOOL)removeSite:(NSString *)site user:(NSString *)user error:(NSString **)error {
    if (![site length] || !user)
        return NO;
    OSStatus status = SecItemDelete((CFDictionaryRef)[self queryForSite:site user:user]);
    if (status != errSecSuccess && status != errSecItemNotFound) {
        NSLog(@"yozora: the password of %@ could not be removed: %d", site, (int)status);
        if (error)
            *error = YZKeychainReason(status);
        return NO;
    }
    return YES;
}

+ (NSArray *)neverSites {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:YZPasswordNeverKey];
    if (![stored isKindOfClass:[NSArray class]])
        return [NSArray array];
    NSMutableArray *sites = [NSMutableArray array];
    for (id site in stored) {
        if ([site isKindOfClass:[NSString class]] && [site length])
            [sites addObject:site];
    }
    return sites;
}

+ (BOOL)neverSavesForSite:(NSString *)site {
    return site && [[self neverSites] containsObject:site];
}

+ (void)setNeverSaves:(BOOL)never site:(NSString *)site {
    if (![site length])
        return;
    NSMutableArray *sites = [NSMutableArray arrayWithArray:[self neverSites]];
    [sites removeObject:site];
    if (never)
        [sites addObject:site];
    if ([sites count] > YZPasswordNeverMax)
        [sites removeObjectsInRange:NSMakeRange(0, [sites count] - YZPasswordNeverMax)];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:sites forKey:YZPasswordNeverKey];
    [defaults synchronize];
}

+ (NSString *)siteOfAddress:(NSString *)address {
    char site[YOZORA_PASSWORD_SITE_MAX];
    if (!address || !yozora_password_site([address UTF8String], site, sizeof site))
        return nil;
    return [NSString stringWithUTF8String:site];
}

// the login field of a password field: the last field before it in its form (or the page) that takes a name, an address or a phone. the
// scripts run in the isolated world, where the page cannot replace querySelectorAll or JSON
static NSString *const YZPasswordFinder =
    @"function yzLogin(pw, filled) {"
     "  var scope = pw.form || document, inputs = scope.querySelectorAll('input'), login = null;"
     "  for (var i = 0; i < inputs.length && inputs[i] !== pw; ++i) {"
     "    var type = (inputs[i].getAttribute('type') || 'text').toLowerCase();"
     "    if ((type == 'text' || type == 'email' || type == 'tel') && (!filled || inputs[i].value)) login = inputs[i];"
     "  }"
     "  return login;"
     "}";

+ (NSString *)captureScript {
    return [YZPasswordFinder stringByAppendingString:
        @"(function () {"
         "  var fields = document.querySelectorAll('input[type=password]'), pw = null;"
         // a change of password has the old one first and the new one, typed twice, after it
         "  for (var i = fields.length - 1; i >= 0 && !pw; --i) if (fields[i].value) pw = fields[i];"
         "  if (!pw) return '';"
         "  var login = yzLogin(pw, true);"
         "  return JSON.stringify({ address: String(location.href), user: login ? login.value : '', password: pw.value });"
         "})()"];
}

+ (YZPasswordCapture *)captureFromAnswer:(NSString *)answer {
    NSData *data = [answer dataUsingEncoding:NSUTF8StringEncoding];
    if (![data length])
        return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![object isKindOfClass:[NSDictionary class]])
        return nil;
    NSString *address = [object objectForKey:@"address"], *user = [object objectForKey:@"user"], *password = [object objectForKey:@"password"];
    if (![address isKindOfClass:[NSString class]] || ![user isKindOfClass:[NSString class]] || ![password isKindOfClass:[NSString class]])
        return nil;
    NSString *site = [self siteOfAddress:address];
    if (!site || ![password length])
        return nil;
    YZPasswordCapture *capture = [[[YZPasswordCapture alloc] init] autorelease];
    capture.site = site;
    capture.user = [user stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    capture.password = password;
    return capture;
}

+ (NSString *)fillScriptWithUser:(NSString *)user password:(NSString *)password {
    NSData *json = [NSJSONSerialization dataWithJSONObject:[NSArray arrayWithObjects:user ? user : @"", password ? password : @"", nil] options:0 error:NULL];
    NSString *values = json ? [[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] autorelease] : nil;
    if (!values)
        return nil;
    // a json text is a script literal except for these two line separators, which end a string in scripts before es2019
    values = [[values stringByReplacingOccurrencesOfString:@" " withString:@"\\u2028"] stringByReplacingOccurrencesOfString:@" " withString:@"\\u2029"];
    return [NSString stringWithFormat:@"%@"
        "(function (values) {"
         "  var fields = document.querySelectorAll('input[type=password]');"
         "  if (fields.length != 1 || fields[0].value) return '';"
         "  function put(field, value) {"
         "    field.value = value;"
         "    ['input', 'change'].forEach(function (name) {"
         "      var event = document.createEvent('HTMLEvents');"
         "      event.initEvent(name, true, true);"
         "      field.dispatchEvent(event);"
         "    });"
         "  }"
         "  var login = yzLogin(fields[0], false);"
         "  if (login && !login.value && values[0]) put(login, values[0]);"
         "  put(fields[0], values[1]);"
         "  return 'filled';"
         "})(%@)", YZPasswordFinder, values];
}

@end
