#import <UIKit/UIKit.h>

@class YZHomeView;

/* the controls of the background of the start page, drawn on the start page itself: a card at the foot of the page with a button for a photo of
   the library, one that takes it away, one that turns the gradient of the accent on while there is no photo, and one that ends the editing. the
   page stays under it and shows every change. the page takes no touches while the card is up. it is added over the page by the browser and
   removes itself when done */
@interface YZHomeBackgroundEditor : UIView <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIPopoverControllerDelegate> {
    YZHomeView *_home;
    UIViewController *_host;
    UIView *_card;
    UILabel *_heading;
    UIButton *_choose;
    UIButton *_remove;
    UIButton *_done;
    // without a photo it turns the gradient of the accent on and off (modern design only)
    UIButton *_option;
    UIPopoverController *_popover;
    BOOL _storing;
    BOOL _pageWasInteractive;
    void (^_changed)(void);
    void (^_finished)(void);
}
/* home is the page that shows the photo, host presents the photo library. changed runs after the photo or the gradient was stored, finished once the
   card has left */
- (id)initWithHome:(YZHomeView *)home host:(UIViewController *)host changed:(void (^)(void))changed finished:(void (^)(void))finished;
- (void)presentInView:(UIView *)parent;
/* the theme changed under the card */
- (void)restyle;
@end
