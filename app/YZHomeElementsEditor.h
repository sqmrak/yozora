#import <UIKit/UIKit.h>

@class YZHomeView;

/* the parts of the start page as switches on a card at the foot of the page: the logo, the line under it, the search line and the recent
   sites, and a field for the text of the line. the page stays under the card and shows every change at once. the page takes no touches
   while the card is up. the browser adds it over the page, and it removes itself when done */
@interface YZHomeElementsEditor : UIView <UITextFieldDelegate> {
    YZHomeView *_home;
    UIView *_card;
    NSMutableArray *_labels;
    NSMutableArray *_toggles;
    UITextField *_field;
    UIButton *_done;
    CGFloat _keyboardHeight;
    BOOL _pageWasInteractive;
    void (^_changed)(void);
    void (^_finished)(void);
}
/* changed runs after a part or the text changed and the page has to lay out again, finished once the card has left */
- (id)initWithHome:(YZHomeView *)home changed:(void (^)(void))changed finished:(void (^)(void))finished;
- (void)presentInView:(UIView *)parent;
@end
