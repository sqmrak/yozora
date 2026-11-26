#import <Foundation/Foundation.h>

/* dictation for the address field: a press on the microphone listens, the words arrive as text while they are spoken and the last version ends the
   listening. it is the speech recognition of the system (SFSpeechRecognizer, ios 10 and later), looked up at run time, so the armv7 sdk, which has no
   such header, and a system that has no recognizer both build and run: there `available` is NO and the key is not shown */
@interface YZVoiceInput : NSObject {
    id _recognizer;
    id _request;
    id _task;
    id _engine;
    BOOL _listening;
    NSUInteger _session;
    void (^_partial)(NSString *text, BOOL final);
    void (^_failed)(NSString *reason);
}
/* the system has a recognizer for the language of the app and it works now */
+ (BOOL)available;
@property(nonatomic, readonly, getter=isListening) BOOL listening;
/* asks for the permissions the first time, then listens. partial gets the text so far (final is YES for the last one), failed gets a sentence for the
   person when the permission is refused or the microphone cannot be opened. both run on the main thread */
- (void)startWithPartial:(void (^)(NSString *text, BOOL final))partial failed:(void (^)(NSString *reason))failed;
/* ends the listening, what was heard so far is reported as the last version */
- (void)stop;
@end
