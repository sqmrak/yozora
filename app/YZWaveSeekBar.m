#import "YZWaveSeekBar.h"

#include <math.h>

#import "YZTheme.h"

#define WAVE_PERIOD 26.0
#define WAVE_AMPLITUDE 3.0
#define WAVE_LINE 4.0
#define WAVE_GAP 6.0
#define THUMB_HEIGHT 24.0

static NSString *const YZWavePhaseKey = @"yz.wave.phase";
static NSString *const YZWaveMorphKey = @"yz.wave.morph";

// the spring of the wobble as a timing curve: it passes its target and settles
static CAMediaTimingFunction *YZWaveSpring(void) {
    return [CAMediaTimingFunction functionWithControlPoints:0.34f:1.45f:0.64f:1.0f];
}

// a line from 0 to width riding amplitude above and below the middle, the point count depends on the width
// alone so a wave and a flat line of one width morph into each other
static UIBezierPath *YZWaveLine(CGFloat width, CGFloat amplitude, CGFloat mid) {
    UIBezierPath *path = [UIBezierPath bezierPath];
    int count = (int)ceil(width / 3) + 1;
    for (int i = 0; i < count; ++i) {
        CGFloat x = width * i / (count - 1);
        CGPoint point = CGPointMake(x, mid + amplitude * sin(2 * M_PI * x / WAVE_PERIOD));
        if (i == 0)
            [path moveToPoint:point];
        else
            [path addLineToPoint:point];
    }
    return path;
}

@implementation YZWaveSeekBar

@synthesize value = _value;
@synthesize buffered = _buffered;
@synthesize waving = _waving;
@synthesize plain = _plain;
@synthesize dragging = _dragging;

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    self.backgroundColor = [UIColor clearColor];
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitAdjustable;
    _rest = [[CAShapeLayer alloc] init];
    _rest.fillColor = nil;
    _rest.strokeColor = [UIColor colorWithWhite:1 alpha:0.24f].CGColor;
    _rest.lineWidth = WAVE_LINE;
    _rest.lineCap = kCALineCapRound;
    _rest.anchorPoint = CGPointMake(0, 0.5f);
    [self.layer addSublayer:_rest];
    _buffer = [[CAShapeLayer alloc] init];
    _buffer.fillColor = nil;
    _buffer.strokeColor = [UIColor colorWithWhite:1 alpha:0.5f].CGColor;
    _buffer.lineWidth = WAVE_LINE;
    _buffer.lineCap = kCALineCapRound;
    _buffer.anchorPoint = CGPointMake(0, 0.5f);
    [self.layer addSublayer:_buffer];
    _clip = [[CALayer alloc] init];
    _clip.masksToBounds = YES;
    _clip.anchorPoint = CGPointMake(0, 0.5f);
    [self.layer addSublayer:_clip];
    _wave = [[CAShapeLayer alloc] init];
    _wave.fillColor = nil;
    _wave.lineWidth = WAVE_LINE;
    _wave.lineCap = kCALineCapRound;
    _wave.lineJoin = kCALineJoinRound;
    _wave.anchorPoint = CGPointMake(0, 0.5f);
    [_clip addSublayer:_wave];
    _thumb = [[CALayer alloc] init];
    _thumb.cornerRadius = 2;
    [self.layer addSublayer:_thumb];
    self.playedColor = [UIColor whiteColor];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_rest release];
    [_buffer release];
    [_clip release];
    [_wave release];
    [_thumb release];
    [super dealloc];
}

- (UIColor *)playedColor { return [UIColor colorWithCGColor:_wave.strokeColor]; }

- (void)setPlayedColor:(UIColor *)color {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _wave.strokeColor = color.CGColor;
    _thumb.backgroundColor = color.CGColor;
    [CATransaction commit];
}

- (UIColor *)restColor { return [UIColor colorWithCGColor:_rest.strokeColor]; }

- (void)setRestColor:(UIColor *)color {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _rest.strokeColor = color.CGColor;
    [CATransaction commit];
}

// the handle: a thin pill that thins further under a finger, or in the plain bar a circle that grows
- (CGSize)thumbSizeSqueezed:(BOOL)squeezed {
    if (_plain)
        return squeezed ? CGSizeMake(22, 22) : CGSizeMake(16, 16);
    return CGSizeMake(squeezed ? 2 : 4, THUMB_HEIGHT);
}

// the plain bar has no gap, the played line runs up to the handle
- (CGFloat)handleGap { return _plain ? 0 : WAVE_GAP; }

- (void)setPlain:(BOOL)plain {
    if (plain == _plain)
        return;
    _plain = plain;
    _waving = NO;
    [_wave removeAllAnimations];
    _thumb.cornerRadius = plain ? 8 : 2;
    _laidSize = CGSizeZero;
    [self setNeedsLayout];
}

- (CGFloat)trackWidth { return MAX((CGFloat)1, self.bounds.size.width - YZWaveSeekBarInset * 2); }

// a view that is off screen or a system that asks for reduced motion gets the wave standing still
- (BOOL)moving { return self.window != nil && [YZTheme animationsEnabled] && _laidSize.width > 0; }

- (UIBezierPath *)wavePath {
    return YZWaveLine([self trackWidth] + WAVE_PERIOD, _waving ? WAVE_AMPLITUDE : 0, YZWaveSeekBarHeight / 2);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    if (size.width < 1 || CGSizeEqualToSize(size, _laidSize))
        return;
    _laidSize = size;
    CGFloat mid = YZWaveSeekBarHeight / 2;
    CGFloat track = [self trackWidth];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    UIBezierPath *line = [UIBezierPath bezierPath];
    [line moveToPoint:CGPointMake(0, mid)];
    [line addLineToPoint:CGPointMake(track, mid)];
    for (CAShapeLayer *flat in [NSArray arrayWithObjects:_rest, _buffer, nil]) {
        flat.bounds = CGRectMake(0, 0, track, YZWaveSeekBarHeight);
        flat.position = CGPointMake(YZWaveSeekBarInset, mid);
        flat.path = line.CGPath;
    }
    _clip.position = CGPointMake(0, mid);
    _wave.bounds = CGRectMake(0, 0, track + WAVE_PERIOD, YZWaveSeekBarHeight);
    _wave.position = CGPointMake(YZWaveSeekBarInset, mid);
    _wave.path = [self wavePath].CGPath;
    _thumb.bounds = CGRectMake(0, 0, [self thumbSizeSqueezed:_dragging].width, [self thumbSizeSqueezed:_dragging].height);
    _thumb.cornerRadius = _plain ? [self thumbSizeSqueezed:_dragging].width / 2 : 2;
    [CATransaction commit];
    [self placeGliding:NO];
    [self syncMotion];
}

// the wave stops short of the handle and the plain lines start after it, with a gap on both sides
- (void)placeGliding:(BOOL)gliding {
    CGFloat track = [self trackWidth];
    CGFloat played = _value * track;
    CGFloat waveEnd = played - [self handleGap];
    CGFloat start = MIN((CGFloat)1, MAX((CGFloat)0, (played + [self handleGap]) / track));
    [CATransaction begin];
    if (gliding && [YZTheme animationsEnabled]) {
        [CATransaction setAnimationDuration:0.25];
        [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear]];
    } else {
        [CATransaction setDisableActions:YES];
    }
    _clip.bounds = CGRectMake(0, 0, waveEnd > 0 ? YZWaveSeekBarInset + waveEnd : 0, YZWaveSeekBarHeight);
    _rest.strokeStart = start;
    _buffer.strokeStart = start;
    _buffer.strokeEnd = MAX(start, MIN((CGFloat)1, (CGFloat)_buffered));
    _thumb.position = CGPointMake(YZWaveSeekBarInset + played, YZWaveSeekBarHeight / 2);
    [CATransaction commit];
}

- (void)setValue:(float)value gliding:(BOOL)gliding {
    value = !(value > 0) ? 0 : (value > 1 ? 1 : value);
    if (value == _value)
        return;
    _value = value;
    [self placeGliding:gliding && !_dragging];
}

- (void)setValue:(float)value { [self setValue:value gliding:NO]; }

- (void)setBuffered:(float)buffered {
    buffered = !(buffered > 0) ? 0 : (buffered > 1 ? 1 : buffered);
    if (buffered == _buffered)
        return;
    _buffered = buffered;
    [self placeGliding:NO];
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    self.alpha = enabled ? 1 : 0.4f;
}

- (NSString *)accessibilityValue { return [NSString stringWithFormat:@"%d%%", (int)(_value * 100 + 0.5f)]; }

- (void)stepBy:(float)step {
    [self setValue:_value + step gliding:NO];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
    [self sendActionsForControlEvents:UIControlEventTouchUpInside];
}

- (void)accessibilityIncrement { [self stepBy:0.05f]; }
- (void)accessibilityDecrement { [self stepBy:-0.05f]; }

#pragma mark wave motion

// backgrounding drops running animations, so they start again when the app is active
- (void)syncMotion {
    if (![self moving] || !_waving) {
        // a wave going flat keeps travelling until the morph ends, the flat line hides it and removing it
        // earlier would jump the crests
        if (![_wave animationForKey:YZWaveMorphKey] || ![self moving])
            [_wave removeAnimationForKey:YZWavePhaseKey];
        return;
    }
    if ([_wave animationForKey:YZWavePhaseKey])
        return;
    CABasicAnimation *travel = [CABasicAnimation animationWithKeyPath:@"position.x"];
    travel.fromValue = [NSNumber numberWithFloat:(float)(YZWaveSeekBarInset - WAVE_PERIOD)];
    travel.toValue = [NSNumber numberWithFloat:(float)YZWaveSeekBarInset];
    travel.duration = 1.3;
    travel.repeatCount = HUGE_VALF;
    travel.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    [_wave addAnimation:travel forKey:YZWavePhaseKey];
}

// the wave flattens into the line and rises again on the spring
- (void)setWaving:(BOOL)waving {
    if (_plain || waving == _waving)
        return;
    _waving = waving;
    if (_laidSize.width < 1)
        return;
    CAShapeLayer *shown = (CAShapeLayer *)[_wave presentationLayer];
    CGPathRef from = shown && shown.path ? shown.path : _wave.path;
    CGPathRetain(from);
    [_wave removeAnimationForKey:YZWaveMorphKey];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _wave.path = [self wavePath].CGPath;
    [CATransaction commit];
    if ([self moving] && from) {
        CABasicAnimation *morph = [CABasicAnimation animationWithKeyPath:@"path"];
        morph.fromValue = (id)from;
        morph.toValue = (id)_wave.path;
        morph.duration = 0.45;
        morph.timingFunction = YZWaveSpring();
        morph.delegate = (id)self;
        [_wave addAnimation:morph forKey:YZWaveMorphKey];
    }
    CGPathRelease(from);
    [self syncMotion];
}

- (void)animationDidStop:(CAAnimation *)animation finished:(BOOL)finished {
    (void)animation;
    if (finished && !_waving)
        [_wave removeAnimationForKey:YZWavePhaseKey];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    if (_observing)
        [center removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
    _observing = NO;
    if (self.window) {
        [center addObserver:self selector:@selector(syncMotion) name:UIApplicationDidBecomeActiveNotification object:nil];
        _observing = YES;
    }
    [self syncMotion];
}

#pragma mark touch

// the handle gets thinner under a finger and springs back wide
- (void)squeezeThumb:(BOOL)squeezed {
    [CATransaction begin];
    if (![YZTheme animationsEnabled]) {
        [CATransaction setDisableActions:YES];
    } else {
        [CATransaction setAnimationDuration:0.25];
        [CATransaction setAnimationTimingFunction:YZWaveSpring()];
    }
    CGSize size = [self thumbSizeSqueezed:squeezed];
    _thumb.bounds = CGRectMake(0, 0, size.width, size.height);
    if (_plain)
        _thumb.cornerRadius = size.width / 2;
    [CATransaction commit];
}

- (float)valueForTouch:(UITouch *)touch { return (float)(([touch locationInView:self].x - YZWaveSeekBarInset) / [self trackWidth]); }

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    (void)event;
    _dragging = YES;
    [self squeezeThumb:YES];
    [self setValue:[self valueForTouch:touch] gliding:NO];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    (void)event;
    [self setValue:[self valueForTouch:touch] gliding:NO];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
    return YES;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    (void)touch;
    (void)event;
    _dragging = NO;
    [self squeezeThumb:NO];
}

- (void)cancelTrackingWithEvent:(UIEvent *)event {
    (void)event;
    _dragging = NO;
    [self squeezeThumb:NO];
}

// the bar is 28 points tall, a finger needs 44
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    return CGRectContainsPoint(CGRectInset(self.bounds, -8, -MAX((CGFloat)0, (44 - self.bounds.size.height) / 2)), point);
}

@end
