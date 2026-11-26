#import "YZHomeBackgroundEditor.h"
#import <QuartzCore/QuartzCore.h>
#import "YZBackground.h"
#import "YZCompat.h"
#import "YZControls.h"
#import "YZDialog.h"
#import "YZHomeView.h"
#import "YZMotion.h"
#import "YZSettings.h"
#import "YZStrings.h"
#import "YZTheme.h"

static const CGFloat YZEditorPad = 10;
static const CGFloat YZEditorButton = 36;

@implementation YZHomeBackgroundEditor

- (id)initWithHome:(YZHomeView *)home host:(UIViewController *)host changed:(void (^)(void))changed finished:(void (^)(void))finished {
    self = [super initWithFrame:CGRectZero];
    if (!self)
        return nil;
    _home = home;
    _host = host;
    _changed = [changed copy];
    _finished = [finished copy];
    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.layer.shadowColor = [[UIColor blackColor] CGColor];
    _card.layer.shadowOpacity = 0.18f;
    _card.layer.shadowRadius = 10;
    _card.layer.shadowOffset = CGSizeMake(0, 3);
    [self addSubview:_card];
    _heading = [[UILabel alloc] initWithFrame:CGRectZero];
    _heading.backgroundColor = [UIColor clearColor];
    _heading.textAlignment = YZTextAlignmentCenter;
    [_card addSubview:_heading];
    for (int i = 0; i < 4; ++i) {
        UIButton *button = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
        button.layer.cornerRadius = 18;
        [_card addSubview:button];
        if (i == 0)
            _choose = button;
        else if (i == 1)
            _remove = button;
        else if (i == 2)
            _option = button;
        else
            _done = button;
    }
    [_option addTarget:self action:@selector(toggleOption) forControlEvents:UIControlEventTouchUpInside];
    [_choose addTarget:self action:@selector(choosePicture) forControlEvents:UIControlEventTouchUpInside];
    [_remove addTarget:self action:@selector(removePicture) forControlEvents:UIControlEventTouchUpInside];
    [_done addTarget:self action:@selector(finish) forControlEvents:UIControlEventTouchUpInside];
    [self restyle];
    return self;
}

- (void)dealloc {
    _popover.delegate = nil;
    [_popover release];
    [_card release];
    [_heading release];
    [_choose release];
    [_remove release];
    [_option release];
    [_done release];
    [_changed release];
    [_finished release];
    [super dealloc];
}

// only the card takes touches, the page under it is not used while the photo is edited
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}

- (void)showState {
    UIImage *picture = [YZBackground image];
    _heading.text = YZT(@"Фон");
    _remove.hidden = picture == nil;
    // the gradient stands where no photo does, and only in the modern design: the classic and the flat ones keep their own ground
    _option.hidden = picture || [YZTheme isClassic] || [YZTheme isFlat];
    [_option setTitle:[YZSettings homeGradient] ? YZT(@"Убрать градиент") : YZT(@"Градиент из акцента") forState:UIControlStateNormal];
    [_choose setTitle:picture ? YZT(@"Другое фото") : YZT(@"Выбрать фото") forState:UIControlStateNormal];
    _choose.enabled = !_storing;
    [self setNeedsLayout];
}

- (void)restyle {
    // a little see-through, the page and the photo show faintly behind it
    _card.backgroundColor = [[YZTheme cardColor] colorWithAlphaComponent:0.94f];
    _card.layer.cornerRadius = MIN([YZTheme sheetRadius], (CGFloat)18);
    _heading.font = [YZTheme boldSystemFontOfSize:15];
    _heading.textColor = [YZTheme accentColor];
    for (UIButton *button in [NSArray arrayWithObjects:_choose, _remove, _option, _done, nil]) {
        button.backgroundColor = [YZTheme surfaceColor];
        button.titleLabel.font = [YZTheme boldSystemFontOfSize:14];
    }
    [_choose setTitleColor:[YZTheme accentColor] forState:UIControlStateNormal];
    [_option setTitleColor:[YZTheme accentColor] forState:UIControlStateNormal];
    [_done setTitle:YZT(@"Готово") forState:UIControlStateNormal];
    [_done setTitleColor:[YZTheme accentColor] forState:UIControlStateNormal];
    [_remove setTitle:YZT(@"Убрать фон") forState:UIControlStateNormal];
    [_remove setTitleColor:[UIColor colorWithRed:0.86f green:0.22f blue:0.22f alpha:1] forState:UIControlStateNormal];
    [self showState];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat viewWidth = self.bounds.size.width, viewHeight = self.bounds.size.height;
    CGFloat width = MIN((CGFloat)340, viewWidth - 32);
    BOOL removable = !_remove.hidden, optional = !_option.hidden;
    CGFloat height = YZEditorPad + 20 + 8 + YZEditorButton + 6 + YZEditorButton + YZEditorPad + (optional ? 6 + YZEditorButton : 0);
    CGFloat bottom = viewHeight - 10;
    CGFloat top = MAX((CGFloat)8, bottom - height);
    _card.frame = CGRectMake(floor((viewWidth - width) / 2), top, width, bottom - top);
    _card.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_card.bounds cornerRadius:_card.layer.cornerRadius].CGPath;
    _heading.frame = CGRectMake(YZEditorPad, YZEditorPad, width - 2 * YZEditorPad, 20);
    CGFloat rowTop = YZEditorPad + 20 + 8;
    CGFloat buttonWidth = removable ? floor((width - 3 * YZEditorPad) / 2) : width - 2 * YZEditorPad;
    _choose.frame = CGRectMake(YZEditorPad, rowTop, buttonWidth, YZEditorButton);
    _remove.frame = CGRectMake(YZEditorPad * 2 + buttonWidth, rowTop, buttonWidth, YZEditorButton);
    if (optional) {
        rowTop += YZEditorButton + 6;
        _option.frame = CGRectMake(YZEditorPad, rowTop, width - 2 * YZEditorPad, YZEditorButton);
    }
    _done.frame = CGRectMake(YZEditorPad, rowTop + YZEditorButton + 6, width - 2 * YZEditorPad, YZEditorButton);
}

- (void)presentInView:(UIView *)parent {
    _pageWasInteractive = _home.userInteractionEnabled;
    _home.userInteractionEnabled = NO;
    self.frame = parent.bounds;
    [parent addSubview:self];
    [self layoutIfNeeded];
    _card.alpha = 0;
    _card.transform = CGAffineTransformMakeTranslation(0, 24);
    YZMotionAnimateView(_card, CGAffineTransformIdentity, 1, YOZORA_MOTION_WOBBLE, 0, nil);
}

- (void)finish {
    _home.userInteractionEnabled = _pageWasInteractive;
    [self retain];
    YZMotionAnimateView(_card, CGAffineTransformMakeTranslation(0, 24), 0, YOZORA_MOTION_DISMISS, 0, ^(BOOL finished) {
        (void)finished;
        [self removeFromSuperview];
        if (_finished)
            _finished();
        [self autorelease];
    });
}

- (void)choosePicture {
    if (_storing || ![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary])
        return;
    UIImagePickerController *picker = [[[UIImagePickerController alloc] init] autorelease];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.delegate = self;
    // the photo library of an ipad is shown in a popover, a full screen one is refused by the system before ios 13
    if ([YZTheme isPad] && NSClassFromString(@"UIPopoverController")) {
        _popover = [[UIPopoverController alloc] initWithContentViewController:picker];
        _popover.delegate = self;
        [_popover presentPopoverFromRect:_choose.bounds inView:_choose permittedArrowDirections:UIPopoverArrowDirectionAny animated:YES];
    } else {
        [_host presentViewController:picker animated:YES completion:nil];
    }
}

- (void)closePicker {
    if (_popover) {
        [_popover dismissPopoverAnimated:YES];
        _popover.delegate = nil;
        [_popover release];
        _popover = nil;
    } else {
        [_host dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)popoverControllerDidDismissPopover:(UIPopoverController *)popover {
    if (popover == _popover) {
        _popover.delegate = nil;
        [_popover release];
        _popover = nil;
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    (void)picker;
    [self closePicker];
}

// a photo is decoded and cut down away from the main thread, a large one takes seconds on an old phone
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
    (void)picker;
    UIImage *picture = [info objectForKey:UIImagePickerControllerOriginalImage];
    [self closePicker];
    if (!picture)
        return;
    _storing = YES;
    [self showState];
    [picture retain];
    [self retain];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        BOOL stored = [YZBackground storePicture:picture];
        [picture release];
        dispatch_async(dispatch_get_main_queue(), ^{
            _storing = NO;
            if (stored) {
                if (_changed)
                    _changed();
            } else {
                YZDialog *dialog = [YZDialog dialogWithTitle:YZT(@"Фон не сохранён") message:YZT(@"Не удалось записать фото, возможно, на устройстве нет места")
                                                 cancelTitle:nil confirmTitle:YZT(@"Хорошо") destructive:NO handler:nil];
                dialog.picture = [YZTheme mascotImage:@"error"];
                [dialog showInView:_host.view];
            }
            [self showState];
            [self release];
        });
        [pool drain];
    });
}

// a page without a photo turns its gradient on or off
- (void)toggleOption {
    [YZSettings setHomeGradient:![YZSettings homeGradient]];
    [YZTheme animateFeedbackOfView:_option];
    if (_changed)
        _changed();
    [self showState];
}

- (void)removePicture {
    [YZBackground remove];
    [YZTheme animateFeedbackOfView:_remove];
    if (_changed)
        _changed();
    [self showState];
}

@end
