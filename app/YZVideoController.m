#import "YZVideoController.h"
#import "YZCompat.h"
#import "YZMediaPlayer.h"
#import "YZMotion.h"
#import "YZPlayerViews.h"
#import "YZStrings.h"
#import "YZTheme.h"
#import "YZWaveSeekBar.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#include <math.h>

static const NSTimeInterval YZChromeSeconds = 3.5;
static const double YZSkipSeconds = 10;
static const CGFloat YZPlaySide = 76;
static const CGFloat YZSkipSide = 56;
static const CGFloat YZCenterGap = 28;
static const CGFloat YZBottomHeight = 108;
static const CGFloat YZTopHeight = 56;

static NSString *YZClock(double seconds) {
    if (!isfinite(seconds) || seconds < 0)
        seconds = 0;
    long total = (long)seconds;
    if (total >= 3600)
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", total / 3600, (total / 60) % 60, total % 60];
    return [NSString stringWithFormat:@"%ld:%02ld", total / 60, total % 60];
}

static NSString *YZRateText(double rate) {
    return [[NSString stringWithFormat:@"%g", rate] stringByAppendingString:@"×"];
}

// a view that is hidden pops in on the wobble, one that is already up keeps its place so a changing word does not flicker
static void YZPopIn(UIView *view) {
    if (view.alpha > 0.5f)
        return;
    view.alpha = 1;
    view.transform = CGAffineTransformIdentity;
    YZMotionAnimateEnter(view, CGAffineTransformMakeScale(0.8f, 0.8f), 0, YOZORA_MOTION_WOBBLE, 0);
}

// a round dark button behind a white glyph, so it holds against any picture
static UIButton *YZRoundButton(UIImage *image, CGFloat side) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.frame = CGRectMake(0, 0, side, side);
    button.backgroundColor = [UIColor colorWithWhite:0 alpha:0.34f];
    button.layer.cornerRadius = side / 2;
    [button setImage:image forState:UIControlStateNormal];
    YZMotionAttachBounce(button, 0.08f);
    return button;
}

// the line of a toast: a dark pill with a word or two
static UILabel *YZToastLabel(void) {
    UILabel *label = [[[UILabel alloc] init] autorelease];
    label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.62f];
    label.textColor = [UIColor whiteColor];
    label.font = [YZTheme boldSystemFontOfSize:15];
    label.textAlignment = YZTextAlignmentCenter;
    label.layer.cornerRadius = 18;
    label.alpha = 0;
    label.userInteractionEnabled = NO;
    return label;
}

@interface YZVideoController () <UIGestureRecognizerDelegate> {
    unsigned _mediaID;
    NSString *_title;
    BOOL _video;
    YZMediaPlayer *_mediaPlayer;
    CALayer *_layer;
    NSTimer *_updateTimer;
    NSTimer *_hideTimer;
    UIView *_stage;
    YZScrimView *_topScrim;
    YZScrimView *_bottomScrim;
    UIView *_top;
    UIView *_center;
    UIView *_bottom;
    UIButton *_back;
    UILabel *_titleLabel;
    UIButton *_skipBack;
    UIButton *_skipForward;
    YZPlayButton *_play;
    YZWaveSeekBar *_seek;
    UILabel *_elapsed;
    UILabel *_remaining;
    UIButton *_mute;
    UIButton *_speed;
    UIButton *_aspect;
    UIView *_bubble;
    UILabel *_bubbleLabel;
    UILabel *_toast;
    UIControl *_menuBackdrop;
    YZSpeedMenu *_menu;
    double _duration;
    double _position;
    double _skipSum;
    double _rateBeforeHold;
    CGFloat _brightnessBefore;
    CGFloat _brightnessAtStart;
    BOOL _scrubbing;
    BOOL _shut;
    BOOL _chromeShown;
    BOOL _fill;
    BOOL _holding;
    BOOL _brightnessChanged;
    BOOL _idleWas;
    BOOL _appeared;
    // what the controls show now, so a tick of the timer redraws only what changed: a glyph drawn again every
    // quarter second took main thread time that the fade of the controls needs on an iphone 4s
    int _shownMute;
    double _shownRate;
    NSUInteger _chromeToken;
}
- (void)refreshPlayback;
- (void)startPlayback;
- (void)finishFailed:(BOOL)failed;
- (void)updateControls;
- (void)setChromeShown:(BOOL)shown animated:(BOOL)animated;
- (void)closeMenu;
@end

@implementation YZVideoController

@synthesize delegate = _delegate;
@synthesize mediaID = _mediaID;

- (id)initWithPlayer:(YZMediaPlayer *)player title:(NSString *)title {
    self = [super init];
    if (!self)
        return nil;
    _mediaPlayer = [player retain];
    _mediaID = player.mediaID;
    _video = player.videoLayer != nil;
    _title = [title copy];
    // ios 13 and newer present a screen as a card that leaves the top of the page showing (a phone with a notch
    // shows it most), the player is the whole screen
    self.modalPresentationStyle = UIModalPresentationFullScreen;
    return self;
}

- (void)dealloc {
    [self shutDown];
    for (id owned in [NSArray arrayWithObjects:_stage, _topScrim, _bottomScrim, _top, _center, _bottom, _back, _titleLabel, _skipBack, _skipForward, _play,
                      _seek, _elapsed, _remaining, _mute, _speed, _aspect, _bubble, _bubbleLabel, _toast, nil])
        [owned release];
    [_mediaPlayer release];
    [_title release];
    [super dealloc];
}

#pragma mark view

- (UILabel *)labelWithSize:(CGFloat)size alignment:(int)alignment {
    UILabel *label = [[[UILabel alloc] init] autorelease];
    label.backgroundColor = [UIColor clearColor];
    label.textColor = [UIColor whiteColor];
    label.font = [YZTheme boldSystemFontOfSize:size];
    label.textAlignment = alignment;
    return label;
}

- (void)loadView {
    UIView *view = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 480)] autorelease];
    view.backgroundColor = [UIColor blackColor];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view = view;

    _stage = [[UIView alloc] initWithFrame:view.bounds];
    _stage.clipsToBounds = YES;
    _stage.userInteractionEnabled = NO;
    [view addSubview:_stage];
    _topScrim = [[YZScrimView alloc] initWithFrame:CGRectZero fromTop:YES];
    _bottomScrim = [[YZScrimView alloc] initWithFrame:CGRectZero fromTop:NO];
    [view addSubview:_topScrim];
    [view addSubview:_bottomScrim];

    _top = [[UIView alloc] init];
    _back = [YZRoundButton([YZTheme icon:YZIconBack size:24 color:[UIColor whiteColor]], 44) retain];
    _back.accessibilityLabel = YZT(@"Закрыть");
    [_back addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    _titleLabel = [[self labelWithSize:17 alignment:YZTextAlignmentLeft] retain];
    _titleLabel.text = _title;
    YZShrinkToFit(_titleLabel);
    [_top addSubview:_back];
    [_top addSubview:_titleLabel];
    [view addSubview:_top];

    _center = [[UIView alloc] init];
    _skipBack = [YZRoundButton(YZPlayerSkipImage(NO, 30, [UIColor whiteColor]), YZSkipSide) retain];
    _skipBack.accessibilityLabel = YZT(@"Назад на 10 секунд");
    [_skipBack addTarget:self action:@selector(skipBackTapped) forControlEvents:UIControlEventTouchUpInside];
    _skipForward = [YZRoundButton(YZPlayerSkipImage(YES, 30, [UIColor whiteColor]), YZSkipSide) retain];
    _skipForward.accessibilityLabel = YZT(@"Вперёд на 10 секунд");
    [_skipForward addTarget:self action:@selector(skipForwardTapped) forControlEvents:UIControlEventTouchUpInside];
    _play = [[YZPlayButton alloc] initWithFrame:CGRectMake(0, 0, YZPlaySide, YZPlaySide)];
    [_play addTarget:self action:@selector(playTapped) forControlEvents:UIControlEventTouchUpInside];
    YZMotionAttachBounce(_play, 0.06f);
    [_center addSubview:_skipBack];
    [_center addSubview:_play];
    [_center addSubview:_skipForward];
    [view addSubview:_center];

    _bottom = [[UIView alloc] init];
    _seek = [[YZWaveSeekBar alloc] init];
    // an ordinary bar: the wave that travelled over the picture is gone, the played line and a round handle remain
    _seek.plain = YES;
    _seek.playedColor = YZPlayerAccent();
    _seek.enabled = NO;
    _seek.accessibilityLabel = YZT(@"Перемотка");
    [_seek addTarget:self action:@selector(scrubMoved) forControlEvents:UIControlEventValueChanged];
    [_seek addTarget:self action:@selector(scrubEnded) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    _elapsed = [[self labelWithSize:13 alignment:YZTextAlignmentLeft] retain];
    _remaining = [[self labelWithSize:13 alignment:YZTextAlignmentRight] retain];
    _mute = [YZRoundButton(YZPlayerSpeakerImage(NO, 24, [UIColor whiteColor]), 44) retain];
    [_mute addTarget:self action:@selector(muteTapped) forControlEvents:UIControlEventTouchUpInside];
    _speed = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _speed.frame = CGRectMake(0, 0, 64, 40);
    _speed.backgroundColor = [UIColor colorWithWhite:0 alpha:0.34f];
    _speed.layer.cornerRadius = 20;
    _speed.titleLabel.font = [YZTheme boldSystemFontOfSize:16];
    _speed.accessibilityLabel = YZT(@"Скорость");
    [_speed addTarget:self action:@selector(speedTapped) forControlEvents:UIControlEventTouchUpInside];
    YZMotionAttachBounce(_speed, 0.08f);
    _aspect = [YZRoundButton(YZPlayerAspectImage(YES, 24, [UIColor whiteColor]), 44) retain];
    [_aspect addTarget:self action:@selector(aspectTapped) forControlEvents:UIControlEventTouchUpInside];
    for (UIView *item in [NSArray arrayWithObjects:_seek, _elapsed, _remaining, _mute, _speed, _aspect, nil])
        [_bottom addSubview:item];
    [view addSubview:_bottom];

    // the feedback of a double tap and the word of a gesture
    _bubble = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 112, 112)];
    _bubble.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18f];
    _bubble.layer.cornerRadius = 56;
    _bubble.alpha = 0;
    _bubble.userInteractionEnabled = NO;
    _bubbleLabel = [[self labelWithSize:20 alignment:YZTextAlignmentCenter] retain];
    _bubbleLabel.frame = _bubble.bounds;
    [_bubble addSubview:_bubbleLabel];
    [view addSubview:_bubble];
    _toast = [YZToastLabel() retain];
    [view addSubview:_toast];

    // a button or the bar keeps its own touches, on iOS 5 a recognizer on the parent would swallow them
    UITapGestureRecognizer *doubleTap = [[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(videoDoubleTapped:)] autorelease];
    doubleTap.numberOfTapsRequired = 2;
    doubleTap.delegate = self;
    [view addGestureRecognizer:doubleTap];
    UITapGestureRecognizer *tap = [[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(videoTapped)] autorelease];
    tap.delegate = self;
    [tap requireGestureRecognizerToFail:doubleTap];
    [view addGestureRecognizer:tap];
    UILongPressGestureRecognizer *hold = [[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(videoHeld:)] autorelease];
    hold.minimumPressDuration = 0.45;
    hold.delegate = self;
    [view addGestureRecognizer:hold];
    UIPinchGestureRecognizer *pinch = [[[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(videoPinched:)] autorelease];
    pinch.delegate = self;
    [view addGestureRecognizer:pinch];
    UIPanGestureRecognizer *pan = [[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(videoPanned:)] autorelease];
    pan.maximumNumberOfTouches = 1;
    pan.delegate = self;
    [view addGestureRecognizer:pan];
    _chromeShown = YES;
    [self updateControls];
}

// a touch on a control belongs to the control
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    (void)recognizer;
    for (UIView *view = touch.view; view; view = view.superview) {
        if ([view isKindOfClass:[UIControl class]])
            return NO;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    (void)recognizer;
    (void)other;
    return NO;
}

- (UIEdgeInsets)safeInsets {
    UIEdgeInsets insets = UIEdgeInsetsZero;
    if ([self.view respondsToSelector:@selector(safeAreaInsets)])
        insets = [[self.view valueForKey:@"safeAreaInsets"] UIEdgeInsetsValue];
    return insets;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // once the player is shut the screen only slides away: the safe insets change while it leaves, and laying the
    // controls out again inside the transition moved them sideways before they were gone
    if (_shut)
        return;
    CGRect bounds = self.view.bounds;
    CGFloat width = bounds.size.width, height = bounds.size.height;
    UIEdgeInsets safe = [self safeInsets];
    CGFloat left = MAX(safe.left, (CGFloat)0) + 16, right = MAX(safe.right, (CGFloat)0) + 16;
    _stage.frame = bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _layer.frame = _stage.bounds;
    [CATransaction commit];

    CGFloat topHeight = safe.top + YZTopHeight;
    _topScrim.frame = CGRectMake(0, 0, width, topHeight + 40);
    _top.frame = CGRectMake(0, 0, width, topHeight);
    _back.frame = CGRectMake(left, safe.top + 6, 44, 44);
    _titleLabel.frame = CGRectMake(left + 56, safe.top + 6, MAX(width - left - right - 56, (CGFloat)0), 44);

    CGFloat bottomHeight = safe.bottom + YZBottomHeight;
    _bottomScrim.frame = CGRectMake(0, height - bottomHeight - 56, width, bottomHeight + 56);
    _bottom.frame = CGRectMake(0, height - bottomHeight, width, bottomHeight);
    _seek.frame = CGRectMake(left - YZWaveSeekBarInset, 6, width - left - right + 2 * YZWaveSeekBarInset, YZWaveSeekBarHeight);
    _elapsed.frame = CGRectMake(left, 36, 72, 20);
    _remaining.frame = CGRectMake(width - right - 96, 36, 96, 20);
    CGFloat buttons = 60;
    _mute.frame = CGRectMake(left, buttons, 44, 44);
    _aspect.frame = CGRectMake(width - right - 44, buttons, 44, 44);
    _speed.frame = CGRectMake(CGRectGetMinX(_aspect.frame) - 12 - 64, buttons + 2, 64, 40);

    CGFloat cluster = YZSkipSide + YZCenterGap + YZPlaySide + YZCenterGap + YZSkipSide;
    CGFloat centerY = (height - YZPlaySide) / 2;
    _center.frame = CGRectMake((width - cluster) / 2, centerY, cluster, YZPlaySide);
    _skipBack.frame = CGRectMake(0, (YZPlaySide - YZSkipSide) / 2, YZSkipSide, YZSkipSide);
    _play.frame = CGRectMake(YZSkipSide + YZCenterGap, 0, YZPlaySide, YZPlaySide);
    _skipForward.frame = CGRectMake(cluster - YZSkipSide, (YZPlaySide - YZSkipSide) / 2, YZSkipSide, YZSkipSide);

    CGFloat toastWidth = MIN(width - 32, (CGFloat)220);
    _toast.frame = CGRectMake((width - toastWidth) / 2, safe.top + YZTopHeight + 8, toastWidth, 36);
    if (_menu)
        [self placeMenu];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self startPlayback];
}

// the controls arrive on the wobble, one group after the other
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_appeared)
        return;
    _appeared = YES;
    UIView *groups[3] = { _top, _center, _bottom };
    for (int i = 0; i < 3; ++i)
        YZMotionAnimateEnter(groups[i], CGAffineTransformMakeScale(0.9f, 0.9f), 0, YOZORA_MOTION_WOBBLE, 0.05 * i);
    [self armHideTimer];
}

- (BOOL)prefersStatusBarHidden { return YES; }

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return YZPresentedOrientation();
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    (void)orientation;
    return YES;
}

#pragma mark playback

- (void)startPlayback {
    _layer = _mediaPlayer.videoLayer;
    _idleWas = [UIApplication sharedApplication].idleTimerDisabled;
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    _brightnessBefore = [UIScreen mainScreen].brightness;
    if (_layer) {
        // the page sized the layer to the picture, here the picture fits the screen whole
        ((AVPlayerLayer *)_layer).videoGravity = AVLayerVideoGravityResizeAspect;
        _layer.frame = _stage.bounds;
        [_stage.layer insertSublayer:_layer atIndex:0];
    }
    _updateTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(refreshPlayback) userInfo:nil repeats:YES];
    [self refreshPlayback];
}

- (void)refreshPlayback {
    if (_shut)
        return;
    if (_mediaPlayer.failed) {
        [self finishFailed:YES];
        return;
    }
    _duration = _mediaPlayer.duration;
    _position = _mediaPlayer.position;
    [self updateControls];
}

- (void)play { [_mediaPlayer play]; }
- (void)pause { [_mediaPlayer pause]; }
- (void)seekTo:(double)seconds { [_mediaPlayer seekTo:seconds]; }

// the browser owns playback, dismissing this view only gives its layer back to the page
- (void)shutDown {
    if (_shut)
        return;
    _shut = YES;
    [_hideTimer invalidate];
    _hideTimer = nil;
    [_updateTimer invalidate];
    _updateTimer = nil;
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [_menu removeFromSuperview];
    [_menu release];
    _menu = nil;
    [_menuBackdrop removeFromSuperview];
    [_menuBackdrop release];
    _menuBackdrop = nil;
    if (_holding)
        _mediaPlayer.playbackRate = _rateBeforeHold;
    _holding = NO;
    [UIApplication sharedApplication].idleTimerDisabled = _idleWas;
    if (_brightnessChanged)
        [UIScreen mainScreen].brightness = _brightnessBefore;
    // the layer stays in the stage until the screen is gone: taking it out at once left a black screen sliding
    // down over the page. the page takes it back and sets its gravity when it places the picture again
    _layer = nil;
}

- (void)finishFailed:(BOOL)failed {
    if (_shut)
        return;
    // leaving the full screen player does not stop the video, it goes on playing on the page
    [self shutDown];
    [_delegate videoControllerFinished:self failed:failed];
}

#pragma mark controls

- (void)closeTapped {
    [self finishFailed:NO];
}

- (void)playTapped {
    if (_mediaPlayer.playing || _mediaPlayer.buffering) {
        [self pause];
    } else {
        // a video that played to its end starts over
        if (_duration > 0 && _position >= _duration - 0.3)
            [self seekTo:0];
        [self play];
    }
    // the glyph answers the tap now, not at the next tick of the timer
    [self updateControls];
    [self showChromeAndArmTimer];
}

- (void)turnSkipButton:(UIButton *)button forward:(BOOL)forward {
    YZMotionAnimateEnter(button, CGAffineTransformMakeRotation(forward ? (CGFloat)0.5 : (CGFloat)-0.5), 1, YOZORA_MOTION_WOBBLE, 0);
}

- (void)skipBackTapped {
    [self turnSkipButton:_skipBack forward:NO];
    [_mediaPlayer skipBy:-YZSkipSeconds];
    [self showChromeAndArmTimer];
}

- (void)skipForwardTapped {
    [self turnSkipButton:_skipForward forward:YES];
    [_mediaPlayer skipBy:YZSkipSeconds];
    [self showChromeAndArmTimer];
}

- (void)muteTapped {
    _mediaPlayer.muted = !_mediaPlayer.muted;
    [self updateControls];
    [self showChromeAndArmTimer];
}

- (void)aspectTapped {
    [self setFill:!_fill];
    [self showChromeAndArmTimer];
}

- (void)setFill:(BOOL)fill {
    if (fill == _fill)
        return;
    _fill = fill;
    if ([_layer isKindOfClass:[AVPlayerLayer class]])
        ((AVPlayerLayer *)_layer).videoGravity = fill ? AVLayerVideoGravityResizeAspectFill : AVLayerVideoGravityResizeAspect;
    [_aspect setImage:YZPlayerAspectImage(!fill, 24, [UIColor whiteColor]) forState:UIControlStateNormal];
    _aspect.accessibilityLabel = fill ? YZT(@"Целиком") : YZT(@"Во весь экран");
    [self showToast:fill ? YZT(@"Во весь экран") : YZT(@"Целиком") holdOpen:NO];
}

#pragma mark seek

- (void)scrubMoved {
    _scrubbing = YES;
    [_hideTimer invalidate];
    _hideTimer = nil;
    double target = _seek.value * _duration;
    _elapsed.text = YZClock(target);
    _remaining.text = [@"-" stringByAppendingString:YZClock(_duration - target)];
}

- (void)scrubEnded {
    if (!_scrubbing)
        return;
    _scrubbing = NO;
    [self seekTo:_seek.value * _duration];
    // the bar shows where the finger let go until the player reports the new position
    _position = _seek.value * _duration;
    [self showChromeAndArmTimer];
}

#pragma mark speed

- (void)placeMenu {
    CGSize size = [YZSpeedMenu menuSize];
    CGRect chip = [self.view convertRect:_speed.frame fromView:_bottom];
    CGFloat right = CGRectGetMaxX(chip), bottom = CGRectGetMinY(chip) - 8;
    // the menu grows from its lower right corner, where the chip is
    _menu.layer.anchorPoint = CGPointMake(1, 1);
    _menu.layer.position = CGPointMake(right, MAX(bottom, size.height + 8));
}

- (void)speedTapped {
    if (_menu) {
        [self closeMenu];
        return;
    }
    [_hideTimer invalidate];
    _hideTimer = nil;
    _menuBackdrop = [[UIControl alloc] initWithFrame:self.view.bounds];
    _menuBackdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_menuBackdrop addTarget:self action:@selector(closeMenu) forControlEvents:UIControlEventTouchDown];
    [self.view addSubview:_menuBackdrop];
    YZVideoController *me = self;
    _menu = [[YZSpeedMenu alloc] initWithSelectedRate:_mediaPlayer.playbackRate choose:^(double rate) {
        me->_mediaPlayer.playbackRate = rate;
        [me updateControls];
        [me closeMenu];
    }];
    [self.view addSubview:_menu];
    [self placeMenu];
    YZMotionAnimateEnter(_menu, CGAffineTransformMakeScale(0.6f, 0.6f), 0, YOZORA_MOTION_WOBBLE, 0);
}

- (void)closeMenu {
    if (!_menu)
        return;
    YZSpeedMenu *menu = _menu;
    UIControl *backdrop = _menuBackdrop;
    _menu = nil;
    _menuBackdrop = nil;
    backdrop.userInteractionEnabled = NO;
    YZMotionAnimateView(menu, CGAffineTransformMakeScale(0.7f, 0.7f), 0, YOZORA_MOTION_DISMISS, 0, ^(BOOL finished) {
        (void)finished;
        [menu removeFromSuperview];
        [backdrop removeFromSuperview];
        [menu release];
        [backdrop release];
    });
    [self armHideTimer];
}

#pragma mark gestures

- (void)videoTapped {
    if (_menu) {
        [self closeMenu];
        return;
    }
    [self setChromeShown:!_chromeShown animated:YES];
    if (_chromeShown)
        [self armHideTimer];
}

// two taps on the sides skip ten seconds each way, in the middle they play or pause
- (void)videoDoubleTapped:(UITapGestureRecognizer *)tap {
    CGFloat x = [tap locationInView:self.view].x, width = self.view.bounds.size.width;
    if (x > width / 3 && x < 2 * width / 3) {
        [self playTapped];
        return;
    }
    BOOL forward = x >= 2 * width / 3;
    // taps in a row on one side add up on the bubble, a tap on the other side starts again
    BOOL continued = _skipSum != 0 && (_skipSum > 0) == forward;
    _skipSum = continued ? _skipSum + (forward ? YZSkipSeconds : -YZSkipSeconds) : (forward ? YZSkipSeconds : -YZSkipSeconds);
    [_mediaPlayer skipBy:forward ? YZSkipSeconds : -YZSkipSeconds];
    [self showBubbleAtX:forward ? width * 0.8f : width * 0.2f];
}

- (void)showBubbleAtX:(CGFloat)x {
    _bubble.center = CGPointMake(x, self.view.bounds.size.height / 2);
    _bubbleLabel.text = [NSString stringWithFormat:@"%@%d", _skipSum > 0 ? @"+" : @"−", (int)fabs(_skipSum)];
    YZPopIn(_bubble);
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideBubble) object:nil];
    [self performSelector:@selector(hideBubble) withObject:nil afterDelay:0.7];
}

- (void)hideBubble {
    _skipSum = 0;
    YZMotionAnimateView(_bubble, CGAffineTransformMakeScale(0.7f, 0.7f), 0, YOZORA_MOTION_DISMISS, 0, nil);
}

// holding a finger on the picture plays at twice the speed until it lifts
- (void)videoHeld:(UILongPressGestureRecognizer *)hold {
    if (hold.state == UIGestureRecognizerStateBegan) {
        if (!_mediaPlayer.playing)
            return;
        _holding = YES;
        _rateBeforeHold = _mediaPlayer.playbackRate;
        _mediaPlayer.playbackRate = 2;
        [self showToast:YZRateText(2) holdOpen:YES];
    } else if (_holding && (hold.state == UIGestureRecognizerStateEnded || hold.state == UIGestureRecognizerStateCancelled || hold.state == UIGestureRecognizerStateFailed)) {
        _holding = NO;
        _mediaPlayer.playbackRate = _rateBeforeHold;
        [self hideToast];
    }
}

// pulling the picture apart fills the screen with it, pinching together fits it whole
- (void)videoPinched:(UIPinchGestureRecognizer *)pinch {
    if (pinch.state != UIGestureRecognizerStateEnded)
        return;
    if (pinch.scale > 1.15f)
        [self setFill:YES];
    else if (pinch.scale < 0.85f)
        [self setFill:NO];
}

// a vertical stroke on the left half changes the brightness of the screen
- (void)videoPanned:(UIPanGestureRecognizer *)pan {
    CGPoint start = [pan locationInView:self.view];
    if (pan.state == UIGestureRecognizerStateBegan) {
        _brightnessAtStart = [UIScreen mainScreen].brightness;
        CGPoint speed = [pan velocityInView:self.view];
        // only a stroke that is mostly vertical and begins on the left half counts, the rest is left to the taps
        if (fabs(speed.y) <= fabs(speed.x) || start.x > self.view.bounds.size.width / 2) {
            pan.enabled = NO;
            pan.enabled = YES;
        }
        return;
    }
    if (pan.state != UIGestureRecognizerStateChanged)
        return;
    CGFloat height = MAX(self.view.bounds.size.height, (CGFloat)1);
    CGFloat level = _brightnessAtStart - [pan translationInView:self.view].y / (height * 0.7f);
    level = MIN((CGFloat)1, MAX((CGFloat)0.02, level));
    _brightnessChanged = YES;
    [UIScreen mainScreen].brightness = level;
    [self showToast:[NSString stringWithFormat:@"%@ %d%%", YZT(@"Яркость"), (int)(level * 100 + 0.5f)] holdOpen:NO];
}

#pragma mark toast

- (void)showToast:(NSString *)text holdOpen:(BOOL)holdOpen {
    _toast.text = text;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideToast) object:nil];
    YZPopIn(_toast);
    if (!holdOpen)
        [self performSelector:@selector(hideToast) withObject:nil afterDelay:1.0];
}

- (void)hideToast {
    YZMotionAnimateView(_toast, CGAffineTransformMakeScale(0.85f, 0.85f), 0, YOZORA_MOTION_DISMISS, 0, nil);
}

#pragma mark chrome

- (void)showChromeAndArmTimer {
    [self setChromeShown:YES animated:YES];
    [self armHideTimer];
}

// the controls go away by themselves while a video plays and nothing is touched
- (void)armHideTimer {
    [_hideTimer invalidate];
    _hideTimer = nil;
    if (_shut || !_video || _menu)
        return;
    _hideTimer = [NSTimer scheduledTimerWithTimeInterval:YZChromeSeconds target:self selector:@selector(hideChrome) userInfo:nil repeats:NO];
}

- (void)hideChrome {
    _hideTimer = nil;
    if (_video && !_scrubbing && !_menu && _mediaPlayer.playing)
        [self setChromeShown:NO animated:YES];
}

// the groups arrive with the wobble and leave on the faster curve, a little apart in time; the scrims only fade
- (void)setChromeShown:(BOOL)shown animated:(BOOL)animated {
    if (shown == _chromeShown && animated)
        return;
    _chromeShown = shown;
    NSArray *groups = [NSArray arrayWithObjects:_top, _center, _bottom, nil];
    // no scale on the way out: a group shrinks toward its middle, so the buttons at its right end slid to the left
    // while the group faded. the bars only move away vertically, the middle group just fades
    CGAffineTransform away[3] = {
        CGAffineTransformMakeTranslation(0, -14),
        CGAffineTransformIdentity,
        CGAffineTransformMakeTranslation(0, 14)
    };
    NSUInteger token = ++_chromeToken;
    for (NSUInteger i = 0; i < 3; ++i) {
        UIView *group = [groups objectAtIndex:i];
        group.userInteractionEnabled = shown;
        // a group that fades over the picture is drawn off screen again on every frame, because its buttons have
        // translucent backs. the bottom group holds the travelling wave, which would redraw the cache as well
        BOOL cached = animated && group != _bottom;
        if (cached) {
            group.layer.rasterizationScale = [UIScreen mainScreen].scale;
            group.layer.shouldRasterize = YES;
        }
        YZMotionAnimateView(group, shown ? CGAffineTransformIdentity : away[i], shown ? 1 : 0, shown ? YOZORA_MOTION_WOBBLE : YOZORA_MOTION_DISMISS,
                            animated ? 0.04 * i : 0, ^(BOOL finished) {
            (void)finished;
            // a newer change of the controls owns the cache now
            if (token == _chromeToken)
                group.layer.shouldRasterize = NO;
        });
    }
    [YZTheme animate:^{
        _topScrim.alpha = shown ? 1 : 0;
        _bottomScrim.alpha = shown ? 1 : 0;
    } completion:nil];
}

- (void)updateControls {
    BOOL playing = _mediaPlayer.playing;
    BOOL live = _duration <= 0;
    [_play setPlaying:playing || _mediaPlayer.buffering animated:_appeared];
    _play.busy = _mediaPlayer.buffering;
    _play.accessibilityLabel = playing ? YZT(@"Пауза") : YZT(@"Воспроизвести");
    _seek.enabled = !live;
    _seek.waving = playing;
    if (!_seek.dragging) {
        [_seek setValue:live ? 0 : (float)(_position / _duration) gliding:playing];
        _seek.buffered = live ? 0 : (float)(_mediaPlayer.bufferedEnd / _duration);
    }
    if (!_scrubbing) {
        _elapsed.text = YZClock(_position);
        _remaining.text = live ? YZT(@"В эфире") : [@"-" stringByAppendingString:YZClock(_duration - _position)];
    }
    double rate = _mediaPlayer.playbackRate;
    if (rate != _shownRate) {
        _shownRate = rate;
        [_speed setTitle:YZRateText(rate) forState:UIControlStateNormal];
    }
    int muteState = _mediaPlayer.muted ? 2 : 1;
    if (muteState != _shownMute) {
        _shownMute = muteState;
        [_mute setImage:YZPlayerSpeakerImage(muteState == 2, 24, [UIColor whiteColor]) forState:UIControlStateNormal];
        _mute.accessibilityLabel = muteState == 2 ? YZT(@"Включить звук") : YZT(@"Выключить звук");
    }
    // the controls of a picture stay up while sound plays alone and the video is paused
    // a stall of a playing video must not bring the controls back in the middle of their way out
    if (!playing && !_mediaPlayer.buffering && !_chromeShown)
        [self setChromeShown:YES animated:YES];
}

@end
