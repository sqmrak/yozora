#import <UIKit/UIKit.h>

typedef enum {
    YZMenuNewTab,
    YZMenuBookmarks,
    YZMenuHistory,
    YZMenuDownloads,
    YZMenuCopyAddress,
    YZMenuSettings,
    YZMenuLeavePrivate,
    YZMenuFindInPage,
    YZMenuShare,
    YZMenuTranslate,
    YZMenuAdblock
} YZMenuItem;

@protocol YZMenuViewDelegate;

/* the material 3 menu: a compact card that grows out of the menu button at the bottom right, rows of a glyph
   and a title, a tap outside closes it */
@interface YZMenuView : UIView {
    id<YZMenuViewDelegate> _delegate;
    UIView *_panel;
    CGFloat _bottomInset;
    CGFloat _rightInset;
    CGFloat _topInset;
    BOOL _anchorsTop;
    // the classic design asks with the action sheet of the system and builds no card
    NSArray *_items;
    NSArray *_titles;
    id _sheet;
}
@property(nonatomic, assign) id<YZMenuViewDelegate> delegate;
/* the distance from the bottom of the view to the card, which is the height of the bottom bar and the home indicator */
@property(nonatomic, assign) CGFloat bottomInset;
/* the distance from the right edge of the view to the card */
@property(nonatomic, assign) CGFloat rightInset;
/* a wide screen has the menu button in the top toolbar, the card hangs from topInset and grows from its top
   right corner */
@property(nonatomic, assign) BOOL anchorsTop;
@property(nonatomic, assign) CGFloat topInset;
/* items are YZMenuItem values boxed in NSNumber, titles come from the caller where they change */
- (void)showItems:(NSArray *)items titles:(NSArray *)titles icons:(NSArray *)icons;
/* the card grows from its bottom right corner with the wobble, call it once the menu is in its superview */
- (void)present;
/* the card shrinks back into the corner and the menu ignores touches meanwhile, the block runs when it is gone */
- (void)dismissWithCompletion:(void (^)(void))completion;
@end

@protocol YZMenuViewDelegate <NSObject>
- (void)menuView:(YZMenuView *)view didSelectItem:(YZMenuItem)item;
- (void)menuViewDidDismiss:(YZMenuView *)view;
@end
