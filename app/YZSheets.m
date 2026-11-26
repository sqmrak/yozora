#import "YZSheets.h"
#import "YZClassic.h"
#import "YZCompat.h"
#import "YZColorPicker.h"
#import "YZControls.h"
#import "YZDownloadsController.h"
#import "YZMotion.h"
#import "YZStrings.h"
#import "YZTheme.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#include "yozora_core.h"

static const CGFloat YZSheetMaxWidth = 560;
static const CGFloat YZSheetHandleArea = 20;
static const CGFloat YZSheetTitleArea = 52;

// the panel is a picture of a rounded rectangle behind its parts, not a view cut by a mask: a mask on a panel
// that rises and scrolls makes the render server draw it twice per frame and stuttered the lists on an old
// phone. kept by color and corners
static UIImage *YZPanelImage(UIColor *color, BOOL allCorners) {
    static NSMutableDictionary *cache;
    if (!cache)
        cache = [[NSMutableDictionary alloc] init];
    CGFloat c[4] = { 0, 0, 0, 1 };
    [color getRed:&c[0] green:&c[1] blue:&c[2] alpha:&c[3]];
    NSString *key = [NSString stringWithFormat:@"%d:%.3f:%.3f:%.3f:%.3f", allCorners ? 1 : 0, c[0], c[1], c[2], c[3]];
    UIImage *image = [cache objectForKey:key];
    if (image)
        return image;
    if ([cache count] > 20)
        [cache removeAllObjects];
    CGFloat radius = [YZTheme sheetRadius], side = 2 * radius + 2;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, 0);
    [color setFill];
    UIRectCorner corners = allCorners ? UIRectCornerAllCorners : (UIRectCornerTopLeft | UIRectCornerTopRight);
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side) byRoundingCorners:corners cornerRadii:CGSizeMake(radius, radius)] fill];
    image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    [cache setObject:image forKey:key];
    return image;
}

@implementation YZSheet
@synthesize contentHeight = _contentHeight;
@synthesize bottomInset = _bottomInset;
@synthesize closing = _closing;
@synthesize onCancel = _onCancel;
@synthesize onDone = _onDone;

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    self.backgroundColor = [YZTheme scrimColor];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UIButton *scrim = [UIButton buttonWithType:UIButtonTypeCustom];
    scrim.frame = self.bounds;
    scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [scrim addTarget:self action:@selector(cancelPressed) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:scrim];
    _panel = [[UIView alloc] initWithFrame:CGRectZero];
    [self addSubview:_panel];
    _panelBack = [[UIView alloc] initWithFrame:CGRectZero];
    _panelBack.opaque = NO;
    _panelBack.backgroundColor = [UIColor clearColor];
    [_panel addSubview:_panelBack];
    _panelPlate = [[YZPlateView alloc] initWithFrame:CGRectZero];
    [_panel insertSubview:_panelPlate belowSubview:_panelBack];
    // a drag down on the head of the panel, the handle and the title, takes the sheet away
    UIPanGestureRecognizer *drag = [[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragPanel:)] autorelease];
    drag.delegate = self;
    [_panel addGestureRecognizer:drag];
    UIView *handle = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
    handle.tag = 7;
    handle.backgroundColor = [[YZTheme subtleTextColor] colorWithAlphaComponent:0.5f];
    handle.layer.cornerRadius = 2;
    [_panel addSubview:handle];
    return self;
}

- (void)dealloc {
    [_panel release];
    [_panelBack release];
    [_panelPlate release];
    [_content release];
    [_titleLabel release];
    [_doneButton release];
    [_onCancel release];
    [_onDone release];
    [super dealloc];
}

- (UIView *)content { return _content; }

- (void)setContent:(UIView *)content {
    if (content == _content)
        return;
    [_content removeFromSuperview];
    [_content release];
    _content = [content retain];
    if (_content)
        [_panel addSubview:_content];
    [self setNeedsLayout];
}

- (void)setTitle:(NSString *)title doneTitle:(NSString *)doneTitle {
    if (!_titleLabel) {
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.font = [YZTheme boldSystemFontOfSize:18];
        _titleLabel.backgroundColor = [UIColor clearColor];
        [_panel addSubview:_titleLabel];
    }
    _titleLabel.text = title;
    _titleLabel.textColor = [YZTheme textColor];
    if ([doneTitle length] && !_doneButton) {
        _doneButton = [[YZStateButton alloc] initWithFrame:CGRectZero];
        _doneButton.titleLabel.font = [YZTheme boldSystemFontOfSize:16];
        [_doneButton addTarget:self action:@selector(donePressed) forControlEvents:UIControlEventTouchUpInside];
        [_panel addSubview:_doneButton];
    }
    [_doneButton setTitle:doneTitle forState:UIControlStateNormal];
    [_doneButton setTitleColor:[YZTheme accentColor] forState:UIControlStateNormal];
    [self setNeedsLayout];
}

// the system before ios 6 knows only the old name of the mode, the arm64 slice only the new one
- (void)truncateTitleInMiddle {
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 70000
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
#else
    _titleLabel.lineBreakMode = UILineBreakModeMiddleTruncation;
#endif
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width, height = self.bounds.size.height;
    CGFloat panelWidth = MIN(width, YZSheetMaxWidth);
    CGFloat header = _titleLabel ? YZSheetHandleArea + YZSheetTitleArea : YZSheetHandleArea + 4;
    CGFloat room = MAX((CGFloat)0, height * 0.7f - header - _bottomInset);
    CGFloat contentHeight = MIN(_contentHeight, room);
    CGFloat panelHeight = header + contentHeight + _bottomInset;
    // bounds and center, not the frame: the frame of a view with a transform is undefined and the panel holds
    // a transform for the whole way out (the end is set at once and the animation plays toward it), so a
    // layout during the exit put the panel back and it jumped
    _panel.bounds = CGRectMake(0, 0, panelWidth, panelHeight);
    _panel.center = CGPointMake(floorf((width - panelWidth) / 2) + panelWidth / 2, height - panelHeight + panelHeight / 2);
    // a column on an ipad floats with all four corners rounded, a sheet on a phone is cut at the top only
    _panelBack.frame = _panel.bounds;
    BOOL classic = [YZTheme isClassic];
    _panelPlate.hidden = !classic;
    _panelBack.hidden = classic;
    if (classic) {
        // a sheet on a phone is cut at the foot of the screen: the plate runs past the edges, so only its top corners and outline show
        BOOL floating = panelWidth < width;
        CGFloat bleed = floating ? 0 : 3;
        _panelPlate.frame = CGRectMake(-bleed, 0, panelWidth + 2 * bleed, panelHeight + (floating ? 0 : 24));
        [(YZPlateView *)_panelPlate applyTheme];
    } else {
        [YZTheme stretchImage:YZPanelImage([YZTheme cardColor], panelWidth < width) caps:[YZTheme sheetRadius] onView:_panelBack];
    }
    _headerHeight = header;
    [_panel viewWithTag:7].frame = CGRectMake((panelWidth - 32) / 2, 10, 32, 4);
    if (_titleLabel) {
        CGFloat doneWidth = _doneButton ? 96 : 0;
        _titleLabel.frame = CGRectMake(24, YZSheetHandleArea, panelWidth - 48 - doneWidth, YZSheetTitleArea);
        _doneButton.frame = CGRectMake(panelWidth - doneWidth - 12, YZSheetHandleArea, doneWidth, YZSheetTitleArea);
    }
    _content.frame = CGRectMake(0, header, panelWidth, contentHeight);
}

// the drag starts on the panel head only, so the list or fields below scroll as before, and only when it goes
// more down or up than aside
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (_closing || ![recognizer isKindOfClass:[UIPanGestureRecognizer class]])
        return YES;
    UIPanGestureRecognizer *drag = (UIPanGestureRecognizer *)recognizer;
    CGPoint velocity = [drag velocityInView:self];
    return [drag locationInView:_panel].y <= _headerHeight && fabs(velocity.y) > fabs(velocity.x);
}

- (void)dragPanel:(UIPanGestureRecognizer *)drag {
    CGFloat travel = [drag translationInView:self].y;
    switch (drag.state) {
    case UIGestureRecognizerStateChanged:
        // upward the panel only gives a little, as if it were held
        _panel.transform = CGAffineTransformMakeTranslation(0, travel > 0 ? travel : travel / 6);
        self.backgroundColor = [[YZTheme scrimColor] colorWithAlphaComponent:CGColorGetAlpha([YZTheme scrimColor].CGColor) * (1 - MIN((CGFloat)1, MAX((CGFloat)0, travel) / MAX((CGFloat)1, _panel.bounds.size.height)) * 0.6f)];
        break;
    case UIGestureRecognizerStateEnded:
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed: {
        CGFloat speed = [drag velocityInView:self].y;
        BOOL leave = drag.state == UIGestureRecognizerStateEnded && (travel > _panel.bounds.size.height * 0.3f || speed > 700);
        if (leave) {
            [self cancelPressed];
        } else {
            self.backgroundColor = [YZTheme scrimColor];
            YZMotionAnimateView(_panel, CGAffineTransformIdentity, 1, YOZORA_MOTION_WOBBLE, 0, nil);
        }
        break;
    }
    default:
        break;
    }
}

- (void)presentInView:(UIView *)host {
    self.frame = host.bounds;
    [host addSubview:self];
    [self layoutIfNeeded];
    self.alpha = 0;
    [YZTheme animate:^{ self.alpha = 1; } completion:nil];
    YZMotionAnimateEnter(_panel, CGAffineTransformMakeTranslation(0, _panel.bounds.size.height), 1, YOZORA_MOTION_POPUP_ENTER, 0);
}

- (void)dismissAnimated:(BOOL)animated {
    if (_closing)
        return;
    _closing = YES;
    // the block that is running its way out must not hold the sheet's own references
    [self retain];
    void (^finish)(void) = ^{
        [self removeFromSuperview];
        [self release];
    };
    if (!animated || !self.superview) {
        finish();
        return;
    }
    YZMotionAnimateView(_panel, CGAffineTransformMakeTranslation(0, _panel.bounds.size.height), 1, YOZORA_MOTION_POPUP_EXIT, 0, ^(BOOL done) {
        (void)done;
        finish();
    });
    [YZTheme animate:^{ self.alpha = 0; } completion:nil];
}

- (void)cancelPressed {
    if (_closing)
        return;
    void (^block)(void) = [[_onCancel retain] autorelease];
    [self dismissAnimated:YES];
    if (block)
        block();
}

- (void)donePressed {
    if (_closing)
        return;
    void (^block)(void) = [[_onDone retain] autorelease];
    [self dismissAnimated:YES];
    if (block)
        block();
}
@end

// the rows of a list: texts with group labels, separators and unavailable items, the chosen one on a pill of the accent
@interface YZChoiceTable : UITableView <UITableViewDataSource, UITableViewDelegate> {
    NSArray *_texts;
    NSArray *_flags;
    NSInteger _selected;
    // a glyph for each row of a list of actions, nil for a list of choices
    NSArray *_icons;
    // a list that takes several choices: the chosen rows, and taps toggle them instead of answering
    BOOL _multiple;
    NSMutableIndexSet *_chosen;
    void (^_choose)(NSInteger index);
}
@property(nonatomic, copy) void (^choose)(NSInteger index);
@property(nonatomic, readonly) NSIndexSet *chosen;
@property(nonatomic, retain) NSArray *icons;
- (id)initWithTexts:(NSArray *)texts flags:(NSArray *)flags selected:(NSInteger)selected;
- (id)initMultipleWithTexts:(NSArray *)texts flags:(NSArray *)flags;
@end

@implementation YZChoiceTable
@synthesize choose = _choose;
@synthesize icons = _icons;

- (id)initWithTexts:(NSArray *)texts flags:(NSArray *)flags selected:(NSInteger)selected {
    self = [super initWithFrame:CGRectZero style:UITableViewStylePlain];
    if (!self)
        return nil;
    _texts = [texts retain];
    _flags = [flags retain];
    _selected = selected;
    self.backgroundColor = [UIColor clearColor];
    self.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.dataSource = self;
    self.delegate = self;
    return self;
}

- (id)initMultipleWithTexts:(NSArray *)texts flags:(NSArray *)flags {
    self = [self initWithTexts:texts flags:flags selected:-1];
    if (!self)
        return nil;
    _multiple = YES;
    _chosen = [[NSMutableIndexSet alloc] init];
    for (NSUInteger i = 0; i < [flags count]; ++i) {
        if ([[flags objectAtIndex:i] intValue] & YOZORA_CHOICE_SELECTED)
            [_chosen addIndex:i];
    }
    return self;
}

- (NSIndexSet *)chosen { return _chosen; }

- (void)dealloc {
    self.dataSource = nil;
    self.delegate = nil;
    [_chosen release];
    [_icons release];
    [_texts release];
    [_flags release];
    [_choose release];
    [super dealloc];
}

- (int)flagsOfRow:(NSInteger)row { return [[_flags objectAtIndex:row] intValue]; }

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    (void)table;
    (void)section;
    return (NSInteger)[_texts count];
}

- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    (void)table;
    int flags = [self flagsOfRow:path.row];
    if (flags & YOZORA_CHOICE_SEPARATOR)
        return 9;
    return flags & YOZORA_CHOICE_GROUP ? 40 : 52;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    static NSString *identifier = @"choice";
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier] autorelease];
        cell.backgroundColor = [UIColor clearColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        // the pill and the check are made once for a reused row, new views per scrolled in row stuttered a
        // list of a hundred languages
        UIView *pill = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
        pill.layer.cornerRadius = 26;
        cell.backgroundView = pill;
        cell.accessoryView = [[[UIImageView alloc] initWithImage:[YZTheme icon:YZIconCheck size:24 color:[YZTheme accentColor]]] autorelease];
    }
    int flags = [self flagsOfRow:path.row];
    BOOL selected = _multiple ? [_chosen containsIndex:(NSUInteger)path.row] : path.row == _selected;
    cell.textLabel.text = (flags & YOZORA_CHOICE_SEPARATOR) ? nil : [_texts objectAtIndex:path.row];
    cell.textLabel.backgroundColor = [UIColor clearColor];
    if (flags & YOZORA_CHOICE_GROUP) {
        cell.textLabel.font = [YZTheme boldSystemFontOfSize:13];
        cell.textLabel.textColor = [YZTheme subtleTextColor];
    } else {
        cell.textLabel.font = [YZTheme systemFontOfSize:16];
        cell.textLabel.textColor = (flags & YOZORA_CHOICE_DISABLED) ? [[YZTheme textColor] colorWithAlphaComponent:0.38f] : [YZTheme textColor];
    }
    // the chosen row lies on a pill and carries a check, as the options of the settings do
    cell.backgroundView.backgroundColor = selected ? [YZTheme stateColor] : [UIColor clearColor];
    cell.accessoryView.hidden = !selected;
    if (_icons && (NSUInteger)path.row < [_icons count])
        cell.imageView.image = [YZTheme icon:(YZIcon)[[_icons objectAtIndex:path.row] intValue] size:24 color:[YZTheme accentColor]];
    return cell;
}

- (void)tableView:(UITableView *)table willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)path {
    (void)path;
    // the pill keeps a margin to the edges of the sheet
    cell.backgroundView.frame = CGRectInset(cell.bounds, 12, 2);
    (void)table;
}

- (NSIndexPath *)tableView:(UITableView *)table willSelectRowAtIndexPath:(NSIndexPath *)path {
    (void)table;
    int flags = [self flagsOfRow:path.row];
    return (flags & (YOZORA_CHOICE_GROUP | YOZORA_CHOICE_SEPARATOR | YOZORA_CHOICE_DISABLED)) ? nil : path;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:NO];
    if (_multiple) {
        if ([_chosen containsIndex:(NSUInteger)path.row])
            [_chosen removeIndex:(NSUInteger)path.row];
        else
            [_chosen addIndex:(NSUInteger)path.row];
        [table reloadRowsAtIndexPaths:[NSArray arrayWithObject:path] withRowAnimation:UITableViewRowAnimationNone];
        return;
    }
    if (_choose)
        _choose(path.row);
}

- (void)revealSelected {
    if (_selected >= 0 && _selected < (NSInteger)[_texts count])
        [self scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:_selected inSection:0] atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
}
@end

// formats of the five date fields, in the form the page reads and writes them, whatever the language of the phone
static NSDateFormatter *YZDateFormatter(NSString *format) {
    NSDateFormatter *formatter = [[[NSDateFormatter alloc] init] autorelease];
    formatter.locale = [[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = format;
    return formatter;
}

static NSCalendar *YZIsoWeekCalendar(void) {
    NSCalendar *calendar = [[[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar] autorelease];
    calendar.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    // an ISO week starts on Monday and the first one holds the fourth of January
    calendar.firstWeekday = 2;
    calendar.minimumDaysInFirstWeek = 4;
    return calendar;
}

static NSString *YZWeekString(NSDate *date) {
    NSDateComponents *parts = [YZIsoWeekCalendar() components:NSYearForWeekOfYearCalendarUnit | NSWeekOfYearCalendarUnit fromDate:date];
    return [NSString stringWithFormat:@"%04ld-W%02ld", (long)parts.yearForWeekOfYear, (long)parts.weekOfYear];
}

static NSDate *YZWeekDate(NSString *value) {
    int year = 0, week = 0;
    if (sscanf([value UTF8String], "%d-W%d", &year, &week) != 2 || year < 1 || week < 1 || week > 53)
        return nil;
    NSDateComponents *parts = [[[NSDateComponents alloc] init] autorelease];
    parts.yearForWeekOfYear = year;
    parts.weekOfYear = week;
    parts.weekday = 2;
    return [YZIsoWeekCalendar() dateFromComponents:parts];
}

@implementation YZPickers

+ (YZSheet *)presentChoicesInView:(UIView *)host title:(NSString *)title texts:(NSArray *)texts flags:(NSArray *)flags selected:(NSInteger)selected
                      bottomInset:(CGFloat)bottomInset completion:(void (^)(NSInteger))completion {
    YZSheet *sheet = [[[YZSheet alloc] initWithFrame:host.bounds] autorelease];
    YZChoiceTable *table = [[[YZChoiceTable alloc] initWithTexts:texts flags:flags selected:selected] autorelease];
    CGFloat height = 8;
    for (NSUInteger i = 0; i < [flags count]; ++i) {
        int flag = [[flags objectAtIndex:i] intValue];
        height += (flag & YOZORA_CHOICE_SEPARATOR) ? 9 : ((flag & YOZORA_CHOICE_GROUP) ? 40 : 52);
    }
    sheet.contentHeight = height;
    sheet.bottomInset = MAX(bottomInset, (CGFloat)8);
    if ([title length])
        [sheet setTitle:title doneTitle:nil];
    sheet.content = table;
    void (^done)(NSInteger) = [[completion copy] autorelease];
    __block BOOL answered = NO;
    // the sheet owns the table and the table owns this block, so the block must not own the sheet
    __block YZSheet *weak = sheet;
    table.choose = ^(NSInteger index) {
        if (answered)
            return;
        answered = YES;
        [weak dismissAnimated:YES];
        done(index);
    };
    sheet.onCancel = ^{
        if (answered)
            return;
        answered = YES;
        done(-1);
    };
    [sheet presentInView:host];
    [table revealSelected];
    return sheet;
}

+ (YZSheet *)presentActionsInView:(UIView *)host title:(NSString *)title texts:(NSArray *)texts icons:(NSArray *)icons bottomInset:(CGFloat)bottomInset
                       completion:(void (^)(NSInteger))completion {
    NSMutableArray *flags = [NSMutableArray arrayWithCapacity:[texts count]];
    for (NSUInteger i = 0; i < [texts count]; ++i)
        [flags addObject:[NSNumber numberWithInt:0]];
    YZSheet *sheet = [[[YZSheet alloc] initWithFrame:host.bounds] autorelease];
    YZChoiceTable *table = [[[YZChoiceTable alloc] initWithTexts:texts flags:flags selected:-1] autorelease];
    table.icons = icons;
    sheet.contentHeight = 8 + 52 * [texts count];
    sheet.bottomInset = MAX(bottomInset, (CGFloat)8);
    if ([title length]) {
        [sheet setTitle:title doneTitle:nil];
        [sheet truncateTitleInMiddle];
    }
    sheet.content = table;
    void (^done)(NSInteger) = [[completion copy] autorelease];
    __block BOOL answered = NO;
    // the sheet owns the table and the table owns this block, so the block must not own the sheet
    __block YZSheet *weak = sheet;
    table.choose = ^(NSInteger index) {
        if (answered)
            return;
        answered = YES;
        [weak dismissAnimated:YES];
        done(index);
    };
    sheet.onCancel = ^{
        if (answered)
            return;
        answered = YES;
        done(-1);
    };
    [sheet presentInView:host];
    return sheet;
}

+ (YZSheet *)presentMultipleChoicesInView:(UIView *)host title:(NSString *)title texts:(NSArray *)texts flags:(NSArray *)flags
                              bottomInset:(CGFloat)bottomInset completion:(void (^)(NSIndexSet *))completion {
    YZSheet *sheet = [[[YZSheet alloc] initWithFrame:host.bounds] autorelease];
    YZChoiceTable *table = [[[YZChoiceTable alloc] initMultipleWithTexts:texts flags:flags] autorelease];
    CGFloat height = 8;
    for (NSUInteger i = 0; i < [flags count]; ++i) {
        int flag = [[flags objectAtIndex:i] intValue];
        height += (flag & YOZORA_CHOICE_SEPARATOR) ? 9 : ((flag & YOZORA_CHOICE_GROUP) ? 40 : 52);
    }
    sheet.contentHeight = height;
    sheet.bottomInset = MAX(bottomInset, (CGFloat)8);
    [sheet setTitle:title doneTitle:YZT(@"Готово")];
    sheet.content = table;
    void (^done)(NSIndexSet *) = [[completion copy] autorelease];
    __block BOOL answered = NO;
    // the sheet owns the table and the table is read when the done button is pressed, so the block keeps no reference to it
    __block YZChoiceTable *weakTable = table;
    sheet.onDone = ^{
        if (answered)
            return;
        answered = YES;
        done([[weakTable.chosen copy] autorelease]);
    };
    sheet.onCancel = ^{
        if (answered)
            return;
        answered = YES;
        done(nil);
    };
    [sheet presentInView:host];
    return sheet;
}

+ (YZSheet *)presentColorInView:(UIView *)host value:(NSString *)value bottomInset:(CGFloat)bottomInset completion:(void (^)(NSString *))completion {
    YZSheet *sheet = [[[YZSheet alloc] initWithFrame:host.bounds] autorelease];
    YZColorPicker *picker = [[[YZColorPicker alloc] initWithFrame:CGRectMake(0, 0, 320, [YZColorPicker preferredHeight])] autorelease];
    if ([value length])
        picker.hex = value;
    sheet.contentHeight = [YZColorPicker preferredHeight];
    sheet.bottomInset = MAX(bottomInset, (CGFloat)8);
    [sheet setTitle:YZT(@"Цвет") doneTitle:YZT(@"Готово")];
    sheet.content = picker;
    void (^done)(NSString *) = [[completion copy] autorelease];
    __block BOOL answered = NO;
    __block YZColorPicker *weakPicker = picker;
    sheet.onDone = ^{
        if (answered)
            return;
        answered = YES;
        done(weakPicker.hex);
    };
    sheet.onCancel = ^{
        if (answered)
            return;
        answered = YES;
        done(nil);
    };
    [sheet presentInView:host];
    return sheet;
}

+ (YZSheet *)presentDateInView:(UIView *)host type:(NSString *)type value:(NSString *)value minimum:(double)minimum maximum:(double)maximum step:(double)step
                   bottomInset:(CGFloat)bottomInset completion:(void (^)(NSString *))completion {
    BOOL isTime = [type isEqualToString:@"time"], isDateTime = [type isEqualToString:@"datetime-local"];
    BOOL isMonth = [type isEqualToString:@"month"], isWeek = [type isEqualToString:@"week"];
    NSString *format = isTime ? ([value length] > 5 ? @"HH:mm:ss" : @"HH:mm") : (isDateTime ? @"yyyy-MM-dd'T'HH:mm" : (isMonth ? @"yyyy-MM" : @"yyyy-MM-dd"));
    NSString *title = isTime ? YZT(@"Время") : (isDateTime ? YZT(@"Дата и время") : (isMonth ? YZT(@"Месяц") : (isWeek ? YZT(@"Неделя") : YZT(@"Дата"))));
    UIDatePicker *picker = [[[UIDatePicker alloc] initWithFrame:CGRectMake(0, 0, 320, 216)] autorelease];
    picker.datePickerMode = isTime ? UIDatePickerModeTime : (isDateTime ? UIDatePickerModeDateAndTime : UIDatePickerModeDate);
    // the value of the field is what the wheels show, so they run in the zone of the formatter
    picker.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    picker.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    // the compact style of ios 14 does not fit a sheet, the wheels do
    if ([picker respondsToSelector:NSSelectorFromString(@"setPreferredDatePickerStyle:")])
        ((void (*)(id, SEL, NSInteger))(void *)objc_msgSend)(picker, NSSelectorFromString(@"setPreferredDatePickerStyle:"), 1);
    NSDate *start = nil;
    if ([value length])
        start = isWeek ? YZWeekDate(value) : [YZDateFormatter(format) dateFromString:value];
    if (start)
        picker.date = start;
    // the limits of the type itself (year 1 and year 275760) are far outside what a picker can show
    double low = -2208988800000.0, high = 7258118400000.0;
    if (!isTime && !isMonth) {
        if (minimum > low && minimum < high)
            picker.minimumDate = [NSDate dateWithTimeIntervalSince1970:minimum / 1000.0];
        if (maximum > low && maximum < high)
            picker.maximumDate = [NSDate dateWithTimeIntervalSince1970:maximum / 1000.0];
    }
    // the step of a time field is in milliseconds, the wheels count minutes and take only the divisors of an hour
    if (isTime && step >= 60000) {
        int minutes = (int)(step / 60000);
        if (minutes <= 30 && 60 % minutes == 0)
            picker.minuteInterval = minutes;
    }
    YZSheet *sheet = [[[YZSheet alloc] initWithFrame:host.bounds] autorelease];
    sheet.contentHeight = 216;
    sheet.bottomInset = MAX(bottomInset, (CGFloat)8);
    [sheet setTitle:title doneTitle:YZT(@"Готово")];
    sheet.content = picker;
    void (^done)(NSString *) = [[completion copy] autorelease];
    __block BOOL answered = NO;
    // the sheet owns the picker and the sheet owns this block
    __block UIDatePicker *weakPicker = picker;
    sheet.onDone = ^{
        if (answered)
            return;
        answered = YES;
        NSDate *date = weakPicker.date;
        done(isWeek ? YZWeekString(date) : [YZDateFormatter(format) stringFromDate:date]);
    };
    sheet.onCancel = ^{
        if (answered)
            return;
        answered = YES;
        done(nil);
    };
    [sheet presentInView:host];
    return sheet;
}
@end

// what the accept attribute lets the person pick from the photos: nothing listed, an image or video type, or
// an image extension
static BOOL YZAcceptsPhotos(NSString *accept) {
    if (![accept length])
        return YES;
    NSString *lower = [accept lowercaseString];
    NSArray *markers = [NSArray arrayWithObjects:@"image", @"video", @"*/*", @".jpg", @".jpeg", @".png", @".gif", @".heic", @".webp", @".mov", @".mp4", nil];
    for (NSString *marker in markers) {
        if ([lower rangeOfString:marker].location != NSNotFound)
            return YES;
    }
    return NO;
}

// the photo picker lists videos too when the field takes them, it shows pictures only until it is told
static BOOL YZAcceptsVideo(NSString *accept) {
    if (![accept length])
        return YES;
    NSString *lower = [accept lowercaseString];
    NSArray *markers = [NSArray arrayWithObjects:@"video", @"*/*", @".mov", @".mp4", @".m4v", nil];
    for (NSString *marker in markers) {
        if ([lower rangeOfString:marker].location != NSNotFound)
            return YES;
    }
    return NO;
}

// the media folder of the user. ios before 8 has no system file picker, so a file that is not a photo is
// reached from here, as far as the process can read the folders
static NSString *const YZStorageRoot = @"/var/mobile/Media";

static BOOL YZStorageReadable(void) {
    return [[NSFileManager defaultManager] contentsOfDirectoryAtPath:YZStorageRoot error:NULL] != nil;
}

// a folder of downloads without a file in it is no source: its sheet would close the picker without a word
static BOOL YZDownloadsHaveFiles(void) {
    NSString *directory = [YZDownloadsController directory];
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:NULL]) {
        if (![name hasPrefix:@"."] && ![name hasSuffix:@".part"])
            return YES;
    }
    return NO;
}

static NSString *YZUploadDirectory(void) {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"YozoraUploads"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
    return directory;
}

// a photo that is not one day old is still wanted by a page that is open, older ones are dropped when the next photo comes
static void YZPruneUploads(NSString *directory) {
    NSFileManager *files = [NSFileManager defaultManager];
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:-86400];
    for (NSString *name in [files contentsOfDirectoryAtPath:directory error:NULL]) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        NSDate *modified = [[files attributesOfItemAtPath:path error:NULL] objectForKey:NSFileModificationDate];
        if (modified && [modified compare:limit] == NSOrderedAscending)
            [files removeItemAtPath:path error:NULL];
    }
}

typedef enum { YZFileSourcePhotos, YZFileSourceDownloads, YZFileSourceDocuments, YZFileSourceStorage } YZFileSource;

@implementation YZFilePicker

- (id)initWithHost:(UIViewController *)host accept:(NSString *)accept multiple:(BOOL)multiple bottomInset:(CGFloat)bottomInset completion:(void (^)(NSArray *))completion {
    self = [super init];
    if (!self)
        return nil;
    _host = host;
    _hostView = host.view;
    _accept = [accept copy];
    _multiple = multiple;
    _bottomInset = bottomInset;
    _completion = [completion copy];
    return self;
}

- (void)dealloc {
    [_accept release];
    [_completion release];
    [super dealloc];
}

- (BOOL)hasDocumentPicker { return NSClassFromString(@"UIDocumentPickerViewController") != nil; }

// ios 8 to 10 have no Files app, the picker opens on iCloud Drive
- (NSString *)documentSourceTitle {
    Class pickerClass = NSClassFromString(@"UIDocumentPickerViewController");
    BOOL files = [pickerClass instancesRespondToSelector:NSSelectorFromString(@"setAllowsMultipleSelection:")];
    return files ? YZT(@"Файлы") : @"iCloud Drive";
}

+ (BOOL)hasSourceForAccept:(NSString *)accept {
    if (YZAcceptsPhotos(accept) && [UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary])
        return YES;
    return YZDownloadsHaveFiles() || YZStorageReadable() || NSClassFromString(@"UIDocumentPickerViewController") != nil;
}

- (void)present {
    // the picker is its own owner until it has answered
    [self retain];
    [self showSources];
}

// comes back when the system picker closes without a file, a sideload has no icloud entitlement and the picker can close at once
- (void)showSources {
    NSMutableArray *titles = [NSMutableArray array], *sources = [NSMutableArray array];
    if (YZAcceptsPhotos(_accept) && [UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) {
        [titles addObject:YZT(@"Фото")];
        [sources addObject:[NSNumber numberWithInt:YZFileSourcePhotos]];
    }
    if (YZDownloadsHaveFiles()) {
        [titles addObject:YZT(@"Загрузки")];
        [sources addObject:[NSNumber numberWithInt:YZFileSourceDownloads]];
    }
    if (YZStorageReadable()) {
        [titles addObject:YZT(@"Память устройства")];
        [sources addObject:[NSNumber numberWithInt:YZFileSourceStorage]];
    }
    if ([self hasDocumentPicker]) {
        [titles addObject:[self documentSourceTitle]];
        [sources addObject:[NSNumber numberWithInt:YZFileSourceDocuments]];
    }
    NSLog(@"yozora: file chooser, accept \"%@\", multiple %d, sources: %@", _accept, (int)_multiple, [titles componentsJoinedByString:@", "]);
    if (![titles count]) {
        [self finishWithPaths:nil];
        return;
    }
    NSMutableArray *flags = [NSMutableArray array];
    for (NSUInteger i = 0; i < [titles count]; ++i)
        [flags addObject:[NSNumber numberWithInt:0]];
    _sheet = [[YZPickers presentChoicesInView:_hostView title:YZT(@"Выберите файл") texts:titles flags:flags selected:-1 bottomInset:_bottomInset
                                  completion:^(NSInteger index) {
        [_sheet release];
        _sheet = nil;
        if (index < 0 || index >= (NSInteger)[sources count]) {
            [self finishWithPaths:nil];
            return;
        }
        [self openSource:(YZFileSource)[[sources objectAtIndex:index] intValue]];
    }] retain];
}

// webkit takes a repeated path as no change and fires cancel, so each pick gets a copy in a new folder
- (void)finishWithFreshCopiesOf:(NSArray *)paths {
    if (![paths count]) {
        [self finishWithPaths:nil];
        return;
    }
    NSArray *sources = [paths copy];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSFileManager *files = [NSFileManager defaultManager];
        NSString *directory = YZUploadDirectory();
        YZPruneUploads(directory);
        static unsigned counter;
        NSMutableArray *results = [NSMutableArray array];
        for (NSString *source in sources) {
            NSString *folder = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%lld-%u", (long long)([[NSDate date] timeIntervalSince1970] * 1000), counter++]];
            NSString *target = [folder stringByAppendingPathComponent:[source lastPathComponent]];
            NSError *error = nil;
            if ([files createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:&error] && [files copyItemAtPath:source toPath:target error:&error]) {
                [results addObject:target];
            } else {
                NSLog(@"yozora: file chooser: %@ was not copied, it goes on under its own path: %@", [source lastPathComponent], error);
                [results addObject:source];
            }
        }
        [sources release];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishWithPaths:results];
        });
        [pool drain];
    });
}

- (void)finishWithPaths:(NSArray *)paths {
    if (!_completion) {
        return;
    }
    void (^completion)(NSArray *) = _completion;
    _completion = nil;
    NSLog(@"yozora: file chooser answered with %lu file(s)", (unsigned long)[paths count]);
    completion(paths ? paths : [NSArray array]);
    [completion release];
    [self release];
}

- (void)closeEverything {
    [_sheet dismissAnimated:NO];
    [_sheet release];
    _sheet = nil;
    [_popover dismissPopoverAnimated:NO];
    [_popover release];
    _popover = nil;
    if (_picker && [_picker respondsToSelector:@selector(setDelegate:)])
        [_picker performSelector:@selector(setDelegate:) withObject:nil];
    if (_host.presentedViewController == _picker)
        [_host dismissViewControllerAnimated:NO completion:nil];
    [_picker release];
    _picker = nil;
}

- (void)cancel {
    // the sheet keeps its own block, which would answer a second time
    _sheet.onCancel = nil;
    [self closeEverything];
    [self finishWithPaths:nil];
}

- (void)openSource:(YZFileSource)source {
    if (source == YZFileSourcePhotos)
        [self openPhotos];
    else if (source == YZFileSourceDownloads)
        [self openDownloads];
    else if (source == YZFileSourceStorage)
        [self openStorageAt:YZStorageRoot];
    else
        [self openDocuments];
}

#pragma mark photos

- (void)presentPicker:(UIViewController *)picker {
    _picker = [picker retain];
    BOOL pad = [YZTheme isPad] && NSClassFromString(@"UIPopoverController");
    // the photo library of an ipad is shown in a popover, a full screen one is refused by the system before ios 13
    if (pad && [picker isKindOfClass:[UIImagePickerController class]]) {
        _popover = [[UIPopoverController alloc] initWithContentViewController:picker];
        CGRect bounds = _hostView.bounds;
        [_popover presentPopoverFromRect:CGRectMake(bounds.size.width / 2, bounds.size.height - 1, 1, 1) inView:_hostView
                permittedArrowDirections:UIPopoverArrowDirectionDown animated:YES];
    } else {
        [_host presentViewController:picker animated:YES completion:nil];
    }
}

- (void)openPhotos {
    UIImagePickerController *picker = [[[UIImagePickerController alloc] init] autorelease];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.delegate = (id)self;
    if (YZAcceptsVideo(_accept)) {
        NSArray *types = [UIImagePickerController availableMediaTypesForSourceType:UIImagePickerControllerSourceTypePhotoLibrary];
        if ([types count])
            picker.mediaTypes = types;
    }
    [self presentPicker:picker];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    (void)picker;
    [self closeEverything];
    [self finishWithPaths:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
    (void)picker;
    NSURL *movie = [info objectForKey:UIImagePickerControllerMediaURL];
    UIImage *image = [info objectForKey:UIImagePickerControllerOriginalImage];
    [self closeEverything];
    if (movie) {
        [self finishWithPaths:[NSArray arrayWithObject:[movie path]]];
        return;
    }
    if (!image) {
        [self finishWithPaths:nil];
        return;
    }
    // the jpeg of a large photo takes a moment to write, so the interface does not wait for it
    [image retain];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSString *directory = YZUploadDirectory();
        YZPruneUploads(directory);
        NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"IMG_%lld.jpg", (long long)([[NSDate date] timeIntervalSince1970] * 1000)]];
        NSData *data = UIImageJPEGRepresentation(image, 0.9f);
        BOOL written = [data length] && [data writeToFile:path atomically:YES];
        [image release];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!written)
                NSLog(@"yozora: the photo could not be written to %@", path);
            [self finishWithPaths:written ? [NSArray arrayWithObject:path] : nil];
        });
        [pool drain];
    });
}

#pragma mark downloads folder

- (void)openDownloads {
    NSString *directory = [YZDownloadsController directory];
    NSFileManager *files = [NSFileManager defaultManager];
    NSMutableArray *entries = [NSMutableArray array];
    for (NSString *name in [files contentsOfDirectoryAtPath:directory error:NULL]) {
        if ([name hasPrefix:@"."] || [name hasSuffix:@".part"])
            continue;
        NSString *path = [directory stringByAppendingPathComponent:name];
        NSDictionary *attributes = [files attributesOfItemAtPath:path error:NULL];
        if ([[attributes objectForKey:NSFileType] isEqualToString:NSFileTypeRegular])
            [entries addObject:[NSDictionary dictionaryWithObjectsAndKeys:name, @"name", path, @"path",
                                [attributes objectForKey:NSFileModificationDate] ? [attributes objectForKey:NSFileModificationDate] : [NSDate distantPast], @"date", nil]];
    }
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [[b objectForKey:@"date"] compare:[a objectForKey:@"date"]]; }];
    if ([entries count] > YOZORA_CHOICE_MAX)
        [entries removeObjectsInRange:NSMakeRange(YOZORA_CHOICE_MAX, [entries count] - YOZORA_CHOICE_MAX)];
    if (![entries count]) {
        [self finishWithPaths:nil];
        return;
    }
    NSMutableArray *texts = [NSMutableArray array], *flags = [NSMutableArray array];
    for (NSDictionary *entry in entries) {
        [texts addObject:[entry objectForKey:@"name"]];
        [flags addObject:[NSNumber numberWithInt:0]];
    }
    _sheet = [[YZPickers presentChoicesInView:_hostView title:YZT(@"Загрузки") texts:texts flags:flags selected:-1 bottomInset:_bottomInset
                                  completion:^(NSInteger index) {
        [_sheet release];
        _sheet = nil;
        if (index < 0 || index >= (NSInteger)[entries count]) {
            [self finishWithPaths:nil];
            return;
        }
        [self finishWithFreshCopiesOf:[NSArray arrayWithObject:[[entries objectAtIndex:index] objectForKey:@"path"]]];
    }] retain];
}

#pragma mark device storage

// one folder at a time as a list: a row to go up, folders, then files by name. a longer list is cut at the
// size of a page list and says so. what the process cannot read shows as a row that says it
- (void)openStorageAt:(NSString *)directory {
    NSFileManager *files = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray *names = [files contentsOfDirectoryAtPath:directory error:&error];
    NSMutableArray *folders = [NSMutableArray array], *plain = [NSMutableArray array];
    for (NSString *name in names) {
        if ([name hasPrefix:@"."])
            continue;
        NSString *path = [directory stringByAppendingPathComponent:name];
        BOOL isDirectory = NO;
        if (![files fileExistsAtPath:path isDirectory:&isDirectory])
            continue;
        [(isDirectory ? folders : plain) addObject:[NSDictionary dictionaryWithObjectsAndKeys:name, @"name", path, @"path", [NSNumber numberWithBool:isDirectory], @"directory", nil]];
    }
    NSComparisonResult (^byName)(NSDictionary *, NSDictionary *) = ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [[a objectForKey:@"name"] caseInsensitiveCompare:[b objectForKey:@"name"]];
    };
    [folders sortUsingComparator:byName];
    [plain sortUsingComparator:byName];
    NSMutableArray *entries = [NSMutableArray array], *texts = [NSMutableArray array], *flags = [NSMutableArray array];
    void (^add)(NSDictionary *, NSString *, int) = ^(NSDictionary *entry, NSString *text, int flag) {
        [entries addObject:entry ? entry : [NSDictionary dictionary]];
        [texts addObject:text];
        [flags addObject:[NSNumber numberWithInt:flag]];
    };
    if (![directory isEqualToString:@"/"])
        add([NSDictionary dictionaryWithObject:[directory stringByDeletingLastPathComponent] forKey:@"up"], YZT(@"На уровень выше"), 0);
    if (!names)
        add(nil, YZT(@"Нет доступа к папке"), YOZORA_CHOICE_DISABLED);
    else if (![folders count] && ![plain count])
        add(nil, YZT(@"Папка пуста"), YOZORA_CHOICE_DISABLED);
    NSUInteger room = YOZORA_CHOICE_MAX - [entries count] - 1;
    NSUInteger listed = 0;
    BOOL cut = NO;
    for (NSDictionary *entry in [folders arrayByAddingObjectsFromArray:plain]) {
        if (listed == room) {
            cut = YES;
            break;
        }
        BOOL isDirectory = [[entry objectForKey:@"directory"] boolValue];
        add(entry, isDirectory ? [[entry objectForKey:@"name"] stringByAppendingString:@"/"] : [entry objectForKey:@"name"], 0);
        ++listed;
    }
    if (cut)
        add(nil, [NSString stringWithFormat:YZT(@"Показаны первые %d"), (int)listed], YOZORA_CHOICE_DISABLED);
    _sheet = [[YZPickers presentChoicesInView:_hostView title:directory texts:texts flags:flags selected:-1 bottomInset:_bottomInset
                                  completion:^(NSInteger index) {
        [_sheet release];
        _sheet = nil;
        if (index < 0 || index >= (NSInteger)[entries count]) {
            [self finishWithPaths:nil];
            return;
        }
        NSDictionary *entry = [entries objectAtIndex:index];
        if ([entry objectForKey:@"up"])
            [self openStorageAt:[entry objectForKey:@"up"]];
        else if ([[entry objectForKey:@"directory"] boolValue])
            [self openStorageAt:[entry objectForKey:@"path"]];
        else
            [self finishWithFreshCopiesOf:[NSArray arrayWithObject:[entry objectForKey:@"path"]]];
    }] retain];
}

#pragma mark files app

// UIDocumentPickerViewController came with ios 8 and multiple selection with 11, looked up at run time, the
// armv7 sdk has neither
- (void)openDocuments {
    Class pickerClass = NSClassFromString(@"UIDocumentPickerViewController");
    SEL initializer = NSSelectorFromString(@"initWithDocumentTypes:inMode:");
    id picker = [pickerClass alloc];
    if (!pickerClass || ![picker respondsToSelector:initializer]) {
        NSLog(@"yozora: file chooser: the document picker cannot be made on this system");
        [picker release];
        [self finishWithPaths:nil];
        return;
    }
    // the import mode copies the file into the app, so the page reads a file that stays
    picker = ((id (*)(id, SEL, NSArray *, NSInteger))(void *)objc_msgSend)(picker, initializer, [NSArray arrayWithObject:@"public.item"], 0);
    [picker setValue:self forKey:@"delegate"];
    _documentsOpenedAt = CFAbsoluteTimeGetCurrent();
    if (_multiple && [picker respondsToSelector:NSSelectorFromString(@"setAllowsMultipleSelection:")])
        [picker setValue:[NSNumber numberWithBool:YES] forKey:@"allowsMultipleSelection"];
    [self presentPicker:[picker autorelease]];
}

- (void)documentPicker:(id)picker didPickDocumentsAtURLs:(NSArray *)urls {
    (void)picker;
    NSMutableArray *paths = [NSMutableArray array];
    for (NSURL *url in urls) {
        if ([url isFileURL])
            [paths addObject:[url path]];
        else
            NSLog(@"yozora: file chooser: the document picker gave %@, which is not a file", url);
    }
    [self closeEverything];
    [self finishWithFreshCopiesOf:paths];
}

// the single selection of ios 8 to 10
- (void)documentPicker:(id)picker didPickDocumentAtURL:(NSURL *)url {
    [self documentPicker:picker didPickDocumentsAtURLs:url ? [NSArray arrayWithObject:url] : nil];
}

- (void)documentPickerWasCancelled:(id)picker {
    (void)picker;
    NSLog(@"yozora: file chooser: the document picker was closed without a file after %.1f s", CFAbsoluteTimeGetCurrent() - _documentsOpenedAt);
    [self closeEverything];
    [self showSources];
}
@end
