#import "YZUpdateUI.h"
#import "YZClassic.h"
#import "YZCompat.h"
#import "YZControls.h"
#import "YZMotion.h"
#import "YZStrings.h"
#import "YZTheme.h"
#import "YZWaveSeekBar.h"
#import <QuartzCore/QuartzCore.h>

enum { YZItemSticker, YZItemLabel, YZItemProgress, YZItemButton };
enum { YZActionLater = 1, YZActionPrimary, YZActionCancel, YZActionRefresh, YZActionOpenIn };

static NSString *YZVersionText(NSString *tag) {
    return [tag length] ? ([tag hasPrefix:@"v"] ? tag : [@"v" stringByAppendingString:tag]) : @"?";
}

static NSString *YZMegabytes(unsigned long long bytes) {
    return [NSString stringWithFormat:@"%.1f", (double)bytes / (1024.0 * 1024.0)];
}

@implementation YZUpdateProgress {
    YZWaveSeekBar *_wave;
    float _fraction;
}

@synthesize fraction = _fraction;

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    self.backgroundColor = [UIColor clearColor];
    self.userInteractionEnabled = NO;
    [self applyTheme];
    return self;
}

- (void)dealloc {
    [_wave release];
    [super dealloc];
}

- (void)applyTheme {
    if ([YZTheme isClassic]) {
        [_wave removeFromSuperview];
        [_wave release];
        _wave = nil;
    } else if (!_wave) {
        _wave = [[YZWaveSeekBar alloc] initWithFrame:self.bounds];
        _wave.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _wave.userInteractionEnabled = NO;
        _wave.waving = YES;
        [self addSubview:_wave];
    }
    _wave.playedColor = [YZTheme accentColor];
    _wave.restColor = [YZTheme stateColor];
    _wave.value = _fraction;
    [self setNeedsDisplay];
}

- (void)setFraction:(float)fraction {
    _fraction = fraction < 0 ? 0 : fraction > 1 ? 1 : fraction;
    _wave.value = _fraction;
    [self setNeedsDisplay];
}

static void YZFillRounded(CGContextRef context, CGRect rect, CGFloat radius, CGGradientRef gradient) {
    CGContextSaveGState(context);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];
    [path addClip];
    CGContextDrawLinearGradient(context, gradient, CGPointMake(0, CGRectGetMinY(rect)), CGPointMake(0, CGRectGetMaxY(rect)), 0);
    CGContextRestoreGState(context);
}

- (void)drawRect:(CGRect)rect {
    if (!_wave && [YZTheme isClassic]) {
        CGContextRef context = UIGraphicsGetCurrentContext();
        CGFloat height = 11, inset = 1;
        CGRect track = CGRectMake(inset, floor((self.bounds.size.height - height) / 2), self.bounds.size.width - 2 * inset, height);
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGFloat well[8] = { 0.62f, 0.62f, 0.64f, 1, 0.93f, 0.93f, 0.94f, 1 };
        CGGradientRef trackGradient = CGGradientCreateWithColorComponents(space, well, NULL, 2);
        YZFillRounded(context, track, height / 2, trackGradient);
        CGGradientRelease(trackGradient);
        [[UIColor colorWithWhite:0.35f alpha:0.9f] setStroke];
        UIBezierPath *outline = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(track, 0.5f, 0.5f) cornerRadius:height / 2];
        outline.lineWidth = 1;
        [outline stroke];
        CGFloat width = MAX(height - 2, floor((track.size.width - 2) * _fraction));
        if (_fraction > 0) {
            CGRect fill = CGRectMake(track.origin.x + 1, track.origin.y + 1, width, height - 2);
            CGFloat red, green, blue, alpha;
            [[YZClassic barMidColor] getRed:&red green:&green blue:&blue alpha:&alpha];
            CGFloat lit[8] = { MIN(1, red + 0.28f), MIN(1, green + 0.28f), MIN(1, blue + 0.28f), 1, red * 0.78f, green * 0.78f, blue * 0.78f, 1 };
            CGGradientRef fillGradient = CGGradientCreateWithColorComponents(space, lit, NULL, 2);
            YZFillRounded(context, fill, (height - 2) / 2, fillGradient);
            CGGradientRelease(fillGradient);
            CGFloat gloss[8] = { 1, 1, 1, 0.55f, 1, 1, 1, 0.08f };
            CGGradientRef glossGradient = CGGradientCreateWithColorComponents(space, gloss, NULL, 2);
            YZFillRounded(context, CGRectMake(fill.origin.x + 1, fill.origin.y + 1, MAX(0, fill.size.width - 2), (height - 2) / 2), (height - 2) / 4, glossGradient);
            CGGradientRelease(glossGradient);
        }
        CGColorSpaceRelease(space);
    }
}

@end

@implementation YZUpdatePanel

@synthesize compact = _compact, openPage = _openPage, later = _later, resize = _resize;

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    _items = [[NSMutableArray alloc] init];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(changed:) name:YZUpdaterChangedNotification object:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_items release];
    [_release release];
    [_signature release];
    [_sticker release];
    [_progress release];
    [_status release];
    [_openPage release];
    [_later release];
    [_resize release];
    [super dealloc];
}

- (UILabel *)labelWithText:(NSString *)text font:(UIFont *)font color:(UIColor *)color center:(BOOL)center lines:(NSInteger)lines {
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.backgroundColor = [UIColor clearColor];
    label.textAlignment = center ? YZTextAlignmentCenter : YZTextAlignmentLeft;
    label.numberOfLines = lines;
    label.lineBreakMode = lines ? YZLineBreakTailTruncation : YZLineBreakWordWrapping;
    return label;
}

- (void)add:(UIView *)view kind:(int)kind gap:(CGFloat)gap {
    NSDictionary *item = [NSDictionary dictionaryWithObjectsAndKeys:view, @"view", [NSNumber numberWithInt:kind], @"kind", [NSNumber numberWithDouble:gap], @"gap", nil];
    [_items addObject:item];
    [self addSubview:view];
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(int)action primary:(BOOL)primary {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.titleLabel.font = [YZTheme boldSystemFontOfSize:16];
    YZShrinkToFit(button.titleLabel);
    button.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
    button.tag = action;
    [button setTitle:title forState:UIControlStateNormal];
    UIColor *color = primary ? [YZTheme accentColor] : [YZTheme stateColor];
    if ([YZTheme isClassic])
        color = primary ? [YZClassic barMidColor] : [UIColor colorWithWhite:0.5f alpha:1];
    [YZClassic styleKey:button color:color radius:9 modernRadius:22];
    if (![YZTheme isClassic])
        [button setTitleColor:primary ? [UIColor whiteColor] : [YZTheme textColor] forState:UIControlStateNormal];
    [button addTarget:self action:@selector(pressed:) forControlEvents:UIControlEventTouchUpInside];
    YZMotionAttachBounce(button, 0.04f);
    return button;
}

- (void)changed:(NSNotification *)note {
    (void)note;
    [self refresh];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window)
        [self refresh];
}

- (NSString *)stateSignature {
    YZUpdater *updater = [YZUpdater shared];
    YZRelease *release = [YZUpdate cachedRelease];
    return [NSString stringWithFormat:@"%d|%d|%@|%d|%d|%@|%d", (int)updater.state, [YZUpdate checking] ? 1 : 0, release.tag, [YZUpdate isNewer:release] ? 1 : 0,
            updater.hasFile ? 1 : 0, updater.failure, [YZTheme isClassic] ? 1 : 0];
}

- (void)refresh {
    if (!self.window)
        return;
    YZUpdater *updater = [YZUpdater shared];
    NSString *signature = [self stateSignature];
    if ([signature isEqualToString:_signature ? _signature : @""]) {
        [self updateProgress];
        return;
    }
    [_signature release];
    _signature = [signature copy];
    [self rebuild];
    if (_resize)
        _resize();
    (void)updater;
}

- (void)updateProgress {
    YZUpdater *updater = [YZUpdater shared];
    _progress.fraction = updater.fraction;
    if (updater.state == YZUpdaterWorking)
        _status.text = updater.downloaded ? [NSString stringWithFormat:YZT(@"Загрузка %@ из %@ МБ"), YZMegabytes(updater.downloaded), updater.total ? YZMegabytes(updater.total) : @"?"]
                                          : YZT(@"Подготовка…");
    else if (updater.state == YZUpdaterInstalling)
        _status.text = YZT(@"Установка, приложение закроется");
}

- (void)rebuild {
    for (NSDictionary *item in _items)
        [[item objectForKey:@"view"] removeFromSuperview];
    [_items removeAllObjects];
    [_progress release];
    _progress = nil;
    [_status release];
    _status = nil;
    YZUpdater *updater = [YZUpdater shared];
    YZRelease *release = [YZUpdate cachedRelease];
    BOOL newer = [YZUpdate isNewer:release];
    BOOL checking = [YZUpdate checking];
    BOOL install = [YZUpdate canInstallInApp];
    YZUpdaterState state = updater.state;
    UIColor *text = [YZTheme textColor], *subtle = [YZTheme subtleTextColor];
    [_release release];
    _release = [release retain];
    if (!_sticker) {
        _sticker = [[UIImageView alloc] initWithFrame:CGRectZero];
        _sticker.contentMode = UIViewContentModeScaleAspectFit;
    }
    _sticker.image = [YZTheme mascotImage:@"sticker"];
    [self add:_sticker kind:YZItemSticker gap:0];
    NSString *title = checking && !release ? YZT(@"Проверка обновлений…") : !release ? YZT(@"Не удалось проверить обновления") :
                      newer ? YZT(@"Доступно обновление") : YZT(@"Установлена последняя версия");
    [self add:[self labelWithText:title font:[YZTheme boldSystemFontOfSize:20] color:text center:YES lines:0] kind:YZItemLabel gap:14];
    NSString *installed = YZVersionText([YZUpdate installedVersion]);
    NSString *latest = release ? YZVersionText(release.tag) : checking ? @"…" : @"?";
    if (_compact)
        [self add:[self labelWithText:[NSString stringWithFormat:@"%@  →  %@", installed, latest] font:[YZTheme systemFontOfSize:15] color:subtle center:YES lines:0] kind:YZItemLabel gap:6];
    else {
        [self add:[self labelWithText:[NSString stringWithFormat:@"%@: %@", YZT(@"Установлена"), installed] font:[YZTheme systemFontOfSize:16] color:subtle center:YES lines:0] kind:YZItemLabel gap:8];
        [self add:[self labelWithText:[NSString stringWithFormat:@"%@: %@", YZT(@"Новейшая"), latest] font:[YZTheme boldSystemFontOfSize:16] color:text center:YES lines:0] kind:YZItemLabel gap:2];
    }
    if (newer && !install && state == YZUpdaterIdle)
        [self add:[self labelWithText:YZT(@"Без джейлбрейка с AppSync файл ставится вручную: страница релиза откроется во вкладке") font:[YZTheme systemFontOfSize:13]
                                color:subtle center:YES lines:0] kind:YZItemLabel gap:10];
    if (state == YZUpdaterWorking || state == YZUpdaterInstalling) {
        _progress = [[YZUpdateProgress alloc] initWithFrame:CGRectZero];
        _status = [[self labelWithText:@"" font:[YZTheme systemFontOfSize:13] color:subtle center:YES lines:0] retain];
        [self add:_progress kind:YZItemProgress gap:16];
        [self add:_status kind:YZItemLabel gap:6];
        [self updateProgress];
    } else if (state == YZUpdaterFailed && [updater.failure length]) {
        [self add:[self labelWithText:updater.failure font:[YZTheme systemFontOfSize:14] color:[YZTheme errorColor] center:YES lines:0] kind:YZItemLabel gap:12];
    }
    NSMutableArray *buttons = [NSMutableArray array];
    if (state == YZUpdaterIdle && newer) {
        [buttons addObject:[self buttonWithTitle:install ? YZT(@"Установить обновление") : YZT(@"Открыть релиз") action:YZActionPrimary primary:YES]];
        if (_compact)
            [buttons addObject:[self buttonWithTitle:YZT(@"Позже") action:YZActionLater primary:NO]];
        else
            [buttons addObject:[self buttonWithTitle:YZT(@"Проверить снова") action:YZActionRefresh primary:NO]];
    } else if (state == YZUpdaterIdle && !_compact && !checking) {
        [buttons addObject:[self buttonWithTitle:YZT(@"Проверить снова") action:YZActionRefresh primary:NO]];
    } else if (state == YZUpdaterWorking) {
        [buttons addObject:[self buttonWithTitle:YZT(@"Отмена") action:YZActionCancel primary:NO]];
    } else if (state == YZUpdaterFailed) {
        [buttons addObject:[self buttonWithTitle:YZT(@"Повторить") action:YZActionPrimary primary:YES]];
        if (_compact)
            [buttons addObject:[self buttonWithTitle:YZT(@"Закрыть") action:YZActionLater primary:NO]];
    }
    if (updater.hasFile)
        [buttons addObject:[self buttonWithTitle:YZT(@"Открыть в…") action:YZActionOpenIn primary:NO]];
    BOOL notesFirst = !_compact;
    if (!notesFirst)
        [self addNotes:release subtle:subtle text:text];
    for (NSUInteger i = 0; i < [buttons count]; ++i)
        [self add:[buttons objectAtIndex:i] kind:YZItemButton gap:i == 0 ? 20 : 8];
    if (notesFirst)
        [self addNotes:release subtle:subtle text:text];
}

- (void)addNotes:(YZRelease *)release subtle:(UIColor *)subtle text:(UIColor *)text {
    if (![release.notes length])
        return;
    [self add:[self labelWithText:YZT(@"Что нового") font:[YZTheme boldSystemFontOfSize:16] color:text center:NO lines:1] kind:YZItemLabel gap:_compact ? 18 : 28];
    [self add:[self labelWithText:release.notes font:[YZTheme systemFontOfSize:14] color:subtle center:NO lines:0] kind:YZItemLabel gap:6];
}

- (void)pressed:(UIButton *)button {
    YZUpdater *updater = [YZUpdater shared];
    switch (button.tag) {
    case YZActionLater:
        if (_later)
            _later();
        break;
    case YZActionPrimary:
        if ([YZUpdate canInstallInApp]) {
            [updater startWithRelease:_release];
        } else {
            if (_openPage)
                _openPage();
            if (_compact && _later)
                _later();
        }
        break;
    case YZActionCancel:
        [updater cancel];
        break;
    case YZActionRefresh:
        [YZUpdate check:nil];
        break;
    case YZActionOpenIn:
        [updater openFileInView:self];
        break;
    }
}

- (CGFloat)layoutForWidth:(CGFloat)width {
    if (!_signature)
        return 0;
    CGFloat y = 0;
    for (NSDictionary *item in _items) {
        UIView *view = [item objectForKey:@"view"];
        int kind = [[item objectForKey:@"kind"] intValue];
        y += [[item objectForKey:@"gap"] doubleValue];
        CGFloat height = 0;
        switch (kind) {
        case YZItemSticker: {
            CGFloat side = _compact ? 104 : 120;
            view.frame = CGRectMake(floor((width - side) / 2), y, side, side);
            height = side;
            break;
        }
        case YZItemLabel:
            height = ceil([view sizeThatFits:CGSizeMake(width, 2000)].height);
            view.frame = CGRectMake(0, y, width, height);
            break;
        case YZItemProgress:
            height = YZWaveSeekBarHeight;
            view.frame = CGRectMake(0, y, width, height);
            [(YZUpdateProgress *)view applyTheme];
            break;
        case YZItemButton:
            height = 46;
            view.frame = CGRectMake(0, y, width, height);
            break;
        }
        y += height;
    }
    self.bounds = CGRectMake(0, 0, width, y);
    return y;
}

@end

@implementation YZUpdateCard

static YZUpdateCard *YZActiveCard;

+ (void)presentInView:(UIView *)host openPage:(void (^)(void))openPage {
    if (YZActiveCard || !host)
        return;
    YZUpdateCard *card = [[[YZUpdateCard alloc] initWithFrame:host.bounds] autorelease];
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    card->_panel.openPage = openPage;
    YZActiveCard = card;
    [host addSubview:card];
    [card layoutIfNeeded];
    card.alpha = 0;
    YZMotionAnimateView(card, CGAffineTransformIdentity, 1, YOZORA_MOTION_ENTER, 0, nil);
    YZMotionAnimateEnter(card->_card, CGAffineTransformConcat(CGAffineTransformMakeScale(0.86f, 0.86f), CGAffineTransformMakeTranslation(0, -16)), 0, YOZORA_MOTION_WOBBLE, 0);
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    self.backgroundColor = [YZTheme scrimColor];
    YZPlateView *plate = [[YZPlateView alloc] initWithFrame:CGRectZero];
    plate.surfaceInModern = YES;
    plate.sheetCornersInModern = YES;
    [plate applyTheme];
    _card = plate;
    [self addSubview:_card];
    _scroll = [[YZScrollView alloc] initWithFrame:CGRectZero];
    _scroll.delaysContentTouches = NO;
    _scroll.showsHorizontalScrollIndicator = NO;
    _scroll.alwaysBounceVertical = NO;
    [_card addSubview:_scroll];
    _panel = [[YZUpdatePanel alloc] initWithFrame:CGRectZero];
    _panel.compact = YES;
    __block YZUpdateCard *card = self;
    _panel.later = ^{ [card dismiss]; };
    _panel.resize = ^{ [card setNeedsLayout]; };
    [_scroll addSubview:_panel];
    return self;
}

- (void)dealloc {
    [_card release];
    [_scroll release];
    [_panel release];
    [super dealloc];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window)
        [_panel refresh];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat pad = 24;
    CGFloat width = MIN(self.bounds.size.width - 48, 360);
    CGFloat inner = MAX(0, width - 2 * pad);
    CGFloat content = [_panel layoutForWidth:inner];
    CGFloat height = content + 2 * pad;
    CGFloat maxHeight = self.bounds.size.height - 32;
    if (height > maxHeight)
        height = maxHeight;
    CGFloat innerHeight = MAX(0, height - 2 * pad);
    CGAffineTransform held = _card.transform;
    _card.transform = CGAffineTransformIdentity;
    _card.frame = CGRectMake(floor((self.bounds.size.width - width) / 2), floor((self.bounds.size.height - height) / 2), width, height);
    _scroll.frame = CGRectMake(pad, pad, inner, innerHeight);
    _panel.frame = CGRectMake(0, 0, inner, content);
    _scroll.contentSize = CGSizeMake(inner, content);
    _scroll.scrollEnabled = content > innerHeight + 1;
    _card.transform = held;
}

- (void)dismiss {
    self.userInteractionEnabled = NO;
    YZActiveCard = nil;
    [self retain];
    YZMotionAnimateView(_card, CGAffineTransformConcat(CGAffineTransformMakeScale(0.92f, 0.92f), CGAffineTransformMakeTranslation(0, -12)), 0, YOZORA_MOTION_DISMISS, 0, nil);
    YZMotionAnimateView(self, CGAffineTransformIdentity, 0, YOZORA_MOTION_DISMISS, 0, ^(BOOL finished) {
        (void)finished;
        [self removeFromSuperview];
        [self autorelease];
    });
}

@end

@implementation YZUpdateController

@synthesize openPage = _openPage;

- (void)dealloc {
    [_fill removeFromSuperview];
    [_fill release];
    [_scroll release];
    [_card release];
    [_panel release];
    [_openPage release];
    [super dealloc];
}

- (void)loadView {
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]];
    scroll.alwaysBounceVertical = YES;
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll = scroll;
    self.view = scroll;
    YZPlateView *plate = [[YZPlateView alloc] initWithFrame:CGRectZero];
    plate.sheetCornersInModern = YES;
    _card = plate;
    [_scroll addSubview:_card];
    _panel = [[YZUpdatePanel alloc] initWithFrame:CGRectZero];
    __block YZUpdateController *controller = self;
    _panel.openPage = ^{ if (controller->_openPage) controller->_openPage(); };
    _panel.resize = ^{ [controller.view setNeedsLayout]; };
    [_card addSubview:_panel];
    _fill = [[YZBarFill alloc] initWithFrame:CGRectZero];
}

- (void)restyle {
    self.view.backgroundColor = [YZTheme screenColor];
    YZPaintBehindScreens(self.navigationController);
    [YZTheme styleTransparentNavigationBar:self.navigationController.navigationBar];
    [(YZPlateView *)_card applyTheme];
    [_fill applyTheme];
    [_fill attachToScrollView:_scroll controller:self];
    YZInstallBarTitle(self, YZT(@"Обновление"), self, @selector(back));
}

- (void)back { [self.navigationController popViewControllerAnimated:YES]; }

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self restyle];
    if (![YZUpdate checking] && [NSDate timeIntervalSinceReferenceDate] - [YZUpdate lastCheck] > 120)
        [YZUpdate check:nil];
    [_panel refresh];
    [self.view setNeedsLayout];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.view.bounds.size.width;
    CGFloat cardWidth = MIN(520, width - 32);
    CGFloat pad = 24;
    CGFloat top = 8;
    CGFloat content = [_panel layoutForWidth:cardWidth - 2 * pad];
    _card.frame = CGRectMake(floor((width - cardWidth) / 2), top, cardWidth, content + 2 * pad);
    _panel.frame = CGRectMake(pad, pad, cardWidth - 2 * pad, content);
    _scroll.contentSize = CGSizeMake(width, CGRectGetMaxY(_card.frame) + 24);
    UINavigationBar *bar = self.navigationController.navigationBar;
    if (bar && [[[UIDevice currentDevice] systemVersion] floatValue] < 7.0f) {
        UIEdgeInsets inset = _scroll.contentInset;
        CGFloat overlap = [YZTheme barOverlap:bar];
        if (fabs(inset.top - overlap) > 0.5) {
            inset.top = overlap;
            _scroll.contentInset = inset;
            _scroll.scrollIndicatorInsets = inset;
            _scroll.contentOffset = CGPointMake(0, -overlap);
        }
    }
    YZInstallBarTitle(self, YZT(@"Обновление"), self, @selector(back));
    [_fill attachToScrollView:_scroll controller:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if ([self respondsToSelector:NSSelectorFromString(@"setWantsFullScreenLayout:")])
        [self setValue:[NSNumber numberWithBool:YES] forKey:@"wantsFullScreenLayout"];
    _scroll.delegate = (id)self;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [_fill attachToScrollView:scrollView controller:self];
}

@end
