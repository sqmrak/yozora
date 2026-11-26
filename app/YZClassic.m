#import "YZClassic.h"
#import "YZTheme.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static UIColor *YZHSB(CGFloat h, CGFloat s, CGFloat b) {
    return [UIColor colorWithHue:h saturation:MAX((CGFloat)0, MIN((CGFloat)1, s)) brightness:MAX((CGFloat)0, MIN((CGFloat)1, b)) alpha:1];
}

// hue, saturation and brightness of the accent of the palette in use, a bar is built from them
static void YZAccentHSB(CGFloat *h, CGFloat *s, CGFloat *b) {
    CGFloat alpha = 1;
    UIColor *accent = [YZTheme accentColor];
    // the private session wears the accent chosen for it as it is: the palette lightens it for text on a dark ground, which a bar should not be
    if ([YZSettings incognito]) {
        yozora_accent chosen = { YOZORA_PRIVATE_PALETTE_HUE, YOZORA_ACCENT_PALETTE_SATURATION, 1 };
        [YZSettings customPrivateAccent:&chosen];
        float r, g, blue;
        yozora_accent_rgb(&chosen, &r, &g, &blue);
        accent = [UIColor colorWithRed:r green:g blue:blue alpha:1];
    }
    if (![accent getHue:h saturation:s brightness:b alpha:&alpha]) {
        *h = 0.78f;
        *s = 0.6f;
        *b = 0.75f;
    }
}

// the light theme shows the accent as it is, the dark ones a deeper copy so the white ink keeps its contrast
static CGFloat YZBarDepth(void) {
    if ([YZSettings incognito])
        return 0.66f;
    if (![YZTheme isDark])
        return 1;
    return [YZSettings theme] == YZThemeBlack && ![YZSettings incognito] ? 0.4f : 0.55f;
}

// the tag of the toolbar that a lit view carries under its content
static const NSInteger YZLightTag = 90417;

// a button creates its image and its title when they are first set, after the lit toolbar was laid in it, and places them where it
// likes in the order of its views: on a key whose glyph is set after the toolbar the glyph could end up under it, a white mark on a
// pale key, which is no mark at all. a lit button puts the toolbar at the back and the size of the button at every layout
@interface YZLitButton : UIButton
@end
@implementation YZLitButton
- (void)layoutSubviews {
    [super layoutSubviews];
    UIView *bar = [self viewWithTag:YZLightTag];
    if (bar) {
        bar.frame = self.bounds;
        [self sendSubviewToBack:bar];
    }
}
@end

@implementation YZClassic

+ (UIColor *)barMidColor {
    CGFloat h, s, b;
    YZAccentHSB(&h, &s, &b);
    return YZHSB(h, s, b * YZBarDepth());
}

+ (UIColor *)inkColor { return [UIColor whiteColor]; }
+ (UIColor *)subtleInkColor { return [UIColor colorWithWhite:1 alpha:0.72f]; }
+ (UIColor *)stampColor { return [UIColor colorWithWhite:0 alpha:0.45f]; }

+ (UIImage *)stampedImage:(UIImage *)glyph {
    if (!glyph)
        return nil;
    CGSize size = glyph.size;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size.width, size.height + 1), NO, 0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    // the dark copy lies a point lower, the glyph is drawn over it in white
    CGContextSaveGState(context);
    CGContextSetShadowWithColor(context, CGSizeMake(0, -1), 0, [[self stampColor] CGColor]);
    [glyph drawAtPoint:CGPointMake(0, 0)];
    CGContextRestoreGState(context);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

+ (void)stampLabel:(UILabel *)label {
    label.shadowColor = [self stampColor];
    label.shadowOffset = CGSizeMake(0, -1);
}


// the toolbar of the system, tinted with the color, is the lit surface: ios 5 and 6 draw its gradient and its gloss, ios 7 the
// flat tint. it lies under the content of the view and takes no touches
+ (void)lightView:(UIView *)view color:(UIColor *)color radius:(CGFloat)radius {
    UIToolbar *bar = (UIToolbar *)[view viewWithTag:YZLightTag];
    if (!bar) {
        bar = [[[UIToolbar alloc] initWithFrame:view.bounds] autorelease];
        bar.tag = YZLightTag;
        bar.userInteractionEnabled = NO;
        bar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [view insertSubview:bar atIndex:0];
    }
    [view sendSubviewToBack:bar];
    // the class is changed in place: the subclass adds no variable and only places the toolbar
    if (object_getClass(view) == [UIButton class])
        object_setClass(view, [YZLitButton class]);
    bar.layer.cornerRadius = radius;
    bar.layer.masksToBounds = YES;
    // a lit chip does not change while it stands: it is drawn once and the render server composes the picture, which matters on a list of rows or on an ipad
    bar.layer.shouldRasterize = YES;
    bar.layer.rasterizationScale = [[UIScreen mainScreen] scale];
    if ([bar respondsToSelector:@selector(setBarTintColor:)]) {
        [bar setValue:color forKey:@"barTintColor"];
        bar.translucent = NO;
    } else {
        bar.tintColor = color;
    }
}

+ (void)unlightView:(UIView *)view {
    [[view viewWithTag:YZLightTag] removeFromSuperview];
}

+ (void)styleKey:(UIButton *)button color:(UIColor *)color radius:(CGFloat)radius modernRadius:(CGFloat)modernRadius {
    if ([YZTheme isClassic]) {
        button.backgroundColor = [UIColor clearColor];
        button.layer.cornerRadius = 0;
        [button setBackgroundImage:nil forState:UIControlStateNormal];
        [button setBackgroundImage:nil forState:UIControlStateHighlighted];
        [self lightView:button color:color radius:radius];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        button.titleLabel.shadowColor = [self stampColor];
        button.titleLabel.shadowOffset = CGSizeMake(0, -1);
        // the system glow of a pressed button
        button.showsTouchWhenHighlighted = YES;
        return;
    }
    [self unlightView:button];
    button.showsTouchWhenHighlighted = NO;
    [button setBackgroundImage:nil forState:UIControlStateNormal];
    [button setBackgroundImage:nil forState:UIControlStateHighlighted];
    button.backgroundColor = color;
    button.layer.cornerRadius = [YZTheme isFlat] ? MIN(modernRadius, (CGFloat)10) : modernRadius;
    button.titleLabel.shadowColor = nil;
}

+ (void)styleGlyphKey:(UIButton *)button icon:(YZIcon)icon size:(CGFloat)size modernRadius:(CGFloat)modernRadius {
    BOOL classic = [YZTheme isClassic];
    [self styleKey:button color:classic ? [self barMidColor] : [YZTheme stateColor] radius:9 modernRadius:modernRadius];
    UIImage *glyph = classic ? [self stampedImage:[YZTheme icon:icon size:size color:[UIColor whiteColor]]] : [YZTheme icon:icon size:size color:[YZTheme accentColor]];
    [button setImage:glyph forState:UIControlStateNormal];
    // the glyph stands over the lit surface
    if (button.imageView.superview == button)
        [button bringSubviewToFront:button.imageView];
    [button setNeedsLayout];
}

@end

@implementation YZGradientView
+ (Class)layerClass { return [CAGradientLayer class]; }

- (void)setTop:(UIColor *)top bottom:(UIColor *)bottom {
    CAGradientLayer *layer = (CAGradientLayer *)self.layer;
    layer.colors = [NSArray arrayWithObjects:(id)[top CGColor], (id)[bottom CGColor], nil];
    layer.startPoint = CGPointMake(0.5f, 0);
    layer.endPoint = CGPointMake(0.5f, 1);
}
@end

@implementation YZSystemBarView

@synthesize hairlineAtTop = _hairlineAtTop;

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat line = 1.0f / [[UIScreen mainScreen] scale];
    _hairline.frame = CGRectMake(0, _hairlineAtTop ? 0 : self.bounds.size.height - line, self.bounds.size.width, line);
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    _system = [[UIToolbar alloc] initWithFrame:self.bounds];
    _system.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // the toolbar is the picture of the bar, the buttons that stand on it are the app's
    _system.userInteractionEnabled = NO;
    [self insertSubview:_system atIndex:0];
    [self applyTheme];
    return self;
}

- (void)dealloc {
    [_system release];
    [_hairline release];
    [super dealloc];
}

- (void)applyTheme {
    BOOL classic = [YZTheme isClassic];
    _system.hidden = !classic;
    if (!_hairline) {
        _hairline = [[UIView alloc] initWithFrame:CGRectZero];
        [self addSubview:_hairline];
    }
    _hairline.hidden = ![YZTheme isFlat];
    _hairline.backgroundColor = [YZTheme separatorColor];
    [self setNeedsLayout];
    if (!classic) {
        // the modern bar is the flat color of the theme
        UIColor *flat = [YZTheme toolbarColor];
        [self setTop:flat bottom:flat];
        return;
    }
    UIColor *clear = [UIColor clearColor];
    [self setTop:clear bottom:clear];
    UIColor *tint = [YZClassic barMidColor];
    // ios 7 colors the bar through barTintColor and draws it translucent unless told otherwise, ios 5 and 6 tint the gradient
    if ([_system respondsToSelector:@selector(setBarTintColor:)]) {
        [_system setValue:tint forKey:@"barTintColor"];
        _system.translucent = NO;
    } else {
        _system.tintColor = tint;
    }
}
@end

@implementation YZWellView

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    _rim = [[CALayer alloc] init];
    _body = [[CAGradientLayer alloc] init];
    _gloss = [[CAGradientLayer alloc] init];
    for (CALayer *layer in [NSArray arrayWithObjects:_rim, _body, _gloss, nil])
        [self.layer addSublayer:layer];
    [self applyTheme];
    return self;
}

- (void)dealloc {
    [_rim release];
    [_body release];
    [_gloss release];
    [super dealloc];
}

- (void)applyTheme {
    BOOL classic = [YZTheme isClassic];
    _rim.hidden = !classic;
    _body.hidden = !classic;
    _gloss.hidden = !classic;
    self.backgroundColor = classic ? [UIColor clearColor] : [YZTheme addressFieldColor];
    if (!classic)
        return;
    BOOL dark = [YZTheme isDark];
    // metal: bright above, a hard edge at the middle where the gloss ends, a darker belly under it and a lighter foot
    CGFloat at[4] = { 0, 0.45f, 0.65f, 1 };
    NSArray *locations = [NSArray arrayWithObjects:[NSNumber numberWithFloat:at[0]], [NSNumber numberWithFloat:at[1]], [NSNumber numberWithFloat:at[2]], [NSNumber numberWithFloat:at[3]], nil];
    if (dark) {
        _body.colors = [NSArray arrayWithObjects:(id)[[UIColor colorWithWhite:0.30f alpha:1] CGColor], (id)[[UIColor colorWithWhite:0.17f alpha:1] CGColor],
                        (id)[[UIColor colorWithWhite:0.12f alpha:1] CGColor], (id)[[UIColor colorWithWhite:0.21f alpha:1] CGColor], nil];
        _gloss.colors = [NSArray arrayWithObjects:(id)[[UIColor colorWithWhite:1 alpha:0.30f] CGColor], (id)[[UIColor colorWithWhite:1 alpha:0.05f] CGColor], nil];
        _body.borderColor = [[UIColor colorWithWhite:0 alpha:0.85f] CGColor];
        _rim.backgroundColor = [[UIColor colorWithWhite:1 alpha:0.16f] CGColor];
    } else {
        // pale metal with a gentle fall: the belly under the gloss is only a little darker, so no band shows across the field
        _body.colors = [NSArray arrayWithObjects:(id)[[UIColor colorWithWhite:0.99f alpha:1] CGColor], (id)[[UIColor colorWithWhite:0.95f alpha:1] CGColor],
                        (id)[[UIColor colorWithWhite:0.92f alpha:1] CGColor], (id)[[UIColor colorWithWhite:0.96f alpha:1] CGColor], nil];
        _gloss.colors = [NSArray arrayWithObjects:(id)[[UIColor colorWithWhite:1 alpha:0.85f] CGColor], (id)[[UIColor colorWithWhite:1 alpha:0.12f] CGColor], nil];
        _body.borderColor = [[UIColor colorWithWhite:0 alpha:0.5f] CGColor];
        _rim.backgroundColor = [[UIColor colorWithWhite:1 alpha:0.6f] CGColor];
    }
    _body.locations = locations;
    _body.borderWidth = 1;
    for (CAGradientLayer *layer in [NSArray arrayWithObjects:_body, _gloss, nil]) {
        layer.startPoint = CGPointMake(0.5f, 0);
        layer.endPoint = CGPointMake(0.5f, 1);
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    CGFloat radius = bounds.size.height / 2;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // the light line under the pill is the same pill a point lower, seen only at its foot
    _rim.frame = CGRectOffset(bounds, 0, 1);
    _rim.cornerRadius = radius;
    _body.frame = bounds;
    _body.cornerRadius = radius;
    // the gloss covers the upper half inside the outline and ends in the same round
    CGRect upper = CGRectMake(1, 1, MAX((CGFloat)0, bounds.size.width - 2), floor(bounds.size.height / 2));
    _gloss.frame = upper;
    _gloss.cornerRadius = MIN(radius - 1, upper.size.height);
    [CATransaction commit];
}
@end

@implementation YZPlateView
@synthesize surfaceInModern = _surface;
@synthesize sheetCornersInModern = _sheetCorners;

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    // the gloss is a layer over the toolbar of the system and under whatever is added to the plate later
    _shine = [[CAGradientLayer alloc] init];
    _shine.startPoint = CGPointMake(0.5f, 0);
    _shine.endPoint = CGPointMake(0.5f, 1);
    _shineMask = [[CAShapeLayer alloc] init];
    _shine.mask = _shineMask;
    [self.layer addSublayer:_shine];
    [self applyTheme];
    return self;
}

- (void)dealloc {
    [_shine release];
    [_shineMask release];
    [super dealloc];
}

- (void)applyTheme {
    CALayer *layer = self.layer;
    if (![YZTheme isClassic]) {
        [YZClassic unlightView:self];
        _shine.hidden = YES;
        UIColor *flat = _surface ? [YZTheme surfaceColor] : [YZTheme cardColor];
        [self setTop:flat bottom:flat];
        layer.cornerRadius = _sheetCorners ? [YZTheme sheetRadius] : [YZTheme cardRadius];
        layer.borderWidth = 0;
        return;
    }
    BOOL dark = [YZTheme isDark];
    // pale glass on the light themes, charcoal on the dark ones: a toolbar of the system tinted that way, with its outline
    [self setTop:[UIColor clearColor] bottom:[UIColor clearColor]];
    [YZClassic lightView:self color:dark ? [UIColor colorWithWhite:0.22f alpha:1] : [UIColor colorWithWhite:0.92f alpha:1] radius:[YZTheme cardRadius]];
    layer.cornerRadius = [YZTheme cardRadius];
    layer.borderWidth = 1;
    layer.borderColor = [(dark ? [UIColor colorWithWhite:0 alpha:0.8f] : [UIColor colorWithWhite:0 alpha:0.4f]) CGColor];
    _shine.hidden = NO;
    // the light fades out in steps, so the gloss has no edge where it ends: strong at the top, nothing at the lower end of its field
    CGFloat peak = dark ? 0.22f : 0.6f;
    _shine.colors = [NSArray arrayWithObjects:(id)[[UIColor colorWithWhite:1 alpha:peak] CGColor], (id)[[UIColor colorWithWhite:1 alpha:peak * 0.55f] CGColor],
                     (id)[[UIColor colorWithWhite:1 alpha:peak * 0.2f] CGColor], (id)[[UIColor colorWithWhite:1 alpha:peak * 0.05f] CGColor],
                     (id)[[UIColor colorWithWhite:1 alpha:0] CGColor], nil];
    _shine.locations = [NSArray arrayWithObjects:[NSNumber numberWithFloat:0], [NSNumber numberWithFloat:0.3f], [NSNumber numberWithFloat:0.6f],
                        [NSNumber numberWithFloat:0.85f], [NSNumber numberWithFloat:1], nil];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (![YZTheme isClassic])
        return;
    CGRect bounds = self.bounds;
    CGFloat radius = [YZTheme cardRadius];
    CGRect upper = CGRectMake(1, 1, MAX((CGFloat)0, bounds.size.width - 2), MAX((CGFloat)0, floor(MIN(bounds.size.height * 0.62f, (CGFloat)84)) - 1));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _shine.frame = upper;
    // the gloss follows the round corners of the plate at the top and ends flat at the middle
    _shineMask.frame = _shine.bounds;
    _shineMask.path = [UIBezierPath bezierPathWithRoundedRect:_shine.bounds byRoundingCorners:UIRectCornerTopLeft | UIRectCornerTopRight cornerRadii:CGSizeMake(MAX((CGFloat)0, radius - 1), MAX((CGFloat)0, radius - 1))].CGPath;
    [CATransaction commit];
}
@end
