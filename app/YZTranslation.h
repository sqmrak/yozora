#import <Foundation/Foundation.h>
#include "yozora_core.h"

typedef enum {
    /* nothing to offer: no page, no text, or the page is in the language asked for */
    YZTranslationIdle,
    /* the language of the page is known and differs from the target */
    YZTranslationOffered,
    /* the texts of the page are being sent and put back, progress says how far */
    YZTranslationWorking,
    /* the page is translated, and what it adds later is translated as it comes */
    YZTranslationDone,
    /* the service did not answer, failure says why */
    YZTranslationFailed
} YZTranslationPhase;

@class YZTranslation;

@protocol YZTranslationDelegate <NSObject>
/* the phase, the progress or a language changed. always on the main thread */
- (void)translationDidChange:(YZTranslation *)translation;
/* the page asks to be translated at once (the person chose that for its language): false keeps it offered, for a private tab */
- (BOOL)translationMayStartAlone:(YZTranslation *)translation;
@end

/* translation of one core's page: the language is found on the device, the library collects texts in the
   page's isolated world, they go to the service in batches and come back where they were. it runs on its own
   queue and never touches the page from the interface thread. invalidate drops what is on its way */
@interface YZTranslation : NSObject {
    yozora_core *_core;
    id<YZTranslationDelegate> _delegate;
    YZTranslationPhase _phase;
    NSString *_source;
    NSString *_target;
    NSString *_failure;
    float _progress;
    dispatch_queue_t _queue;
    volatile NSInteger _generation;
    volatile BOOL _valid;
    BOOL _translatedOnce;
}
@property(nonatomic, assign) id<YZTranslationDelegate> delegate;
@property(nonatomic, readonly) YZTranslationPhase phase;
/* the code of the language of the page as found, or chosen */
@property(nonatomic, readonly, copy) NSString *source;
@property(nonatomic, readonly, copy) NSString *target;
@property(nonatomic, readonly, copy) NSString *failure;
/* 0 to 1 while working */
@property(nonatomic, readonly) float progress;
- (id)initWithCore:(yozora_core *)core;
/* a document finished loading: its language is found, and the page is offered, translated at once or left alone */
- (void)pageDidLoad;
/* sends the page to the service, source is a code or nil to let the service find it. a translated page is
   first given back as it was */
- (void)translateFrom:(NSString *)source to:(NSString *)target;
/* the page is given back as it was, and offered again */
- (void)showOriginal;
/* stops what is running and goes back to nothing, for a page that is gone or a person who dismissed the offer */
- (void)cancel;
/* runs a script in the isolated world of the page on the queue of the translation and gives its string answer on the main
   queue, nil when it threw or the core went away in the meantime */
- (void)runScript:(NSString *)script completion:(void (^)(NSString *answer))completion;
/* the core is going away */
- (void)invalidate;
@end
