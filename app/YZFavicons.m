#import "YZFavicons.h"
#import "YZSettings.h"
#import "YZTheme.h"
#include "yozora_address.h"
#include "yozora_icons.h"

NSString *const YZFaviconDidLoadNotification = @"YZFaviconDidLoad";

static const NSUInteger YZFaviconMemoryLimit = 64;
static const NSUInteger YZIconBytesLimit = 524288;
// a tile draws its icon 40 points wide, which is 120 pixels on a screen of 3 times and a home screen picture of
// a site is 180 pixels; the picture is kept up to 256 pixels (64 of them are 16 MB in memory)
static const CGFloat YZIconPixels = 256;
// the page that declares the icons is read up to this many bytes and no more
static const NSUInteger YZIconPageLimit = YOZORA_ICON_SCAN_MAX;
// an icon smaller than this is a placeholder, not a picture of the site
static const CGFloat YZIconMinimumSide = 16;
// the pictures kept by an earlier version came from a guessed file name at 128 pixels at most and are not trusted
static NSString *const YZIconDirectoryName = @"YozoraIcons3";
static NSString *const YZIconOldDirectoryName = @"YozoraIcons";
// the pictures of the second cache kept the first one that decoded, often a 32 pixel favicon
static NSString *const YZIconOlderDirectoryName = @"YozoraIcons2";
static const NSTimeInterval YZIconRetry = 3 * 24 * 3600;

static NSMutableDictionary *YZFaviconMemory;
static NSMutableSet *YZIconPending;
static NSOperationQueue *YZIconQueue;

static NSString *YZIconDirectory(void) {
    NSArray *roots = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if (![roots count])
        return nil;
    static BOOL cleaned;
    if (!cleaned) {
        cleaned = YES;
        [[NSFileManager defaultManager] removeItemAtPath:[[roots objectAtIndex:0] stringByAppendingPathComponent:YZIconOldDirectoryName] error:NULL];
        [[NSFileManager defaultManager] removeItemAtPath:[[roots objectAtIndex:0] stringByAppendingPathComponent:YZIconOlderDirectoryName] error:NULL];
    }
    return [[roots objectAtIndex:0] stringByAppendingPathComponent:YZIconDirectoryName];
}

// a host is letters, digits, dots and hyphens, which makes a safe file name; anything else is not asked for
static BOOL YZSafeHost(NSString *host) {
    if (![host length] || [host length] > 253)
        return NO;
    for (NSUInteger i = 0; i < [host length]; ++i) {
        unichar c = [host characterAtIndex:i];
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '-'))
            return NO;
    }
    return [host rangeOfString:@"."].location != NSNotFound && ![host hasPrefix:@"."];
}

// the picture is kept at most 256 pixels on a side, a larger one would only weigh on the memory. a smaller
// one is not enlarged, the view that shows it does that with its own filter
static UIImage *YZScaledIcon(UIImage *image) {
    CGSize size = image.size;
    // a picture that decodes at a scale of 2 or 3 reports points, the pixels are what is measured
    CGFloat pixelWidth = size.width * image.scale, pixelHeight = size.height * image.scale;
    if (pixelWidth < YZIconMinimumSide || pixelHeight < YZIconMinimumSide)
        return nil;
    CGFloat scale = MIN((CGFloat)1, YZIconPixels / MAX(pixelWidth, pixelHeight));
    CGSize target = CGSizeMake(MAX((CGFloat)1, floorf(pixelWidth * scale)), MAX((CGFloat)1, floorf(pixelHeight * scale)));
    UIGraphicsBeginImageContextWithOptions(target, NO, 1);
    CGContextSetInterpolationQuality(UIGraphicsGetCurrentContext(), kCGInterpolationHigh);
    [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}

// reads the start of one https page and no more than YZIconPageLimit bytes of it, on the main run loop. the
// page is where a site says which pictures are its icons. `failed` is YES when the connection itself broke
// (it may be the network), a refusal or a page that is not https gives no data and is not a failure
@interface YZIconPage : NSObject {
    NSMutableData *_data;
    NSURLConnection *_connection;
    NSURL *_finalURL;
    BOOL _refused;
    void (^_done)(NSData *, NSURL *, BOOL);
}
- (id)initWithURL:(NSURL *)url done:(void (^)(NSData *page, NSURL *finalURL, BOOL failed))done;
@end

@implementation YZIconPage
- (id)initWithURL:(NSURL *)url done:(void (^)(NSData *, NSURL *, BOOL))done {
    self = [super init];
    if (!self)
        return nil;
    _data = [[NSMutableData alloc] init];
    _done = [done copy];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:8];
    [request setValue:@"text/html,application/xhtml+xml" forHTTPHeaderField:@"Accept"];
    _connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:YES];
    if (!_connection) {
        [self finishFailed:YES];
        return self;
    }
    // the connection holds its delegate until it ends, the reader lives that long
    [self retain];
    return self;
}
- (void)dealloc {
    [_data release];
    [_connection release];
    [_finalURL release];
    [_done release];
    [super dealloc];
}
- (void)finishFailed:(BOOL)failed {
    if (!_done)
        return;
    void (^done)(NSData *, NSURL *, BOOL) = _done;
    _done = nil;
    NSData *page = (!failed && !_refused && [_data length]) ? [[_data copy] autorelease] : nil;
    done(page, _finalURL, failed);
    [done release];
}
- (void)stop {
    [_connection cancel];
    [_connection release];
    _connection = nil;
}
// a site that is not served over https does not give its pictures
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    [_finalURL release];
    _finalURL = [[response URL] retain];
    if (status != 200 || ![[[_finalURL scheme] lowercaseString] isEqualToString:@"https"]) {
        _refused = YES;
        [self stop];
        [self finishFailed:NO];
        [self release];
    }
}
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    if (_refused || !_done)
        return;
    [_data appendData:data];
    if ([_data length] >= YZIconPageLimit) {
        [self stop];
        [self finishFailed:NO];
        [self release];
    }
}
- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    if (_refused || !_done)
        return;
    [self stop];
    [self finishFailed:NO];
    [self release];
}
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    if (_refused || !_done)
        return;
    [self stop];
    [self finishFailed:YES];
    [self release];
}
@end

@implementation YZFavicons

+ (NSString *)hostOfURL:(NSString *)url {
    char host[256];
    if (![url length] || !yozora_address_host([url UTF8String], host, sizeof host))
        return nil;
    return [[NSString stringWithUTF8String:host] lowercaseString];
}

+ (void)storeInMemory:(UIImage *)icon forHost:(NSString *)host {
    if (!YZFaviconMemory)
        YZFaviconMemory = [[NSMutableDictionary alloc] init];
    // the table is emptied when it is full, the files in the caches directory fill it again as the icons are asked for
    if ([YZFaviconMemory count] >= YZFaviconMemoryLimit)
        [YZFaviconMemory removeAllObjects];
    [YZFaviconMemory setObject:icon forKey:host];
}

// how much of a 24 by 24 look at the icon is covered and how light the covered part is. false when the picture cannot be read
static BOOL YZIconCoverage(UIImage *icon, double *coverage, double *lightness) {
    CGImageRef image = icon.CGImage;
    if (!image)
        return NO;
    // the icon is looked at in a grid of 24 by 24, which is enough to tell a glyph from a filled square
    enum { side = 24 };
    unsigned char pixels[side * side * 4];
    memset(pixels, 0, sizeof pixels);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, side, side, 8, side * 4, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context)
        return NO;
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextDrawImage(context, CGRectMake(0, 0, side, side), image);
    CGContextRelease(context);
    double alpha = 0, light = 0;
    for (int i = 0; i < side * side; ++i) {
        const unsigned char *p = pixels + i * 4;
        alpha += p[3];
        // premultiplied: the weight of a pixel is already in its channels
        light += 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2];
    }
    *coverage = alpha / (255.0 * side * side);
    *lightness = alpha > 0 ? light / alpha : 0;
    return YES;
}

+ (UIColor *)tileColorForIcon:(UIImage *)icon {
    BOOL dark = [YZTheme isDark];
    UIColor *card = dark ? [YZTheme cardColor] : [UIColor whiteColor];
    double coverage, lightness;
    // a nearly empty picture shows nothing whatever it stands on
    if (!YZIconCoverage(icon, &coverage, &lightness) || coverage < 0.02 || coverage > 0.9)
        return card;
    if (dark)
        return lightness < 0.30 ? [UIColor colorWithRed:0.93f green:0.93f blue:0.94f alpha:1] : card;
    return lightness > 0.85 ? [UIColor colorWithRed:0.16f green:0.16f blue:0.18f alpha:1] : card;
}

+ (YZIconShape)shapeOfIcon:(UIImage *)icon {
    CGFloat pixels = MIN(icon.size.width, icon.size.height) * icon.scale;
    double coverage, lightness;
    // a home screen picture is a square that fills its tile, the way the shortcuts of Firefox show it. a small one is not blown up
    if (pixels < 64)
        return YZIconShapeSmall;
    if (pixels >= 96 && YZIconCoverage(icon, &coverage, &lightness) && coverage > 0.97)
        return YZIconShapeFull;
    return YZIconShapeGlyph;
}

// popular sites draw their own colored mark from the bundle: the page of Google offers a 16 pixel favicon and a blurred one comes out of it,
// m.youtube.com and web.telegram.org give small or plain ones. the longest listed domain wins, so mail.google.com is Gmail and not Google
static UIImage *YZBundledSiteIcon(NSString *host) {
    static NSDictionary *names;
    if (!names)
        names = [[NSDictionary alloc] initWithObjectsAndKeys:
                 @"google", @"google.com", @"google", @"google.ru", @"gmail", @"mail.google.com", @"gmail", @"gmail.com",
                 @"duckduckgo", @"duckduckgo.com", @"yandex", @"yandex.ru", @"yandex", @"ya.ru", @"yandex", @"yandex.com",
                 @"youtube", @"youtube.com", @"youtube", @"youtu.be", @"telegram", @"telegram.org", @"telegram", @"t.me", @"telegram", @"telegram.me",
                 @"facebook", @"facebook.com", @"facebook", @"fb.com", @"instagram", @"instagram.com",
                 @"vk", @"vk.com", @"vk", @"vk.ru", @"x", @"x.com", @"x", @"twitter.com", @"wikipedia", @"wikipedia.org",
                 @"reddit", @"reddit.com", @"github", @"github.com", @"whatsapp", @"whatsapp.com", @"tiktok", @"tiktok.com",
                 @"twitch", @"twitch.tv", @"discord", @"discord.com", @"discord", @"discord.gg", @"netflix", @"netflix.com",
                 @"spotify", @"spotify.com", @"pinterest", @"pinterest.com", @"pinterest", @"pinterest.ru", @"linkedin", @"linkedin.com",
                 @"odnoklassniki", @"ok.ru", @"maildotru", @"mail.ru", @"kinopoisk", @"kinopoisk.ru", @"stackoverflow", @"stackoverflow.com",
                 @"openai", @"chatgpt.com", @"openai", @"openai.com", @"threads", @"threads.net", @"threads", @"threads.com",
                 @"tumblr", @"tumblr.com", @"soundcloud", @"soundcloud.com", @"steam", @"steampowered.com", @"steam", @"steamcommunity.com",
                 @"bluesky", @"bsky.app", @"duolingo", @"duolingo.com", nil];
    NSString *domain = host;
    while ([domain length]) {
        NSString *name = [names objectForKey:domain];
        if (name)
            return [YZTheme logoNamed:name];
        NSRange dot = [domain rangeOfString:@"."];
        if (dot.location == NSNotFound)
            break;
        domain = [domain substringFromIndex:dot.location + 1];
    }
    return nil;
}

+ (UIImage *)iconForURL:(NSString *)url {
    NSString *host = [self hostOfURL:url];
    if (!YZSafeHost(host))
        return nil;
    UIImage *bundled = YZBundledSiteIcon(host);
    if (bundled)
        return bundled;
    UIImage *known = [YZFaviconMemory objectForKey:host];
    if (known)
        return known;
    NSString *directory = YZIconDirectory();
    if (!directory)
        return nil;
    NSString *file = [directory stringByAppendingPathComponent:[host stringByAppendingPathExtension:@"png"]];
    UIImage *stored = [UIImage imageWithContentsOfFile:file];
    if (stored) {
        [self storeInMemory:stored forHost:host];
        return stored;
    }
    // while the private session runs, only what is already stored is shown
    if ([YZSettings incognito])
        return nil;
    NSString *absent = [directory stringByAppendingPathComponent:[host stringByAppendingPathExtension:@"none"]];
    NSDictionary *marker = [[NSFileManager defaultManager] attributesOfItemAtPath:absent error:NULL];
    NSDate *when = [marker objectForKey:NSFileModificationDate];
    if (when && -[when timeIntervalSinceNow] < YZIconRetry)
        return nil;
    [self fetchHost:host file:file absent:absent];
    return nil;
}

// the page of the site for the icons: a mobile host (m.youtube.com) declares a 32 pixel favicon, the site behind it declares the home screen
// pictures and a manifest
static NSString *YZIconPageHost(NSString *host) {
    for (NSString *prefix in [NSArray arrayWithObjects:@"m.", @"mobile.", @"touch.", nil]) {
        if ([host hasPrefix:prefix] && [[host substringFromIndex:[prefix length]] rangeOfString:@"."].location != NSNotFound)
            return [host substringFromIndex:[prefix length]];
    }
    return host;
}

// a picture of this many pixels on its side is sharp on a tile of 60 points at 2 times, a smaller one makes the search go on
static const CGFloat YZIconGoodSide = 128;
// the icons of a manifest, the one that sites keep for installing a page as an app: 192 and 512 pixel pictures that no <link> declares
static const NSUInteger YZIconManifestLimit = 262144;
static const size_t YZIconCandidatesMax = 8;

static CGFloat YZPixelSide(UIImage *icon) {
    return MIN(icon.size.width, icon.size.height) * icon.scale;
}

// the largest side of a "sizes" text such as "192x192" or "48x48 96x96", 0 when it says nothing useful ("any" is a vector picture)
static unsigned YZLargestSize(NSString *sizes) {
    unsigned largest = 0;
    for (NSString *part in [sizes componentsSeparatedByString:@" "]) {
        NSArray *pair = [[part lowercaseString] componentsSeparatedByString:@"x"];
        if ([pair count] == 2)
            largest = MAX(largest, (unsigned)MAX([[pair objectAtIndex:0] intValue], [[pair objectAtIndex:1] intValue]));
    }
    return largest;
}

// the address of the manifest a page declares with <link rel="manifest">, nil when it has none
static NSURL *YZManifestURL(NSData *page, NSURL *pageURL) {
    NSString *head = [[[NSString alloc] initWithBytes:[page bytes] length:MIN([page length], (NSUInteger)YZIconPageLimit) encoding:NSUTF8StringEncoding] autorelease];
    if (!head)
        return nil;
    NSRegularExpression *tag = [NSRegularExpression regularExpressionWithPattern:@"<link\\s[^>]*>" options:NSRegularExpressionCaseInsensitive error:NULL];
    NSRegularExpression *rel = [NSRegularExpression regularExpressionWithPattern:@"rel\\s*=\\s*[\"']?manifest[\"'\\s>]" options:NSRegularExpressionCaseInsensitive error:NULL];
    NSRegularExpression *href = [NSRegularExpression regularExpressionWithPattern:@"href\\s*=\\s*[\"']([^\"']+)[\"']" options:NSRegularExpressionCaseInsensitive error:NULL];
    for (NSTextCheckingResult *match in [tag matchesInString:head options:0 range:NSMakeRange(0, [head length])]) {
        NSString *text = [head substringWithRange:match.range];
        if (![rel firstMatchInString:text options:0 range:NSMakeRange(0, [text length])])
            continue;
        NSTextCheckingResult *link = [href firstMatchInString:text options:0 range:NSMakeRange(0, [text length])];
        if (link) {
            NSURL *resolved = [NSURL URLWithString:[text substringWithRange:[link rangeAtIndex:1]] relativeToURL:pageURL];
            return [[resolved absoluteURL] scheme] ? [resolved absoluteURL] : nil;
        }
    }
    return nil;
}

// candidate addresses, largest first: what the page declares and what its manifest lists (home screen pictures before plain icons at equal
// size), then the file names that sites keep at the root, a favicon.ico last. only https is asked, at most 8 are tried and the search stops
// at the first picture that is sharp (128 pixels), else the largest one found is kept. runs on the icon queue: the manifest is read here
+ (NSArray *)candidatesForHost:(NSString *)host page:(NSData *)page pageURL:(NSURL *)pageURL {
    NSMutableArray *found = [NSMutableArray array];
    if ([page length] && pageURL) {
        yozora_icon_link links[YOZORA_ICON_LINKS_MAX];
        size_t count = yozora_icon_links([page bytes], [page length], [[pageURL absoluteString] UTF8String], links, YOZORA_ICON_LINKS_MAX);
        for (size_t i = 0; i < count; ++i) {
            NSString *address = [NSString stringWithUTF8String:links[i].url];
            if (address)
                [found addObject:[NSArray arrayWithObjects:address, [NSNumber numberWithUnsignedInt:links[i].size], [NSNumber numberWithInt:links[i].touch], nil]];
        }
        NSURL *manifest = YZManifestURL(page, pageURL);
        if ([[manifest scheme] isEqualToString:@"https"]) {
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:manifest cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:6];
            NSURLResponse *response = nil;
            NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:NULL];
            id json = [data length] && [data length] <= YZIconManifestLimit ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            NSArray *icons = [json isKindOfClass:[NSDictionary class]] ? [json objectForKey:@"icons"] : nil;
            if ([icons isKindOfClass:[NSArray class]]) {
                for (id icon in icons) {
                    if (![icon isKindOfClass:[NSDictionary class]] || [[icon objectForKey:@"src"] isKindOfClass:[NSString class]] == NO)
                        continue;
                    // a vector or a monochrome mask is no picture of the site
                    NSString *purpose = [icon objectForKey:@"purpose"];
                    if ([purpose isKindOfClass:[NSString class]] && [purpose rangeOfString:@"any"].location == NSNotFound && [purpose length])
                        continue;
                    NSString *type = [icon objectForKey:@"type"];
                    if ([type isKindOfClass:[NSString class]] && [type rangeOfString:@"svg"].location != NSNotFound)
                        continue;
                    NSString *sizes = [icon objectForKey:@"sizes"];
                    NSURL *resolved = [[NSURL URLWithString:[icon objectForKey:@"src"] relativeToURL:[response URL] ? [response URL] : manifest] absoluteURL];
                    NSString *address = [resolved absoluteString];
                    if (address)
                        [found addObject:[NSArray arrayWithObjects:address, [NSNumber numberWithUnsignedInt:[sizes isKindOfClass:[NSString class]] ? YZLargestSize(sizes) : 0],
                                          [NSNumber numberWithInt:1], nil]];
                }
            }
        }
    }
    // the largest first, a home screen picture before a plain one of the same size, the order of the page otherwise
    NSArray *sorted = [found sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        unsigned left = [[a objectAtIndex:1] unsignedIntValue], right = [[b objectAtIndex:1] unsignedIntValue];
        if (left != right)
            return left > right ? NSOrderedAscending : NSOrderedDescending;
        int touchA = [[a objectAtIndex:2] intValue], touchB = [[b objectAtIndex:2] intValue];
        return touchA == touchB ? NSOrderedSame : (touchA > touchB ? NSOrderedAscending : NSOrderedDescending);
    }];
    NSMutableArray *list = [NSMutableArray array];
    for (NSArray *entry in sorted) {
        NSString *address = [entry objectAtIndex:0];
        if ([address hasPrefix:@"https://"] && ![list containsObject:address])
            [list addObject:address];
    }
    NSString *pageHost = YZIconPageHost(host);
    for (NSString *path in [NSArray arrayWithObjects:@"apple-touch-icon.png", @"apple-touch-icon-precomposed.png", @"favicon.ico", nil]) {
        NSString *address = [NSString stringWithFormat:@"https://%@/%@", pageHost, path];
        if (![list containsObject:address])
            [list addObject:address];
    }
    if ([list count] > YZIconCandidatesMax)
        [list removeObjectsInRange:NSMakeRange(YZIconCandidatesMax, [list count] - YZIconCandidatesMax)];
    return list;
}

+ (void)finishHost:(NSString *)host icon:(UIImage *)icon file:(NSString *)file {
    NSData *png = UIImagePNGRepresentation(icon);
    NSFileManager *files = [NSFileManager defaultManager];
    NSDictionary *mode = [NSDictionary dictionaryWithObject:[NSNumber numberWithUnsignedLong:0700] forKey:NSFilePosixPermissions];
    [files createDirectoryAtPath:[file stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:mode error:NULL];
    if (png)
        [png writeToFile:file options:NSDataWritingAtomic error:NULL];
    dispatch_async(dispatch_get_main_queue(), ^{
        [YZIconPending removeObject:host];
        [YZFavicons storeInMemory:icon forHost:host];
        [[NSNotificationCenter defaultCenter] postNotificationName:YZFaviconDidLoadNotification object:[YZFavicons class]
                                                          userInfo:[NSDictionary dictionaryWithObject:host forKey:@"host"]];
    });
}

// a refusal moves on to the next candidate, a failed connection stops (it may be the network) and is not remembered. a picture under 128
// pixels is kept as the best so far and the search goes on, the largest one found is what stays
+ (void)fetchCandidates:(NSArray *)candidates index:(NSUInteger)index host:(NSString *)host file:(NSString *)file absent:(NSString *)absent refused:(BOOL)refused best:(UIImage *)best {
    if (index >= [candidates count]) {
        if (best) {
            [self finishHost:host icon:best file:file];
            return;
        }
        NSFileManager *files = [NSFileManager defaultManager];
        NSDictionary *mode = [NSDictionary dictionaryWithObject:[NSNumber numberWithUnsignedLong:0700] forKey:NSFilePosixPermissions];
        [files createDirectoryAtPath:[file stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:mode error:NULL];
        if (refused)
            [[NSData data] writeToFile:absent options:NSDataWritingAtomic error:NULL];
        dispatch_async(dispatch_get_main_queue(), ^{ [YZIconPending removeObject:host]; });
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[candidates objectAtIndex:index]]
                                                           cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:8];
    [request setValue:@"image/*" forHTTPHeaderField:@"Accept"];
    [NSURLConnection sendAsynchronousRequest:request queue:YZIconQueue completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
        UIImage *icon = nil;
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        // an error page that answers with a status of 200 is not an image and does not decode as one
        if (!error && status == 200 && [data length] && [data length] <= YZIconBytesLimit)
            icon = YZScaledIcon([UIImage imageWithData:data]);
        if (!icon) {
            if (error && !best) {
                // the network failed: nothing is remembered, the next ask tries again
                dispatch_async(dispatch_get_main_queue(), ^{ [YZIconPending removeObject:host]; });
                return;
            }
            [self fetchCandidates:candidates index:index + 1 host:host file:file absent:absent refused:YES best:best];
            return;
        }
        UIImage *kept = (!best || YZPixelSide(icon) > YZPixelSide(best)) ? icon : best;
        if (YZPixelSide(kept) >= YZIconGoodSide) {
            [self finishHost:host icon:kept file:file];
            return;
        }
        [self fetchCandidates:candidates index:index + 1 host:host file:file absent:absent refused:YES best:kept];
    }];
}

+ (void)fetchHost:(NSString *)host file:(NSString *)file absent:(NSString *)absent {
    if (!YZIconPending)
        YZIconPending = [[NSMutableSet alloc] init];
    if ([YZIconPending containsObject:host])
        return;
    [YZIconPending addObject:host];
    if (!YZIconQueue) {
        YZIconQueue = [[NSOperationQueue alloc] init];
        YZIconQueue.maxConcurrentOperationCount = 2;
    }
    NSURL *root = [NSURL URLWithString:[NSString stringWithFormat:@"https://%@/", YZIconPageHost(host)]];
    // the page is read on the main run loop, the rest happens on the icon queue
    dispatch_async(dispatch_get_main_queue(), ^{
        [[[YZIconPage alloc] initWithURL:root done:^(NSData *page, NSURL *finalURL, BOOL failed) {
            if (failed) {
                // the network failed: nothing is remembered, the next ask tries again
                [YZIconPending removeObject:host];
                return;
            }
            [YZIconQueue addOperationWithBlock:^{
                [self fetchCandidates:[self candidatesForHost:host page:page pageURL:finalURL] index:0 host:host file:file absent:absent refused:NO best:nil];
            }];
        }] autorelease];
    });
}

@end
