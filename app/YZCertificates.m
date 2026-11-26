#import "YZCertificates.h"
#import "YZStreamProxy.h"
#import "YZStore.h"
#import "YZStrings.h"
#import <CommonCrypto/CommonDigest.h>
#include "yozora_core.h"

// the core refuses a roots file over 1 MB and the bundle takes 200 KB of it
static const NSUInteger YZCertificateMaxSize = 32 * 1024;
static const NSUInteger YZCertificateMaxCount = 100;
static const NSUInteger YZCertificateMaxFile = 512 * 1024;

// the folder the profile uses: Library/Yozora refuses writes on some installs (Cocoa error 513) and the profile then moves to Documents/Yozora
static NSString *YZCertificatesRoot(void) {
    return [YZStore profileDirectory];
}

static NSString *YZCertificatesFolder(void) {
    return [YZCertificatesRoot() stringByAppendingPathComponent:@"certificates"];
}

static NSString *YZHex(const unsigned char *bytes, NSUInteger count) {
    NSMutableString *text = [NSMutableString stringWithCapacity:count * 2];
    for (NSUInteger i = 0; i < count; ++i)
        [text appendFormat:@"%02x", bytes[i]];
    return text;
}

static NSString *YZSHA1Hex(NSData *data) {
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1([data bytes], (CC_LONG)[data length], digest);
    return YZHex(digest, CC_SHA1_DIGEST_LENGTH);
}

static const char YZBase64Alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static NSString *YZBase64Lines(NSData *data) {
    const unsigned char *in = [data bytes];
    NSUInteger length = [data length];
    NSMutableString *text = [NSMutableString string];
    NSUInteger column = 0;
    for (NSUInteger i = 0; i < length; i += 3) {
        unsigned value = (unsigned)in[i] << 16;
        if (i + 1 < length)
            value |= (unsigned)in[i + 1] << 8;
        if (i + 2 < length)
            value |= in[i + 2];
        char quad[4] = { YZBase64Alphabet[(value >> 18) & 63], YZBase64Alphabet[(value >> 12) & 63],
                         i + 1 < length ? YZBase64Alphabet[(value >> 6) & 63] : '=', i + 2 < length ? YZBase64Alphabet[value & 63] : '=' };
        [text appendString:[[[NSString alloc] initWithBytes:quad length:4 encoding:NSASCIIStringEncoding] autorelease]];
        column += 4;
        if (column == 64) {
            [text appendString:@"\n"];
            column = 0;
        }
    }
    if (column)
        [text appendString:@"\n"];
    return text;
}

// nil when the text is not base64
static NSData *YZBase64Decode(NSString *text) {
    NSMutableData *out = [NSMutableData data];
    unsigned accumulator = 0;
    int bits = 0;
    NSUInteger padding = 0;
    for (NSUInteger i = 0; i < [text length]; ++i) {
        unichar c = [text characterAtIndex:i];
        int value;
        if (c >= 'A' && c <= 'Z') value = c - 'A';
        else if (c >= 'a' && c <= 'z') value = c - 'a' + 26;
        else if (c >= '0' && c <= '9') value = c - '0' + 52;
        else if (c == '+') value = 62;
        else if (c == '/') value = 63;
        else if (c == '=') { ++padding; continue; }
        else if (c == ' ' || c == '\n' || c == '\r' || c == '\t') continue;
        else return nil;
        if (padding)
            return nil;
        accumulator = (accumulator << 6) | (unsigned)value;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            unsigned char byte = (unsigned char)((accumulator >> bits) & 0xff);
            [out appendBytes:&byte length:1];
        }
    }
    return out;
}

// a DER certificate is one SEQUENCE that fills the data
static BOOL YZLooksLikeCertificate(NSData *der) {
    const unsigned char *b = [der bytes];
    NSUInteger n = [der length];
    if (n < 64 || n > YZCertificateMaxSize || b[0] != 0x30)
        return NO;
    NSUInteger header, length;
    if (b[1] < 0x80) {
        header = 2;
        length = b[1];
    } else if (b[1] == 0x81) {
        header = 3;
        length = b[2];
    } else if (b[1] == 0x82) {
        header = 4;
        length = ((NSUInteger)b[2] << 8) | b[3];
    } else
        return NO;
    return header + length == n;
}

// the common name of the subject: the issuer comes first in the certificate and the subject after it, so the
// second name is the subject's, the only one is taken when there is just one. only a label for the list
static NSString *YZCommonName(NSData *der) {
    const unsigned char *b = [der bytes];
    NSUInteger n = [der length];
    NSMutableArray *names = [NSMutableArray array];
    for (NSUInteger i = 0; i + 6 < n; ++i) {
        if (b[i] != 0x55 || b[i + 1] != 0x04 || b[i + 2] != 0x03)
            continue;
        unsigned char tag = b[i + 3];
        NSUInteger length = b[i + 4];
        if (length >= 0x80 || i + 5 + length > n)
            continue;
        NSString *text = nil;
        if (tag == 0x0c)
            text = [[[NSString alloc] initWithBytes:b + i + 5 length:length encoding:NSUTF8StringEncoding] autorelease];
        else if (tag == 0x13 || tag == 0x16)
            text = [[[NSString alloc] initWithBytes:b + i + 5 length:length encoding:NSISOLatin1StringEncoding] autorelease];
        else if (tag == 0x1e)
            text = [[[NSString alloc] initWithBytes:b + i + 5 length:length encoding:NSUTF16BigEndianStringEncoding] autorelease];
        if ([text length])
            [names addObject:text];
    }
    if (![names count])
        return nil;
    return [names objectAtIndex:[names count] > 1 ? 1 : 0];
}

static NSDictionary *YZCertificateInfo(NSData *der) {
    NSString *sha = YZSHA1Hex(der);
    NSString *name = YZCommonName(der);
    return [NSDictionary dictionaryWithObjectsAndKeys:der, @"der", name ? name : [sha substringToIndex:12], @"name", sha, @"sha", [sha substringToIndex:16], @"print", nil];
}

@implementation YZCertificates

+ (NSArray *)parseData:(NSData *)data error:(NSString **)error {
    if (!data || ![data length] || [data length] > YZCertificateMaxFile) {
        if (error)
            *error = YZT(@"Файл пустой или слишком большой для сертификата");
        return nil;
    }
    NSMutableArray *found = [NSMutableArray array];
    const unsigned char *bytes = [data bytes];
    if (bytes[0] == 0x30) {
        if (YZLooksLikeCertificate(data))
            [found addObject:YZCertificateInfo(data)];
    } else {
        NSString *text = [[[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding] autorelease];
        NSString *begin = @"-----BEGIN CERTIFICATE-----", *end = @"-----END CERTIFICATE-----";
        NSUInteger at = 0;
        while (text) {
            NSRange head = [text rangeOfString:begin options:0 range:NSMakeRange(at, [text length] - at)];
            if (head.location == NSNotFound)
                break;
            NSUInteger bodyStart = head.location + head.length;
            NSRange tail = [text rangeOfString:end options:0 range:NSMakeRange(bodyStart, [text length] - bodyStart)];
            if (tail.location == NSNotFound)
                break;
            NSData *der = YZBase64Decode([text substringWithRange:NSMakeRange(bodyStart, tail.location - bodyStart)]);
            if (der && YZLooksLikeCertificate(der))
                [found addObject:YZCertificateInfo(der)];
            at = tail.location + tail.length;
        }
    }
    if (![found count]) {
        if (error)
            *error = YZT(@"В файле нет сертификата. Нужен .crt, .cer или .pem");
        return nil;
    }
    return found;
}

+ (NSArray *)entries {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *folder = YZCertificatesFolder();
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *file in [manager contentsOfDirectoryAtPath:folder error:NULL]) {
        if (![file hasSuffix:@".pem"])
            continue;
        NSString *path = [folder stringByAppendingPathComponent:file];
        NSData *data = [NSData dataWithContentsOfFile:path];
        NSArray *parsed = [self parseData:data error:NULL];
        if (![parsed count])
            continue;
        NSDictionary *info = [parsed objectAtIndex:0];
        NSDate *date = [[manager attributesOfItemAtPath:path error:NULL] objectForKey:NSFileModificationDate];
        [items addObject:[NSDictionary dictionaryWithObjectsAndKeys:[info objectForKey:@"name"], @"name", [info objectForKey:@"print"], @"print",
                          file, @"file", date ? date : [NSDate distantPast], @"date", nil]];
    }
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [[a objectForKey:@"date"] compare:[b objectForKey:@"date"]];
    }];
    return items;
}

+ (NSString *)bundledRoots {
    return [[NSBundle mainBundle] pathForResource:@"ca-bundle" ofType:@"crt"];
}

// the file every consumer reads. built from the bundle and the added files, named by the set of them
+ (NSString *)rootsPath {
    @synchronized(self) {
        NSString *bundled = [self bundledRoots];
        NSFileManager *manager = [NSFileManager defaultManager];
        NSMutableArray *files = [NSMutableArray array];
        for (NSString *file in [manager contentsOfDirectoryAtPath:YZCertificatesFolder() error:NULL]) {
            if ([file hasSuffix:@".pem"])
                [files addObject:file];
        }
        if (![files count] || !bundled)
            return bundled;
        [files sortUsingSelector:@selector(compare:)];
        NSString *name = [NSString stringWithFormat:@"roots-%@.crt",
                          [YZSHA1Hex([[files componentsJoinedByString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]) substringToIndex:16]];
        NSString *merged = [YZCertificatesRoot() stringByAppendingPathComponent:name];
        if ([manager fileExistsAtPath:merged])
            return merged;
        NSMutableData *all = [NSMutableData dataWithContentsOfFile:bundled];
        if (!all)
            return bundled;
        [all appendData:[@"\n" dataUsingEncoding:NSASCIIStringEncoding]];
        for (NSString *file in files) {
            NSData *pem = [NSData dataWithContentsOfFile:[YZCertificatesFolder() stringByAppendingPathComponent:file]];
            if (pem)
                [all appendData:pem];
        }
        NSString *temporary = [merged stringByAppendingString:@".tmp"];
        if (![all writeToFile:temporary atomically:NO] || rename([temporary fileSystemRepresentation], [merged fileSystemRepresentation]) != 0) {
            [manager removeItemAtPath:temporary error:NULL];
            return bundled;
        }
        // the files of earlier sets are not needed any more: a running transfer has its file open
        for (NSString *other in [manager contentsOfDirectoryAtPath:YZCertificatesRoot() error:NULL]) {
            if ([other hasPrefix:@"roots-"] && [other hasSuffix:@".crt"] && ![other isEqualToString:name])
                [manager removeItemAtPath:[YZCertificatesRoot() stringByAppendingPathComponent:other] error:NULL];
        }
        return merged;
    }
}

+ (void)apply {
    NSString *roots = [self rootsPath];
    if (roots)
        yozora_core_set_roots([roots fileSystemRepresentation]);
    [[YZStreamProxy shared] rootsChanged];
}

+ (NSUInteger)add:(NSArray *)parsed error:(NSString **)error {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *folder = YZCertificatesFolder();
    if (![manager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL]) {
        if (error)
            *error = YZT(@"Не удалось сохранить сертификат");
        return 0;
    }
    NSUInteger have = [[self entries] count], added = 0;
    for (NSDictionary *info in parsed) {
        NSString *path = [folder stringByAppendingPathComponent:[[info objectForKey:@"sha"] stringByAppendingString:@".pem"]];
        if ([manager fileExistsAtPath:path])
            continue;
        if (have + added >= YZCertificateMaxCount) {
            if (error)
                *error = YZT(@"Сертификатов слишком много");
            break;
        }
        NSString *pem = [NSString stringWithFormat:@"-----BEGIN CERTIFICATE-----\n%@-----END CERTIFICATE-----\n", YZBase64Lines([info objectForKey:@"der"])];
        if (![pem writeToFile:path atomically:YES encoding:NSASCIIStringEncoding error:NULL]) {
            if (error)
                *error = YZT(@"Не удалось сохранить сертификат");
            break;
        }
        ++added;
    }
    if (added)
        [self apply];
    return added;
}

+ (BOOL)removeEntryNamed:(NSString *)file {
    if (![file hasSuffix:@".pem"] || [file rangeOfString:@"/"].location != NSNotFound)
        return NO;
    BOOL ok = [[NSFileManager defaultManager] removeItemAtPath:[YZCertificatesFolder() stringByAppendingPathComponent:file] error:NULL];
    if (ok)
        [self apply];
    return ok;
}

@end
