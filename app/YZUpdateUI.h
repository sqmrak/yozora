#import <UIKit/UIKit.h>
#import "YZUpdate.h"
#import "YZControls.h"

/* the wave bar with a handle in the modern design, the glossy bar of ios 6 in the classic one */
@interface YZUpdateProgress : UIView
@property(nonatomic, assign) float fraction;
- (void)applyTheme;
@end

/* the sticker, the versions, the button, the progress and the notes, for the card and for the settings screen */
@interface YZUpdatePanel : UIView {
    BOOL _compact;
    YZRelease *_release;
    NSString *_signature;
    UIImageView *_sticker;
    NSMutableArray *_items;
    YZUpdateProgress *_progress;
    UILabel *_status;
    void (^_openPage)(void);
    void (^_later)(void);
    void (^_resize)(void);
}
/* the card shows the notes short and can postpone, the screen shows all and can check again */
@property(nonatomic, assign) BOOL compact;
@property(nonatomic, copy) void (^openPage)(void);
@property(nonatomic, copy) void (^later)(void);
/* the content changed its height */
@property(nonatomic, copy) void (^resize)(void);
- (CGFloat)layoutForWidth:(CGFloat)width;
@end

@interface YZUpdateCard : UIView {
    UIView *_card;
    UIScrollView *_scroll;
    YZUpdatePanel *_panel;
}
/* one card at a time */
+ (void)presentInView:(UIView *)host openPage:(void (^)(void))openPage;
@end

@interface YZUpdateController : UIViewController {
    YZBarFill *_fill;
    UIScrollView *_scroll;
    UIView *_card;
    YZUpdatePanel *_panel;
    void (^_openPage)(void);
}
@property(nonatomic, copy) void (^openPage)(void);
@end
