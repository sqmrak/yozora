#import "YZTranslation.h"
#import "YZSettings.h"
#include "yozora_translate.h"

// one batch: how many texts and bytes of the encoded request, the service refuses a request much larger
static const size_t YZBatchBytes = 7000;
static const size_t YZBatchItems = 60;
static const NSTimeInterval YZPollSeconds = 1.5;

static NSString *YZLibrary(void) {
    static NSString *library;
    if (!library)
        library = [[NSString alloc] initWithUTF8String:yozora_translate_script()];
    return library;
}

// the library, then a call of it: the script that the core runs in the isolated world
static NSString *YZCall(yozora_core *core, NSString *call) {
    char *answer = yozora_core_run_script(core, [[[YZLibrary() stringByAppendingString:@"\n"] stringByAppendingString:call] UTF8String]);
    if (!answer)
        return nil;
    NSString *text = [NSString stringWithUTF8String:answer];
    free(answer);
    return text;
}

static id YZJSON(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
}

// a string as a javascript literal: the json of a one item array without its brackets
static NSString *YZLiteral(NSString *text) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:[NSArray arrayWithObject:text] options:0 error:NULL];
    NSString *array = data ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] : nil;
    return [array length] > 2 ? [array substringWithRange:NSMakeRange(1, [array length] - 2)] : @"\"\"";
}

@implementation YZTranslation
@synthesize delegate = _delegate;
@synthesize phase = _phase;
@synthesize source = _source;
@synthesize target = _target;
@synthesize failure = _failure;
@synthesize progress = _progress;

- (id)initWithCore:(yozora_core *)core {
    self = [super init];
    if (!self)
        return nil;
    _core = core;
    _valid = YES;
    _queue = dispatch_queue_create("yozora.translate", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)dealloc {
    _valid = NO;
    ++_generation;
    // what is queued still holds the object, so the queue is empty when this runs
    dispatch_release(_queue);
    [_source release];
    [_target release];
    [_failure release];
    [super dealloc];
}

- (void)setPhase:(YZTranslationPhase)phase progress:(float)progress failure:(NSString *)failure {
    _phase = phase;
    _progress = progress;
    [failure retain];
    [_failure release];
    _failure = failure;
    [_delegate translationDidChange:self];
}

- (void)setSource:(NSString *)source {
    [source retain];
    [_source release];
    _source = source;
}

- (void)setTarget:(NSString *)target {
    [target retain];
    [_target release];
    _target = target;
}

- (void)invalidate {
    _valid = NO;
    ++_generation;
    _core = NULL;
}

- (void)runScript:(NSString *)script completion:(void (^)(NSString *answer))completion {
    if (!_valid || !_core) {
        completion(nil);
        return;
    }
    yozora_core *core = _core;
    void (^done)(NSString *) = [completion copy];
    [self retain];
    dispatch_async(_queue, ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        char *answer = yozora_core_run_script(core, [script UTF8String]);
        NSString *text = answer ? [NSString stringWithUTF8String:answer] : nil;
        free(answer);
        dispatch_async(dispatch_get_main_queue(), ^{
            done(_valid ? text : nil);
            [done release];
            [self release];
        });
        [pool release];
    });
}

- (void)cancel {
    ++_generation;
    if (_phase != YZTranslationIdle)
        [self setPhase:YZTranslationIdle progress:0 failure:nil];
}

#pragma mark finding the language

- (void)pageDidLoad {
    if (!_valid || !_core)
        return;
    ++_generation;
    NSInteger generation = _generation;
    yozora_core *core = _core;
    _translatedOnce = NO;
    [self setSource:nil];
    if (_phase != YZTranslationIdle)
        [self setPhase:YZTranslationIdle progress:0 failure:nil];
    [self retain];
    dispatch_async(_queue, ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        id sampled = YZJSON(YZCall(core, @"yzTr.sample()"));
        NSDictionary *sample = [sampled isKindOfClass:[NSDictionary class]] ? sampled : nil;
        NSString *text = [sample objectForKey:@"text"];
        NSString *declared = [sample objectForKey:@"lang"];
        char code[16] = { 0 };
        int confidence = 0;
        if ([text isKindOfClass:[NSString class]]) {
            const char *bytes = [text UTF8String];
            confidence = yozora_tr_detect(bytes, strlen(bytes), [declared isKindOfClass:[NSString class]] ? [declared UTF8String] : NULL, code, sizeof code);
        }
        NSString *found = code[0] ? [NSString stringWithUTF8String:code] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation == _generation && _valid)
                [self languageFound:found confidence:confidence];
            [self release];
        });
        [pool release];
    });
}

// the page said what its text is: offered, translated at once, or left alone
- (void)languageFound:(NSString *)code confidence:(int)confidence {
    if (!code || confidence < 20)
        return;
    NSString *target = [YZSettings translateTarget];
    if (yozora_tr_language_find([code UTF8String]) == yozora_tr_language_find([target UTF8String]))
        return;
    if ([YZSettings translateNeverOffers:code])
        return;
    [self setSource:code];
    [self setTarget:target];
    if ([YZSettings translatesAtOnce:code] && [_delegate translationMayStartAlone:self]) {
        [self translateFrom:nil to:target];
        return;
    }
    [self setPhase:YZTranslationOffered progress:0 failure:nil];
}

#pragma mark translating

- (void)translateFrom:(NSString *)source to:(NSString *)target {
    if (!_valid || !_core || !target)
        return;
    ++_generation;
    NSInteger generation = _generation;
    yozora_core *core = _core;
    BOOL restoreFirst = _translatedOnce;
    _translatedOnce = YES;
    if (source)
        [self setSource:source];
    [self setTarget:target];
    NSString *from = [[source copy] autorelease];
    NSString *to = [[target copy] autorelease];
    [self setPhase:YZTranslationWorking progress:0 failure:nil];
    [self retain];
    dispatch_async(_queue, ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        if (restoreFirst)
            YZCall(core, @"yzTr.restore()");
        [self runFrom:from to:to core:core generation:generation];
        [pool release];
        [self release];
    });
}

- (BOOL)current:(NSInteger)generation {
    return _valid && generation == _generation;
}

- (void)failWith:(NSString *)text generation:(NSInteger)generation {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self current:generation])
            [self setPhase:YZTranslationFailed progress:0 failure:text];
    });
}

- (void)report:(float)progress generation:(NSInteger)generation {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self current:generation] && _phase == YZTranslationWorking)
            [self setPhase:YZTranslationWorking progress:progress failure:nil];
    });
}

// the whole translation on the work queue: everything the page holds now, then the page watched for what it adds
- (void)runFrom:(NSString *)source to:(NSString *)target core:(yozora_core *)core generation:(NSInteger)generation {
    NSString *failure = nil;
    if (![self translatePendingOfCore:core source:source target:target generation:generation failure:&failure]) {
        if ([self current:generation])
            [self failWith:failure generation:generation];
        return;
    }
    if (![self current:generation])
        return;
    YZCall(core, [NSString stringWithFormat:@"yzTr.watch(true, %@)", YZLiteral(target)]);
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self current:generation])
            [self setPhase:YZTranslationDone progress:1 failure:nil];
    });
    [self retain];
    [self pollCore:core source:source target:target generation:generation];
    [self release];
}

// what the page adds while it is translated is translated too: asked about once in a while, at a cost of one short call
- (void)pollCore:(yozora_core *)core source:(NSString *)source target:(NSString *)target generation:(NSInteger)generation {
    [self retain];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(YZPollSeconds * NSEC_PER_SEC)), _queue, ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        if ([self current:generation]) {
            NSString *dirty = YZCall(core, @"yzTr.dirty()");
            if (!dirty)
                [self invalidate];
            else {
                if ([dirty isEqualToString:@"1"]) {
                    NSString *failure = nil;
                    [self translatePendingOfCore:core source:source target:target generation:generation failure:&failure];
                }
                if ([self current:generation])
                    [self pollCore:core source:source target:target generation:generation];
            }
        }
        [pool release];
        [self release];
    });
}

// one pass: collect what is new, send in batches, put answers back. NO on a failure that stops the work, with
// its words
- (BOOL)translatePendingOfCore:(yozora_core *)core source:(NSString *)source target:(NSString *)target generation:(NSInteger)generation failure:(NSString **)failure {
    NSString *collected = YZCall(core, @"yzTr.collect()");
    NSDictionary *found = [YZJSON(collected) isKindOfClass:[NSDictionary class]] ? YZJSON(collected) : nil;
    NSArray *lengthList = [found objectForKey:@"lengths"];
    NSUInteger from = [[found objectForKey:@"from"] unsignedIntegerValue];
    if (!found || ![lengthList isKindOfClass:[NSArray class]]) {
        *failure = @"page";
        return NO;
    }
    size_t total = [lengthList count];
    if (!total)
        return YES;
    size_t *lengths = malloc(total * sizeof *lengths);
    if (!lengths) {
        *failure = @"memory";
        return NO;
    }
    for (size_t i = 0; i < total; ++i)
        lengths[i] = (size_t)[[lengthList objectAtIndex:i] unsignedIntegerValue];
    char url[512];
    BOOL ok = YES;
    if (!yozora_tr_url(source ? [source UTF8String] : "auto", [target UTF8String], url, sizeof url)) {
        *failure = @"request";
        ok = NO;
    }
    size_t done = 0;
    while (ok && done < total && [self current:generation]) {
        size_t count = yozora_tr_batch(lengths, total, done, YZBatchBytes, YZBatchItems);
        if (!count)
            break;
        NSString *texts = YZCall(core, [NSString stringWithFormat:@"yzTr.get(%lu, %lu)", (unsigned long)(from + done), (unsigned long)count]);
        NSArray *list = [YZJSON(texts) isKindOfClass:[NSArray class]] ? YZJSON(texts) : nil;
        if ([list count] != count) {
            *failure = @"page";
            ok = NO;
            break;
        }
        NSArray *answers = [self translateBatch:list url:url failure:failure generation:generation];
        if (![self current:generation])
            break;
        if (!answers) {
            ok = NO;
            break;
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:answers options:0 error:NULL];
        NSString *jsonText = json ? [[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] autorelease] : nil;
        if (jsonText)
            YZCall(core, [NSString stringWithFormat:@"yzTr.put(%lu, %@)", (unsigned long)(from + done), YZLiteral(jsonText)]);
        done += count;
        [self report:(float)done / (float)total generation:generation];
    }
    free(lengths);
    return ok;
}

// one request. a network failure is retried twice with a growing pause, a refusal of the service is not.
// answers come in list order, an empty string for a text the service did not return
- (NSArray *)translateBatch:(NSArray *)list url:(const char *)url failure:(NSString **)failure generation:(NSInteger)generation {
    size_t count = [list count];
    const char **texts = malloc(count * sizeof *texts);
    size_t estimate = 64;
    for (NSString *text in list)
        estimate += [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] * 9 + 48;
    char *body = malloc(estimate);
    if (!texts || !body) {
        free(texts);
        free(body);
        *failure = @"memory";
        return nil;
    }
    for (size_t i = 0; i < count; ++i)
        texts[i] = [[list objectAtIndex:i] UTF8String];
    size_t length = yozora_tr_body(texts, 0, count, body, estimate);
    free(texts);
    if (!length) {
        free(body);
        *failure = @"request";
        return nil;
    }
    NSArray *result = nil;
    for (int attempt = 0; attempt < 3 && [self current:generation]; ++attempt) {
        if (attempt)
            [NSThread sleepForTimeInterval:0.6 * attempt];
        char *answer = NULL;
        size_t answer_length = 0;
        char error[128];
        int status = yozora_http_post(url, "application/x-www-form-urlencoded", body, length, 20, &answer, &answer_length, error, sizeof error);
        if (status < 0) {
            *failure = @"network";
            continue;
        }
        size_t arena_size = answer_length + 64;
        char *arena = malloc(arena_size);
        const char **items = malloc(count * sizeof *items);
        char detected[16];
        yozora_tr_status parsed = arena && items ? yozora_tr_parse(answer, answer_length, count, arena, arena_size, items, detected, sizeof detected) : YOZORA_TR_TOO_LONG;
        if (parsed == YOZORA_TR_OK || parsed == YOZORA_TR_PARTIAL) {
            NSMutableArray *answers = [NSMutableArray arrayWithCapacity:count];
            for (size_t i = 0; i < count; ++i)
                [answers addObject:items[i] ? ([NSString stringWithUTF8String:items[i]] ?: @"") : @""];
            result = answers;
        } else if (parsed == YOZORA_TR_BLOCKED || status == 429) {
            *failure = @"blocked";
            attempt = 3;
        } else {
            *failure = status == 200 ? @"answer" : @"service";
            if (status >= 400 && status < 500)
                attempt = 3;
        }
        free(items);
        free(arena);
        free(answer);
        if (result)
            break;
    }
    free(body);
    return result;
}

- (void)showOriginal {
    if (!_valid || !_core)
        return;
    ++_generation;
    NSInteger generation = _generation;
    yozora_core *core = _core;
    _translatedOnce = NO;
    [self retain];
    dispatch_async(_queue, ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        YZCall(core, @"yzTr.restore()");
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self current:generation])
                [self setPhase:YZTranslationOffered progress:0 failure:nil];
            [self release];
        });
        [pool release];
    });
}

@end
