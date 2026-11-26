#import <UIKit/UIKit.h>

/* a material 3 bottom sheet: a scrim and a panel with a handle rising on the emphasized curve, a title and an
   optional done button. the scrim or the system cancel closes it. an ipad panel is a column of up to 560
   points. the blocks run once on the main thread after the sheet starts to leave */
@interface YZSheet : UIView <UIGestureRecognizerDelegate> {
    UIView *_panel;
    UIView *_panelBack;
    // the lit plate of the classic design, in place of the picture of the modern panel
    UIView *_panelPlate;
    CGFloat _headerHeight;
    UIView *_content;
    UILabel *_titleLabel;
    UIButton *_doneButton;
    CGFloat _contentHeight;
    CGFloat _bottomInset;
    BOOL _closing;
    void (^_onCancel)(void);
    void (^_onDone)(void);
}
/* what the sheet shows between its header and the bottom, and how tall it wants to be: it is held to 70 percent of its host */
@property(nonatomic, retain) UIView *content;
@property(nonatomic, assign) CGFloat contentHeight;
/* the distance from the bottom of the host to the panel, the home indicator of the host */
@property(nonatomic, assign) CGFloat bottomInset;
@property(nonatomic, copy) void (^onCancel)(void);
@property(nonatomic, copy) void (^onDone)(void);
@property(nonatomic, readonly, getter=isClosing) BOOL closing;
- (void)setTitle:(NSString *)title doneTitle:(NSString *)doneTitle;
/* an address is cut in its middle, so the host and the end of the path both stay readable */
- (void)truncateTitleInMiddle;
/* adds the sheet to host and lets the panel rise */
- (void)presentInView:(UIView *)host;
/* the panel sinks and the sheet leaves its host, with no block run */
- (void)dismissAnimated:(BOOL)animated;
@end

/* the lists and pickers the page asks for. every call returns the sheet it shows, so the caller can close it when the page goes away */
@interface YZPickers : NSObject
/* a select: texts with YOZORA_CHOICE_* flags, the item chosen now (a check mark), the block gets the tapped
   index or -1 when closed */
+ (YZSheet *)presentChoicesInView:(UIView *)host title:(NSString *)title texts:(NSArray *)texts flags:(NSArray *)flags selected:(NSInteger)selected
                      bottomInset:(CGFloat)bottomInset completion:(void (^)(NSInteger index))completion;
/* actions: a glyph in the accent color and a text per row, a tap answers with the row index and closes, any
   other close answers -1. the title is cut in the middle, the way an address reads best */
+ (YZSheet *)presentActionsInView:(UIView *)host title:(NSString *)title texts:(NSArray *)texts icons:(NSArray *)icons bottomInset:(CGFloat)bottomInset
                       completion:(void (^)(NSInteger index))completion;
/* a select with the multiple attribute: items with a check box, the chosen ones (YOZORA_CHOICE_SELECTED)
   marked, a done button. the answer is the set of indexes that stay chosen, nil when closed any other way */
+ (YZSheet *)presentMultipleChoicesInView:(UIView *)host title:(NSString *)title texts:(NSArray *)texts flags:(NSArray *)flags
                              bottomInset:(CGFloat)bottomInset completion:(void (^)(NSIndexSet *chosen))completion;
/* a color field: the picker sheet with the field color ("#RRGGBB"), the answer in the same form or nil when
   cancelled */
+ (YZSheet *)presentColorInView:(UIView *)host value:(NSString *)value bottomInset:(CGFloat)bottomInset completion:(void (^)(NSString *hex))completion;
/* a date field: the picker of the type with the field value, the answer in the format of the type or nil when
   cancelled. minimum, maximum and step are in what the page counts (milliseconds, months for a month field) */
+ (YZSheet *)presentDateInView:(UIView *)host type:(NSString *)type value:(NSString *)value minimum:(double)minimum maximum:(double)maximum step:(double)step
                   bottomInset:(CGFloat)bottomInset completion:(void (^)(NSString *value))completion;
@end

/* files for a file field: a sheet of where files come from (photos, the downloads folder, the Files app where
   the system has it) then the picker of the chosen place. the paths are readable until the app ends. the
   object keeps itself alive until it has answered */
@interface YZFilePicker : NSObject {
    UIViewController *_host;
    UIView *_hostView;
    YZSheet *_sheet;
    BOOL _multiple;
    NSString *_accept;
    CGFloat _bottomInset;
    id _picker;
    CFAbsoluteTime _documentsOpenedAt;
    UIPopoverController *_popover;
    void (^_completion)(NSArray *paths);
}
- (id)initWithHost:(UIViewController *)host accept:(NSString *)accept multiple:(BOOL)multiple bottomInset:(CGFloat)bottomInset completion:(void (^)(NSArray *paths))completion;
- (void)present;
/* whether any place has something to offer for this accept list: photos, a downloads folder with a file in it, the device storage where the process may
   read it, the system picker. a caller that is not a page tells the person what to do instead of opening an empty sheet */
+ (BOOL)hasSourceForAccept:(NSString *)accept;
/* the page is gone: everything shown is closed and the answer is an empty list */
- (void)cancel;
@end
