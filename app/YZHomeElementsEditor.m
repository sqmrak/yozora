#import "YZHomeElementsEditor.h"
#import <QuartzCore/QuartzCore.h>
#import "YZCompat.h"
#import "YZControls.h"
#import "YZHomeView.h"
#import "YZMotion.h"
#import "YZSettings.h"
#import "YZStrings.h"
#import "YZTheme.h"

static const CGFloat YZElementsPad = 12;
static const CGFloat YZElementsRow = 44;

@implementation YZHomeElementsEditor

- (id)initWithHome:(YZHomeView *)home changed:(void (^)(void))changed finished:(void (^)(void))finished {
    self = [super initWithFrame:CGRectZero];
    if (!self)
        return nil;
    _home = home;
    _changed = [changed copy];
    _finished = [finished copy];
    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.layer.shadowColor = [[UIColor blackColor] CGColor];
    _card.layer.shadowOpacity = 0.18f;
    _card.layer.shadowRadius = 10;
    _card.layer.shadowOffset = CGSizeMake(0, 3);
    [self addSubview:_card];
    _labels = [[NSMutableArray alloc] init];
    _toggles = [[NSMutableArray alloc] init];
    NSArray *titles = [NSArray arrayWithObjects:YZT(@"Логотип"), YZT(@"Надпись"), YZT(@"Строка поиска"), YZT(@"Недавние"), nil];
    for (int part = 0; part < 4; ++part) {
        UILabel *label = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
        label.backgroundColor = [UIColor clearColor];
        label.text = [titles objectAtIndex:part];
        [_card addSubview:label];
        [_labels addObject:label];
        YZToggle *toggle = [[[YZToggle alloc] initWithFrame:CGRectZero] autorelease];
        toggle.tag = part;
        toggle.on = [YZSettings homeShows:part];
        toggle.accessibilityLabel = [titles objectAtIndex:part];
        [toggle addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
        [_card addSubview:toggle];
        [_toggles addObject:toggle];
    }
    _field = [[UITextField alloc] initWithFrame:CGRectZero];
    _field.delegate = self;
    _field.text = [YZSettings homeName];
    _field.placeholder = YZT(@"Надпись под логотипом");
    _field.clearButtonMode = UITextFieldViewModeWhileEditing;
    _field.returnKeyType = UIReturnKeyDone;
    _field.autocorrectionType = UITextAutocorrectionTypeNo;
    _field.borderStyle = UITextBorderStyleNone;
    _field.layer.cornerRadius = 10;
    [_field addTarget:self action:@selector(textChanged) forControlEvents:UIControlEventEditingChanged];
    // room inside the rounded field before the text
    UIView *pad = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 10)] autorelease];
    _field.leftView = pad;
    _field.leftViewMode = UITextFieldViewModeAlways;
    [_card addSubview:_field];
    _done = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _done.layer.cornerRadius = 18;
    [_done addTarget:self action:@selector(finish) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:_done];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardChanged:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardChanged:) name:UIKeyboardWillHideNotification object:nil];
    [self restyle];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _field.delegate = nil;
    [_card release];
    [_labels release];
    [_toggles release];
    [_field release];
    [_done release];
    [_changed release];
    [_finished release];
    [super dealloc];
}

// only the card takes touches, the page under it is not used while the parts are set
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}

- (void)restyle {
    _card.backgroundColor = [[YZTheme cardColor] colorWithAlphaComponent:0.96f];
    _card.layer.cornerRadius = MIN([YZTheme sheetRadius], (CGFloat)18);
    for (UILabel *label in _labels) {
        label.font = [YZTheme systemFontOfSize:16];
        label.textColor = [YZTheme textColor];
    }
    for (YZToggle *toggle in _toggles)
        [toggle applyTheme];
    _field.font = [YZTheme systemFontOfSize:16];
    _field.textColor = [YZTheme textColor];
    _field.backgroundColor = [YZTheme surfaceColor];
    _done.backgroundColor = [YZTheme surfaceColor];
    _done.titleLabel.font = [YZTheme boldSystemFontOfSize:14];
    [_done setTitle:YZT(@"Готово") forState:UIControlStateNormal];
    [_done setTitleColor:[YZTheme accentColor] forState:UIControlStateNormal];
}

- (void)keyboardChanged:(NSNotification *)note {
    NSValue *value = [[note userInfo] objectForKey:UIKeyboardFrameEndUserInfoKey];
    CGRect frame = [self convertRect:[value CGRectValue] fromView:nil];
    BOOL showing = [[note name] isEqualToString:UIKeyboardWillShowNotification];
    _keyboardHeight = showing ? MAX((CGFloat)0, self.bounds.size.height - frame.origin.y) : 0;
    [UIView animateWithDuration:0.25 animations:^{ [self layoutSubviews]; }];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat viewWidth = self.bounds.size.width, viewHeight = self.bounds.size.height;
    CGFloat width = MIN((CGFloat)340, viewWidth - 32);
    CGFloat inner = width - 2 * YZElementsPad;
    CGFloat height = YZElementsPad + 4 * YZElementsRow + 8 + 40 + 8 + 36 + YZElementsPad;
    CGFloat bottom = viewHeight - MAX((CGFloat)10, _keyboardHeight + 8);
    CGFloat top = MAX((CGFloat)8, bottom - height);
    _card.frame = CGRectMake(floor((viewWidth - width) / 2), top, width, MIN(height, bottom - top));
    _card.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_card.bounds cornerRadius:_card.layer.cornerRadius].CGPath;
    CGSize switchSize = [YZToggle controlSize];
    for (NSUInteger i = 0; i < [_labels count]; ++i) {
        CGFloat y = YZElementsPad + i * YZElementsRow;
        [[_labels objectAtIndex:i] setFrame:CGRectMake(YZElementsPad, y, inner - switchSize.width - 8, YZElementsRow)];
        [[_toggles objectAtIndex:i] setFrame:CGRectMake(YZElementsPad + inner - switchSize.width, y + floor((YZElementsRow - switchSize.height) / 2),
                                                        switchSize.width, switchSize.height)];
    }
    CGFloat fieldTop = YZElementsPad + 4 * YZElementsRow + 8;
    _field.frame = CGRectMake(YZElementsPad, fieldTop, inner, 40);
    _done.frame = CGRectMake(YZElementsPad, fieldTop + 40 + 8, inner, 36);
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
    [_field resignFirstResponder];
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

- (void)toggled:(YZToggle *)toggle {
    [YZSettings setHome:(int)toggle.tag shown:toggle.on];
    if (_changed)
        _changed();
}

// the line takes the text as it is typed, an empty text brings the name of the app back and the line is shown with it
- (void)textChanged {
    [YZSettings setHomeName:_field.text];
    if (![YZSettings homeShows:YZHomePartName]) {
        [YZSettings setHome:YZHomePartName shown:YES];
        [[_toggles objectAtIndex:YZHomePartName] setOn:YES animated:YES];
    }
    if (_changed)
        _changed();
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    [field resignFirstResponder];
    return NO;
}

@end
