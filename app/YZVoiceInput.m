#import "YZVoiceInput.h"
#import <UIKit/UIKit.h>
#import "YZSettings.h"
#import "YZStrings.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>

// the longest listening, a silence ends it earlier by itself
static const NSTimeInterval YZVoiceLimit = 20;

static void YZLoadSpeech(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // not linked: the framework does not exist before ios 10, and the armv7 slice must not need it at launch
        [[NSBundle bundleWithPath:@"/System/Library/Frameworks/Speech.framework"] load];
    });
}

// the locale of the recognizer follows the language of the app
static NSLocale *YZVoiceLocale(void) {
    switch ([YZSettings language]) {
    case YZLanguageEnglish: return [[[NSLocale alloc] initWithLocaleIdentifier:@"en-US"] autorelease];
    case YZLanguageJapanese: return [[[NSLocale alloc] initWithLocaleIdentifier:@"ja-JP"] autorelease];
    default: return [[[NSLocale alloc] initWithLocaleIdentifier:@"ru-RU"] autorelease];
    }
}

static id YZSend0(id target, const char *name) {
    return ((id (*)(id, SEL))(void *)objc_msgSend)(target, NSSelectorFromString([NSString stringWithUTF8String:name]));
}

static BOOL YZSendBool0(id target, const char *name) {
    return ((BOOL (*)(id, SEL))(void *)objc_msgSend)(target, NSSelectorFromString([NSString stringWithUTF8String:name]));
}

@implementation YZVoiceInput

@synthesize listening = _listening;

+ (BOOL)available {
    if ([[[UIDevice currentDevice] systemVersion] floatValue] < 10.0f)
        return NO;
    YZLoadSpeech();
    Class recognizerClass = NSClassFromString(@"SFSpeechRecognizer");
    if (!recognizerClass || !NSClassFromString(@"AVAudioEngine") || !NSClassFromString(@"SFSpeechAudioBufferRecognitionRequest"))
        return NO;
    id recognizer = ((id (*)(id, SEL, id))(void *)objc_msgSend)([recognizerClass alloc], NSSelectorFromString(@"initWithLocale:"), YZVoiceLocale());
    BOOL usable = recognizer && YZSendBool0(recognizer, "isAvailable");
    [recognizer release];
    return usable;
}

- (void)dealloc {
    [self teardown];
    [_partial release];
    [_failed release];
    [super dealloc];
}

- (void)fail:(NSString *)reason {
    void (^failed)(NSString *) = [[_failed retain] autorelease];
    [self teardown];
    if (failed)
        failed(reason);
}

// the engine, the tap, the request and the task are let go in the order they were made, once
- (void)teardown {
    ++_session;
    _listening = NO;
    if (_engine) {
        if (YZSendBool0(_engine, "isRunning"))
            ((void (*)(id, SEL))(void *)objc_msgSend)(_engine, NSSelectorFromString(@"stop"));
        id input = YZSend0(_engine, "inputNode");
        if (input)
            ((void (*)(id, SEL, NSUInteger))(void *)objc_msgSend)(input, NSSelectorFromString(@"removeTapOnBus:"), 0);
    }
    if (_request)
        ((void (*)(id, SEL))(void *)objc_msgSend)(_request, NSSelectorFromString(@"endAudio"));
    if (_task)
        ((void (*)(id, SEL))(void *)objc_msgSend)(_task, NSSelectorFromString(@"cancel"));
    [_engine release];
    _engine = nil;
    [_request release];
    _request = nil;
    [_task release];
    _task = nil;
    [_recognizer release];
    _recognizer = nil;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(stop) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(teardown) object:nil];
    [[AVAudioSession sharedInstance] setActive:NO error:NULL];
}

- (void)startWithPartial:(void (^)(NSString *, BOOL))partial failed:(void (^)(NSString *))failed {
    if (_listening)
        return;
    [_partial release];
    _partial = [partial copy];
    [_failed release];
    _failed = [failed copy];
    YZLoadSpeech();
    Class recognizerClass = NSClassFromString(@"SFSpeechRecognizer");
    if (!recognizerClass) {
        [self fail:YZT(@"Голосовой ввод на этой версии iOS недоступен")];
        return;
    }
    NSUInteger session = ++_session;
    void (^answer)(NSInteger) = ^(NSInteger status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // 3 is authorized. a press that was ended or repeated while the question was on the screen is not this one
            if (session != _session)
                return;
            if (status != 3) {
                [self fail:YZT(@"Нет разрешения на распознавание речи: его можно дать в настройках iOS")];
                return;
            }
            [AVAudioSession sharedInstance];
            [self listen];
        });
    };
    ((void (*)(id, SEL, void (^)(NSInteger)))(void *)objc_msgSend)(recognizerClass, NSSelectorFromString(@"requestAuthorization:"), [[answer copy] autorelease]);
}

- (void)listen {
    NSError *error = nil;
    AVAudioSession *audio = [AVAudioSession sharedInstance];
    if (![audio setCategory:AVAudioSessionCategoryRecord error:&error] || ![audio setActive:YES error:&error]) {
        NSLog(@"yozora: voice input: the audio session was refused: %@", error);
        [self fail:YZT(@"Не удалось включить микрофон")];
        return;
    }
    Class recognizerClass = NSClassFromString(@"SFSpeechRecognizer");
    Class requestClass = NSClassFromString(@"SFSpeechAudioBufferRecognitionRequest");
    Class engineClass = NSClassFromString(@"AVAudioEngine");
    _recognizer = ((id (*)(id, SEL, id))(void *)objc_msgSend)([recognizerClass alloc], NSSelectorFromString(@"initWithLocale:"), YZVoiceLocale());
    if (!_recognizer || !YZSendBool0(_recognizer, "isAvailable")) {
        [self fail:YZT(@"Распознавание речи сейчас недоступно")];
        return;
    }
    _request = [[requestClass alloc] init];
    ((void (*)(id, SEL, BOOL))(void *)objc_msgSend)(_request, NSSelectorFromString(@"setShouldReportPartialResults:"), YES);
    _engine = [[engineClass alloc] init];
    id input = YZSend0(_engine, "inputNode");
    id format = ((id (*)(id, SEL, NSUInteger))(void *)objc_msgSend)(input, NSSelectorFromString(@"outputFormatForBus:"), 0);
    id request = _request;
    void (^tap)(id, id) = ^(id buffer, id when) {
        (void)when;
        ((void (*)(id, SEL, id))(void *)objc_msgSend)(request, NSSelectorFromString(@"appendAudioPCMBuffer:"), buffer);
    };
    ((void (*)(id, SEL, NSUInteger, uint32_t, id, void (^)(id, id)))(void *)objc_msgSend)(input, NSSelectorFromString(@"installTapOnBus:bufferSize:format:block:"),
                                                                              0, 1024, format, [[tap copy] autorelease]);
    ((void (*)(id, SEL))(void *)objc_msgSend)(_engine, NSSelectorFromString(@"prepare"));
    NSError *started = nil;
    BOOL ok = ((BOOL (*)(id, SEL, NSError **))(void *)objc_msgSend)(_engine, NSSelectorFromString(@"startAndReturnError:"), &started);
    if (!ok) {
        NSLog(@"yozora: voice input: the engine did not start: %@", started);
        [self fail:YZT(@"Не удалось включить микрофон")];
        return;
    }
    NSUInteger session = _session;
    void (^handler)(id, NSError *) = ^(id result, NSError *failure) {
        NSString *text = nil;
        BOOL final = NO;
        if (result) {
            id transcription = YZSend0(result, "bestTranscription");
            text = transcription ? YZSend0(transcription, "formattedString") : nil;
            final = YZSendBool0(result, "isFinal");
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (session != _session)
                return;
            if ([text length] && _partial)
                _partial(text, final);
            if (final)
                [self teardown];
            else if (failure && !result)
                [self fail:YZT(@"Речь не распознана")];
        });
    };
    _task = [((id (*)(id, SEL, id, void (^)(id, NSError *)))(void *)objc_msgSend)(_recognizer, NSSelectorFromString(@"recognitionTaskWithRequest:resultHandler:"),
                                                                           _request, [[handler copy] autorelease]) retain];
    _listening = YES;
    [self performSelector:@selector(stop) withObject:nil afterDelay:YZVoiceLimit];
}

// the audio ends, the recognizer answers with the last words and that answer closes everything. a task that never answers is cut at the limit
- (void)stop {
    if (!_listening)
        return;
    _listening = NO;
    if (_engine) {
        if (YZSendBool0(_engine, "isRunning"))
            ((void (*)(id, SEL))(void *)objc_msgSend)(_engine, NSSelectorFromString(@"stop"));
        id input = YZSend0(_engine, "inputNode");
        if (input)
            ((void (*)(id, SEL, NSUInteger))(void *)objc_msgSend)(input, NSSelectorFromString(@"removeTapOnBus:"), 0);
    }
    if (_request)
        ((void (*)(id, SEL))(void *)objc_msgSend)(_request, NSSelectorFromString(@"endAudio"));
    [self performSelector:@selector(teardown) withObject:nil afterDelay:3];
}

@end
