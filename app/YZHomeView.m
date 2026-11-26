#import "YZHomeView.h"
#import "YZClassic.h"
#import "YZCompat.h"
#import "YZBackground.h"
#import "YZFavicons.h"
#import "YZMotion.h"
#import "YZStrings.h"
#import <QuartzCore/QuartzCore.h>
#import "YZStore.h"
#import "YZTheme.h"
#include "yozora_address.h"
#include "yozora_home.h"

static const NSUInteger YZTilesPerSection = 8;
// the sites a person added are kept, so the favorites hold more than the visited ones
static const NSUInteger YZFavoritesMax = 20;
static const CGFloat YZTileSize = 60;
static const CGFloat YZTileLabelHeight = 32;
// the caption takes the cell minus a gap, so a title wraps at words and not inside one
static const CGFloat YZTileCell = 84;
static const CGFloat YZTileSide = 16;

@interface YZTileButton : UIButton {
@public
    // the square under the letter or the icon: the classic design lights it, the label under it stays on the page
    UIView *square;
    UILabel *letter;
    UIImageView *icon;
    UILabel *caption;
    // the last tile of the favorites: it adds a site and has no address
    BOOL isPlus;
@private
    NSString *_target;
}
@property(nonatomic, copy) NSString *target;
@end
@implementation YZTileButton
@synthesize target = _target;
- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    square = [[UIView alloc] initWithFrame:CGRectMake(0, 0, YZTileSize, YZTileSize)];
    square.userInteractionEnabled = NO;
    [self addSubview:square];
    letter = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, YZTileSize, YZTileSize)];
    letter.textAlignment = YZTextAlignmentCenter;
    letter.font = [YZTheme boldSystemFontOfSize:28];
    letter.textColor = [UIColor whiteColor];
    letter.layer.cornerRadius = [YZTheme tileRadius];
    // a label fills its whole rectangle with its background, so the white icon tile showed square corners
    // outside the rounded edge
    letter.layer.masksToBounds = YES;
    letter.userInteractionEnabled = NO;
    [self addSubview:letter];
    // the icon of the site stands on a white tile, the way the shortcuts of Firefox do
    icon = [[UIImageView alloc] initWithFrame:CGRectMake(10, 10, YZTileSize - 20, YZTileSize - 20)];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    // a picture of 128 pixels is shown at 40 points with the best filter the system has
    icon.layer.minificationFilter = kCAFilterTrilinear;
    icon.userInteractionEnabled = NO;
    [self addSubview:icon];
    caption = [[UILabel alloc] initWithFrame:CGRectMake((YZTileSize - (YZTileCell - 6)) / 2, YZTileSize + 4, YZTileCell - 6, YZTileLabelHeight - 4)];
    caption.numberOfLines = 2;
    caption.lineBreakMode = YZLineBreakTailTruncation;
    caption.textAlignment = YZTextAlignmentCenter;
    caption.font = [YZTheme systemFontOfSize:11];
    caption.backgroundColor = [UIColor clearColor];
    caption.userInteractionEnabled = NO;
    [self addSubview:caption];
    return self;
}
- (void)setHighlighted:(BOOL)highlighted {
    BOOL pressed = highlighted && !self.highlighted;
    [super setHighlighted:highlighted];
    if (pressed)
        [YZTheme animateFeedbackOfView:self];
}
- (void)dealloc {
    [square release];
    [letter release];
    [icon release];
    [caption release];
    [_target release];
    [super dealloc];
}
@end

@implementation YZHomeView
@synthesize homeDelegate = _homeDelegate;
@synthesize topEdgeColor = _topEdgeColor, bottomEdgeColor = _bottomEdgeColor;

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    // the ground (the surface, the gradient or the photo) is a view of its own that the browser lays under the page and the bars, the
    // tiles scroll over it and it stays where the screen is
    self.backgroundColor = [UIColor clearColor];
    _ground = [[UIView alloc] initWithFrame:CGRectZero];
    _ground.userInteractionEnabled = NO;
    _contentDirty = YES;
    self.alwaysBounceVertical = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(iconLoaded:) name:YZFaviconDidLoadNotification object:nil];
    _siteTiles = [[NSMutableArray alloc] init];
    _bookmarkTiles = [[NSMutableArray alloc] init];
    _bookmarksHeading = [[UILabel alloc] initWithFrame:CGRectZero];
    _bookmarksHeading.font = [YZTheme boldSystemFontOfSize:15];
    _bookmarksHeading.textAlignment = YZTextAlignmentCenter;
    _bookmarksHeading.backgroundColor = [UIColor clearColor];
    [self addSubview:_bookmarksHeading];
    // any place of the page opens the menu of the page: the photo, the order of the blocks, a new site
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(holdRecognized:)];
    hold.minimumPressDuration = 0.45;
    [self addGestureRecognizer:hold];
    [hold release];
    // the photo or the gradient is stored, so a new page shows it at once and not only after the next change of the theme
    [self applyBackdrop];
    return self;
}

// the tile of a site under the point and the section it belongs to, the plus tile is not one
- (YZTileButton *)tileAtPoint:(CGPoint)point tiles:(NSMutableArray **)section {
    NSMutableArray *sections[2] = { _siteTiles, _bookmarkTiles };
    for (int s = 0; s < 2; ++s) {
        for (YZTileButton *tile in sections[s]) {
            if (!tile.hidden && !tile->isPlus && tile.target && CGRectContainsPoint(tile.frame, point)) {
                *section = sections[s];
                return tile;
            }
        }
    }
    return nil;
}

// the menu belongs to the page that is not a model and not the private note. the point is in the coordinates of the view that holds the page,
// where the menu grows from it. a held tile is lifted and can be dragged to another place of its section, one let go where it was hands its
// address to the menu so the menu can offer to take it off the page
- (void)holdRecognized:(UILongPressGestureRecognizer *)hold {
    if ([YZTheme isIncognito] || !self.superview) {
        [self dropTileCommitting:NO];
        return;
    }
    CGPoint inside = [hold locationInView:self];
    switch (hold.state) {
    case UIGestureRecognizerStateBegan: {
        NSMutableArray *section = nil;
        YZTileButton *tile = [self tileAtPoint:inside tiles:&section];
        if (tile)
            [self liftTile:tile tiles:section at:inside];
        else
            [_homeDelegate homeView:self didHoldAt:[hold locationInView:self.superview] siteURL:nil favorite:NO];
        break;
    }
    case UIGestureRecognizerStateChanged:
        [self dragTileTo:inside];
        break;
    case UIGestureRecognizerStateEnded: {
        if (!_dragTile)
            break;
        if (_dragMoved) {
            [self dropTileCommitting:YES];
            break;
        }
        NSString *url = [[((YZTileButton *)_dragTile).target copy] autorelease];
        BOOL favorite = _dragTiles == _bookmarkTiles;
        [self dropTileCommitting:NO];
        [_homeDelegate homeView:self didHoldAt:[hold locationInView:self.superview] siteURL:url favorite:favorite];
        break;
    }
    default:
        [self dropTileCommitting:NO];
        break;
    }
}

// the frame of the place index of a section of total tiles whose first row begins at top. every row stands in the middle on its own
- (CGRect)frameOfSlot:(NSUInteger)index total:(NSUInteger)total top:(CGFloat)top {
    CGFloat width = self.bounds.size.width;
    NSUInteger perRow = MAX((NSUInteger)3, (NSUInteger)((width - 2 * YZTileSide) / YZTileCell));
    NSUInteger columns = MAX((NSUInteger)1, MIN(perRow, total));
    NSUInteger row = index / columns;
    NSUInteger inRow = MIN(columns, total - row * columns);
    CGFloat rowLeft = floor((width - inRow * YZTileCell) / 2);
    return CGRectMake(rowLeft + (index % columns) * YZTileCell + (YZTileCell - YZTileSize) / 2, top + row * (YZTileSize + YZTileLabelHeight + 8),
                      YZTileSize, YZTileSize + YZTileLabelHeight);
}

- (CGPoint)centerOfSlot:(NSUInteger)index {
    CGRect frame = [self frameOfSlot:index total:[_dragOrder count] top:_dragTiles == _siteTiles ? _siteTop : _bookmarkTop];
    return CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
}

- (void)liftTile:(YZTileButton *)tile tiles:(NSMutableArray *)section at:(CGPoint)point {
    [self dropTileCommitting:NO];
    _dragTile = [tile retain];
    _dragTiles = section;
    _dragOrder = [[NSMutableArray alloc] initWithArray:section];
    _dragLead = section == _siteTiles && [section count] && ((YZTileButton *)[section objectAtIndex:0])->isPlus ? 1 : 0;
    _dragGrab = CGPointMake(point.x - tile.center.x, point.y - tile.center.y);
    _dragStart = point;
    _dragMoved = NO;
    // the page would scroll under a finger that drags the tile
    self.scrollEnabled = NO;
    [self bringSubviewToFront:tile];
    tile.layer.shadowColor = [[UIColor blackColor] CGColor];
    tile.layer.shadowOffset = CGSizeMake(0, 6);
    tile.layer.shadowRadius = 10;
    [UIView animateWithDuration:[YZTheme animationsEnabled] ? 0.18 : 0 animations:^{
        tile.transform = CGAffineTransformMakeScale(1.12f, 1.12f);
        tile.alpha = 0.94f;
    }];
    tile.layer.shadowOpacity = 0.3f;
}

// the tile follows the finger, the nearest place of its section takes it and the tiles between slide over by one
- (void)dragTileTo:(CGPoint)point {
    if (!_dragTile)
        return;
    _dragTile.center = CGPointMake(point.x - _dragGrab.x, point.y - _dragGrab.y);
    if (!_dragMoved && hypot(point.x - _dragStart.x, point.y - _dragStart.y) < 10)
        return;
    _dragMoved = YES;
    NSUInteger from = [_dragOrder indexOfObjectIdenticalTo:_dragTile], to = from;
    CGFloat nearest = CGFLOAT_MAX;
    for (NSUInteger i = _dragLead; i < [_dragOrder count]; ++i) {
        CGPoint slot = [self centerOfSlot:i];
        CGFloat distance = hypot(slot.x - _dragTile.center.x, slot.y - _dragTile.center.y);
        if (distance < nearest) {
            nearest = distance;
            to = i;
        }
    }
    if (from == NSNotFound || to == from)
        return;
    [_dragTile retain];
    [_dragOrder removeObjectAtIndex:from];
    [_dragOrder insertObject:_dragTile atIndex:to];
    [_dragTile release];
    [UIView animateWithDuration:[YZTheme animationsEnabled] ? 0.22 : 0 delay:0
                        options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState animations:^{
        for (NSUInteger i = 0; i < [_dragOrder count]; ++i) {
            UIView *tile = [_dragOrder objectAtIndex:i];
            if (tile != _dragTile)
                tile.center = [self centerOfSlot:i];
        }
    } completion:nil];
}

// the tile settles into its place. committing stores the new order of the section, otherwise the section goes back to how it stood
- (void)dropTileCommitting:(BOOL)commit {
    if (!_dragTile)
        return;
    UIButton *tile = [_dragTile autorelease];
    _dragTile = nil;
    self.scrollEnabled = YES;
    NSMutableArray *order = [_dragOrder autorelease];
    _dragOrder = nil;
    if (!commit)
        order = [NSMutableArray arrayWithArray:_dragTiles];
    NSUInteger total = [order count];
    CGFloat top = _dragTiles == _siteTiles ? _siteTop : _bookmarkTop;
    [UIView animateWithDuration:[YZTheme animationsEnabled] ? 0.22 : 0 delay:0
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState animations:^{
        tile.transform = CGAffineTransformIdentity;
        tile.alpha = 1;
        for (NSUInteger i = 0; i < total; ++i)
            ((UIView *)[order objectAtIndex:i]).frame = [self frameOfSlot:i total:total top:top];
    } completion:nil];
    tile.layer.shadowOpacity = 0;
    // an icon that arrived during the drag waited for the layout the drag held back
    [self setNeedsLayout];
    if (!commit)
        return;
    NSMutableArray *urls = [NSMutableArray array];
    for (YZTileButton *placed in order) {
        if (!placed->isPlus && placed.target)
            [urls addObject:placed.target];
    }
    // the tiles keep their records: the section is stored in the order the tiles now stand, and the next layout fills them in that order
    [_dragTiles setArray:order];
    if (_dragTiles == _bookmarkTiles)
        [YZSettings setHomeFavoriteOrder:urls];
    else
        [YZSettings setHomeSiteOrder:urls];
    _contentDirty = YES;
    _builtWidth = 0;
    [self setNeedsLayout];
}

// the records of a section in the order to show them: the ones placed by hand first, then the rest, none of the hidden ones
static NSArray *YZArrangedRecords(NSArray *records, NSArray *placed, NSArray *hidden) {
    NSUInteger count = MIN([records count], (NSUInteger)256);
    NSUInteger placedCount = MIN([placed count], (NSUInteger)YOZORA_HOME_LIST_MAX), hiddenCount = MIN([hidden count], (NSUInteger)YOZORA_HOME_LIST_MAX);
    if (!count)
        return records;
    const char *items[256], *placedItems[YOZORA_HOME_LIST_MAX], *hiddenItems[YOZORA_HOME_LIST_MAX];
    size_t indices[256];
    for (NSUInteger i = 0; i < count; ++i)
        items[i] = [((YZRecord *)[records objectAtIndex:i]).url UTF8String];
    for (NSUInteger i = 0; i < placedCount; ++i)
        placedItems[i] = [[placed objectAtIndex:i] UTF8String];
    for (NSUInteger i = 0; i < hiddenCount; ++i)
        hiddenItems[i] = [[hidden objectAtIndex:i] UTF8String];
    size_t shown = yozora_home_arrange(items, count, placedItems, placedCount, hiddenItems, hiddenCount, indices, count);
    NSMutableArray *arranged = [NSMutableArray arrayWithCapacity:shown];
    for (size_t i = 0; i < shown; ++i)
        [arranged addObject:[records objectAtIndex:indices[i]]];
    return arranged;
}

// the blocks stand in a new order or the favorites changed: tiles and logo slide to their new places
- (void)relayoutAnimated {
    _contentDirty = YES;
    _builtWidth = 0;
    [self setNeedsLayout];
    if (!self.window || ![YZTheme animationsEnabled]) {
        [self layoutIfNeeded];
        return;
    }
    [UIView animateWithDuration:0.32 delay:0 options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ [self layoutIfNeeded]; } completion:nil];
}

// the tiles are filled again, the one that waited for its icon takes it
- (void)iconLoaded:(NSNotification *)note {
    (void)note;
    _contentDirty = YES;
    _builtWidth = 0;
    [self setNeedsLayout];
}

// the lettering follows the photo: gray on a light one is hard to read. light above this lightness
static const CGFloat YZLightPhoto = 0.55f;

- (UIColor *)headingInk {
    if (_photoInk == 1)
        return [UIColor colorWithWhite:0.08f alpha:1];
    return _photoInk == 2 ? [UIColor colorWithWhite:0.98f alpha:1] : [YZTheme textColor];
}

- (UIColor *)captionInk {
    if (_photoInk == 1)
        return [UIColor colorWithWhite:0.2f alpha:1];
    return _photoInk == 2 ? [UIColor colorWithWhite:0.9f alpha:1] : [YZTheme subtleTextColor];
}

// the tiles and headings take their colors again when the kind of photo changes
- (void)adaptInkToPicture:(UIImage *)picture {
    int ink = picture ? ([YZBackground lightnessOfImage:picture] > YZLightPhoto ? 1 : 2) : 0;
    if (ink == _photoInk)
        return;
    _photoInk = ink;
    _contentDirty = YES;
    _builtWidth = 0;
    [self setNeedsLayout];
}

// a share of the accent laid over the surface, so the gradient keeps the lightness the lettering of the theme was made for
static UIColor *YZMixedColor(UIColor *surface, UIColor *accent, CGFloat share) {
    CGFloat s[4], a[4];
    if (![surface getRed:&s[0] green:&s[1] blue:&s[2] alpha:&s[3]] || ![accent getRed:&a[0] green:&a[1] blue:&a[2] alpha:&a[3]])
        return surface;
    return [UIColor colorWithRed:s[0] + (a[0] - s[0]) * share green:s[1] + (a[1] - s[1]) * share blue:s[2] + (a[2] - s[2]) * share alpha:1];
}

static const CGFloat YZGradientMiddle = 0.45f;
static const CGPoint YZGradientEnd = { 0.7f, 1 };

// a tint of the accent at the top left, a weaker one in the middle, the plain surface at the end
static void YZGradientStops(UIColor *stops[3]) {
    UIColor *surface = [YZTheme surfaceColor], *accent = [YZTheme accentColor];
    CGFloat strength = [YZTheme isDark] ? 0.34f : 0.42f;
    stops[0] = YZMixedColor(surface, accent, strength);
    stops[1] = YZMixedColor(surface, accent, strength * 0.4f);
    stops[2] = surface;
}

// the gradient stands behind the page of the modern design that has no photo, from a tint of the accent at the top left to the plain surface
- (void)applyGradient:(BOOL)shown {
    if (!shown) {
        _gradient.hidden = YES;
        return;
    }
    if (!_gradient) {
        _gradient = [[YZGradientView alloc] initWithFrame:_ground.bounds];
        _gradient.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _gradient.userInteractionEnabled = NO;
        [_ground insertSubview:_gradient atIndex:0];
    }
    _gradient.hidden = NO;
    UIColor *stops[3];
    YZGradientStops(stops);
    CAGradientLayer *layer = (CAGradientLayer *)_gradient.layer;
    layer.colors = [NSArray arrayWithObjects:(id)[stops[0] CGColor], (id)[stops[1] CGColor], (id)[stops[2] CGColor], nil];
    layer.locations = [NSArray arrayWithObjects:[NSNumber numberWithFloat:0], [NSNumber numberWithFloat:YZGradientMiddle], [NSNumber numberWithFloat:1], nil];
    layer.startPoint = CGPointZero;
    layer.endPoint = YZGradientEnd;
}

// the color of the gradient at a point of the ground: its place along the axis from the top left to the end point, in points, as the layer
// draws it on a ground that is not square
- (UIColor *)gradientColorAt:(CGPoint)point {
    UIColor *stops[3];
    YZGradientStops(stops);
    CGSize size = _ground.bounds.size;
    CGFloat ax = YZGradientEnd.x * size.width, ay = YZGradientEnd.y * size.height, length = ax * ax + ay * ay;
    CGFloat t = length > 0 ? MIN((CGFloat)1, MAX((CGFloat)0, (point.x * ax + point.y * ay) / length)) : 0;
    if (t <= YZGradientMiddle)
        return YZMixedColor(stops[0], stops[1], t / YZGradientMiddle);
    return YZMixedColor(stops[1], stops[2], (t - YZGradientMiddle) / (1 - YZGradientMiddle));
}

// the mean color of the top and the bottom rows of the part of the photo that the page shows (it fills the page and is cut at the sides
// or at the ends), from a copy of 8 by 24 pixels
static BOOL YZPhotoEdgeColors(UIImage *picture, CGSize view, UIColor **top, UIColor **bottom) {
    CGImageRef image = picture.CGImage;
    if (!image || view.width < 1 || view.height < 1)
        return NO;
    CGFloat iw = CGImageGetWidth(image), ih = CGImageGetHeight(image);
    if (iw < 1 || ih < 1)
        return NO;
    CGFloat vx = 0, vy = 0, vw = iw, vh = ih;
    if (iw / ih > view.width / view.height) {
        vw = ih * view.width / view.height;
        vx = (iw - vw) / 2;
    } else {
        vh = iw * view.height / view.width;
        vy = (ih - vh) / 2;
    }
    enum { columns = 8, rows = 24 };
    uint8_t pixels[columns * rows * 4];
    memset(pixels, 0, sizeof pixels);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, columns, rows, 8, columns * 4, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context)
        return NO;
    CGFloat sx = columns / vw, sy = rows / vh;
    // the context counts from the bottom, the first row in memory is the top of the copy
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextDrawImage(context, CGRectMake(-vx * sx, -(ih - vy - vh) * sy, iw * sx, ih * sy), image);
    CGContextRelease(context);
    for (int edge = 0; edge < 2; ++edge) {
        const uint8_t *row = pixels + (edge ? rows - 1 : 0) * columns * 4;
        unsigned sum[3] = { 0, 0, 0 };
        for (int x = 0; x < columns; ++x)
            for (int c = 0; c < 3; ++c)
                sum[c] += row[x * 4 + c];
        UIColor *color = [UIColor colorWithRed:sum[0] / (255.0f * columns) green:sum[1] / (255.0f * columns) blue:sum[2] / (255.0f * columns) alpha:1];
        if (edge)
            *bottom = color;
        else
            *top = color;
    }
    return YES;
}

// taken again when the ground or its size changes, the browser reads them on every frame for the clock of the status bar
- (void)updateEdgeColors {
    CGSize size = _ground.bounds.size;
    _edgeSize = size;
    UIColor *top = _ground.backgroundColor, *bottom = _ground.backgroundColor;
    if (_backdrop && !_backdrop.hidden && _backdrop.image) {
        if (!YZPhotoEdgeColors(_backdrop.image, size, &top, &bottom))
            NSLog(@"yozora: the edges of the start page photo could not be read");
    } else if (_gradient && !_gradient.hidden) {
        top = [self gradientColorAt:CGPointMake(size.width / 2, 0)];
        bottom = [self gradientColorAt:CGPointMake(size.width / 2, size.height)];
    }
    [top retain];
    [_topEdgeColor release];
    _topEdgeColor = top;
    [bottom retain];
    [_bottomEdgeColor release];
    _bottomEdgeColor = bottom;
}

- (BOOL)wantsGradient {
    return [YZSettings homeGradient] && ![YZTheme isClassic] && ![YZTheme isFlat] && ![YZTheme isIncognito];
}

- (UIView *)groundView {
    return _ground;
}

// the ground follows the frame the browser gives it, the colors at its edges follow its size
- (void)groundResized {
    if (!CGSizeEqualToSize(_edgeSize, _ground.bounds.size))
        [self updateEdgeColors];
}

// the private session keeps the plain surface: its note is set for it
- (void)applyBackdrop {
    _ground.backgroundColor = [YZTheme isClassic] ? [YZTheme linenColor] : [YZTheme surfaceColor];
    UIImage *picture = [YZTheme isIncognito] ? nil : [YZBackground image];
    [self applyGradient:!picture && [self wantsGradient]];
    if (!picture) {
        _backdrop.hidden = YES;
        _backdrop.image = nil;
        [self adaptInkToPicture:nil];
        [self updateEdgeColors];
        return;
    }
    if (!_backdrop) {
        _backdrop = [[UIImageView alloc] initWithFrame:_ground.bounds];
        _backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _backdrop.contentMode = UIViewContentModeScaleAspectFill;
        _backdrop.clipsToBounds = YES;
        _backdrop.userInteractionEnabled = NO;
        [_ground insertSubview:_backdrop atIndex:0];
    }
    _backdrop.hidden = NO;
    _backdrop.image = picture;
    [self adaptInkToPicture:picture];
    [self updateEdgeColors];
}

- (void)applyTheme {
    [self applyBackdrop];
    // the mascot is a setting like the theme, and the picture is only made when the brand is first laid out
    _brandImage.image = [YZTheme mascotImage:@"hero"];
    _contentDirty = YES;
    _builtWidth = 0;
    [self setNeedsLayout];
}

- (void)showSites:(NSArray *)sites bookmarks:(NSArray *)bookmarks {
    [sites retain];
    [_sites release];
    _sites = sites;
    [bookmarks retain];
    [_bookmarks release];
    _bookmarks = bookmarks;
    _contentDirty = YES;
    _builtWidth = 0;
    [self setNeedsLayout];
}

- (void)animateContents {
    [self layoutIfNeeded];
    NSUInteger animated = 0;
    for (UIView *tile in self.subviews) {
        if (![tile isKindOfClass:[YZTileButton class]] || tile.hidden || !CGRectIntersectsRect(tile.frame, self.bounds))
            continue;
        // the tiles settle on the wobble curve, passing their place a little
        YZMotionAnimateEnter(tile, CGAffineTransformConcat(CGAffineTransformMakeScale(0.8f, 0.8f), CGAffineTransformMakeTranslation(0, 14)), 0,
                             YOZORA_MOTION_WOBBLE, MIN((NSTimeInterval)0.16, animated * 0.025));
        if (++animated == 8)
            break;
    }
    if (!_brandImage.hidden && _brandImage) {
        YZMotionAnimateEnter(_brandImage, CGAffineTransformMakeScale(0.6f, 0.6f), 0, YOZORA_MOTION_WOBBLE, 0);
        YZMotionAnimateEnter(_brandGlow, CGAffineTransformMakeScale(0.6f, 0.6f), 0, YOZORA_MOTION_WOBBLE, 0);
        [YZTheme animateEntranceOfView:_brandName offset:CGPointMake(0, 10) delay:0.05];
    }
    if (!_heroDisc.hidden) {
        YZMotionAnimateEnter(_heroDisc, CGAffineTransformMakeScale(0.5f, 0.5f), 0, YOZORA_MOTION_WOBBLE, 0);
        YZMotionAnimateEnter(_heroIcon, CGAffineTransformMakeScale(0.4f, 0.4f), 0, YOZORA_MOTION_WOBBLE, 0.06);
        [YZTheme animateEntranceOfView:_heroTitle offset:CGPointMake(0, 16) delay:0.04];
        [YZTheme animateEntranceOfView:_heroText offset:CGPointMake(0, 16) delay:0.08];
    }
}

- (void)tilePressed:(YZTileButton *)button {
    if (button->isPlus)
        [_homeDelegate homeViewDidTapAdd:self];
    else if (button.target)
        [_homeDelegate homeView:self didSelectURL:button.target];
}

- (void)updateTile:(YZTileButton *)tile record:(YZRecord *)record {
    char host[256];
    NSString *name = record.url;
    if (yozora_address_host([record.url UTF8String], host, sizeof host))
        name = [NSString stringWithUTF8String:host];
    tile.target = record.url;
    tile->isPlus = NO;
    tile.accessibilityLabel = nil;
    UIImage *icon = [YZFavicons iconForURL:record.url];
    tile->icon.image = icon;
    tile->icon.hidden = !icon;
    [self shapeIconOfTile:tile];
    tile->letter.text = icon ? nil : [[name substringToIndex:MIN((NSUInteger)1, [name length])] uppercaseString];
    UIColor *tileColor = icon ? [YZFavicons tileColorForIcon:icon] : [YZTheme tileColorForHost:name];
    [self paintTile:tile color:tileColor outlined:icon != nil];
    tile->caption.text = [record.title length] ? record.title : name;
    tile->caption.textColor = [self captionInk];
}

// a square home screen picture fills the tile with the corners of the plate, a glyph keeps room around it and a small favicon about its
// own size, so no picture is enlarged to a blur
- (void)shapeIconOfTile:(YZTileButton *)tile {
    UIImage *image = tile->icon.image;
    CALayer *layer = tile->icon.layer;
    YZIconShape shape = image ? [YZFavicons shapeOfIcon:image] : YZIconShapeGlyph;
    if (shape == YZIconShapeFull) {
        tile->icon.frame = CGRectMake(0, 0, YZTileSize, YZTileSize);
        tile->icon.contentMode = UIViewContentModeScaleAspectFill;
        layer.cornerRadius = [YZTheme tileRadius];
        layer.masksToBounds = YES;
        return;
    }
    CGFloat side = YZTileSize - 20;
    if (shape == YZIconShapeSmall) {
        // 1.5 points for each pixel at most: a 16 pixel favicon is 24 points, a 32 pixel one 40
        side = MIN(side, MAX((CGFloat)24, MIN(image.size.width, image.size.height) * image.scale * 1.25f));
    }
    tile->icon.frame = CGRectMake((YZTileSize - side) / 2, (YZTileSize - side) / 2, side, side);
    tile->icon.contentMode = UIViewContentModeScaleAspectFit;
    layer.cornerRadius = 0;
    layer.masksToBounds = NO;
}

// the plate under the letter or the icon, in the look of the design
- (void)paintTile:(YZTileButton *)tile color:(UIColor *)tileColor outlined:(BOOL)outlined {
    BOOL classic = [YZTheme isClassic];
    tile->letter.layer.cornerRadius = [YZTheme tileRadius];
    if (classic) {
        // the tile is lit like an icon of the old home screen: a toolbar of the system tinted with the color lies under the letter or the icon
        tile->letter.backgroundColor = [UIColor clearColor];
        tile->letter.layer.borderWidth = 0;
        [YZClassic lightView:tile->square color:tileColor radius:[YZTheme tileRadius]];
        tile->square.layer.borderWidth = 1;
        tile->square.layer.borderColor = [[UIColor colorWithWhite:0 alpha:0.4f] CGColor];
        tile->square.layer.cornerRadius = [YZTheme tileRadius];
    } else {
        [YZClassic unlightView:tile->square];
        tile->square.layer.borderWidth = 0;
        tile->letter.backgroundColor = tileColor;
        tile->letter.layer.borderWidth = outlined ? 1 : 0;
        tile->letter.layer.borderColor = [[YZTheme separatorColor] CGColor];
    }
}

// the key that adds a site: a plus in the accent on a tonal plate, the caption says what it does
- (void)updatePlusTile:(YZTileButton *)tile {
    tile.target = nil;
    tile->isPlus = YES;
    tile.accessibilityLabel = YZT(@"Добавить веб-сайт");
    tile->icon.image = [YZTheme icon:YZIconPlus size:28 color:[YZTheme accentColor]];
    tile->icon.hidden = NO;
    [self shapeIconOfTile:tile];
    tile->letter.text = nil;
    [self paintTile:tile color:[YZTheme stateColor] outlined:NO];
    tile->caption.text = YZT(@"Добавить");
    tile->caption.textColor = [self captionInk];
}

// a section without a heading is the tiles alone. plus puts the key of a new site first, whatever the number of tiles. every row stands in the middle on its own, the last one too
- (CGFloat)layoutSection:(NSString *)heading records:(NSArray *)records limit:(NSUInteger)limit plus:(BOOL)plus tiles:(NSMutableArray *)tiles
                  title:(UILabel *)title top:(CGFloat)top {
    NSUInteger shown = MIN([records count], limit);
    NSUInteger total = shown + (plus ? 1 : 0);
    NSUInteger lead = plus ? 1 : 0;
    while ([tiles count] > total) {
        [[tiles lastObject] removeFromSuperview];
        [tiles removeLastObject];
    }
    title.hidden = !total || !heading;
    if (!total)
        return top;
    CGFloat width = self.bounds.size.width;
    NSUInteger perRow = MAX((NSUInteger)3, (NSUInteger)((width - 2 * YZTileSide) / YZTileCell));
    NSUInteger columns = MIN(perRow, total);
    // the heading is centered over the whole width, not over the tile block: a section of one tile is one tile wide and cut "Избранное" to "Избра..."
    if (heading) {
        title.frame = CGRectMake(YZTileSide, top, MAX((CGFloat)0, width - 2 * YZTileSide), 22);
        if (_contentDirty) {
            title.text = heading;
            title.textColor = [self headingInk];
        }
        top += 32;
    }
    if (tiles == _siteTiles)
        _siteTop = top;
    else
        _bookmarkTop = top;
    for (NSUInteger i = 0; i < total; ++i) {
        YZTileButton *tile;
        if (i < [tiles count]) {
            tile = [tiles objectAtIndex:i];
        } else {
            tile = [[[YZTileButton alloc] initWithFrame:CGRectZero] autorelease];
            [tile addTarget:self action:@selector(tilePressed:) forControlEvents:UIControlEventTouchUpInside];
            [tiles addObject:tile];
            [self addSubview:tile];
        }
        tile.hidden = NO;
        if (_contentDirty) {
            if (i < lead)
                [self updatePlusTile:tile];
            else
                [self updateTile:tile record:[records objectAtIndex:i - lead]];
        }
        tile.frame = [self frameOfSlot:i total:total top:top];
    }
    NSUInteger rows = (total + columns - 1) / columns;
    return top + rows * (YZTileSize + YZTileLabelHeight + 8) + 12;
}

// the app picture and name stand at the top middle, as the logo of Firefox does. returns where the tiles
// begin
- (CGFloat)layoutBrandFromTop:(CGFloat)top {
    if (!_brandImage) {
        _brandImage = [[UIImageView alloc] initWithImage:[YZTheme mascotImage:@"hero"]];
        _brandImage.contentMode = UIViewContentModeScaleAspectFit;
        _brandGlow = [[UIImageView alloc] initWithFrame:CGRectZero];
        _brandGlow.userInteractionEnabled = NO;
        [self addSubview:_brandGlow];
        [self addSubview:_brandImage];
        // the name is a label of the system, no drawn wordmark
        _brandName = [[UILabel alloc] initWithFrame:CGRectZero];
        _brandName.text = @"Yozora";
        _brandName.font = [UIFont boldSystemFontOfSize:30];
        _brandName.textAlignment = YZTextAlignmentCenter;
        _brandName.backgroundColor = [UIColor clearColor];
        [self addSubview:_brandName];
    }
    BOOL showLogo = [YZSettings homeShows:YZHomePartLogo];
    BOOL showName = [YZSettings homeShows:YZHomePartName];
    BOOL showSearch = [YZSettings homeShows:YZHomePartSearch];
    _brandImage.hidden = !showLogo;
    _brandGlow.hidden = !showLogo || ![YZSettings mascotGlow];
    _brandName.hidden = !showName;
    _brandName.text = [YZSettings homeName];
    _brandName.textColor = [self headingInk];
    // a soft glow of the accent around the mascot: a finished picture behind it, not a shadow cast by its contour
    _brandGlow.image = [YZTheme glowImageWithColor:[YZTheme accentColor]];
    CGFloat width = self.bounds.size.width;
    // a phone on its side has little height, the picture shrinks before the tiles are pushed off the screen
    CGFloat side = MAX((CGFloat)80, MIN((CGFloat)150, self.bounds.size.height * 0.3f));
    if (showLogo || showName)
        top += 12;
    if (showLogo) {
        _brandImage.bounds = CGRectMake(0, 0, side, side);
        _brandImage.center = CGPointMake(width / 2, top + side / 2);
        _brandGlow.bounds = CGRectMake(0, 0, side * 1.7f, side * 1.7f);
        _brandGlow.center = _brandImage.center;
        top += side + 10;
    }
    if (showName) {
        _brandName.bounds = CGRectMake(0, 0, MIN(width - 32, (CGFloat)320), 36);
        _brandName.center = CGPointMake(width / 2, top + 18);
        top += 36 + 18;
    }
    if (!showSearch) {
        _searchBar.hidden = YES;
        return top + ((showLogo || showName) ? 8 : 0);
    }
    return [self layoutSearchFromTop:top] + 20;
}

// the line of the search under the name, as Firefox has it: the mark of the search engine small at the left, the hint, a tap opens the address field.
// the pill is the color of the address pill of the bars
- (CGFloat)layoutSearchFromTop:(CGFloat)top {
    if (!_searchBar) {
        _searchBar = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
        _searchBar.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        _searchBar.layer.shadowColor = [[UIColor blackColor] CGColor];
        _searchBar.layer.shadowRadius = 8;
        _searchBar.layer.shadowOffset = CGSizeMake(0, 2);
        [_searchBar addTarget:self action:@selector(searchPressed) forControlEvents:UIControlEventTouchUpInside];
        _searchMark = [[UIImageView alloc] initWithFrame:CGRectMake(14, 12, 24, 24)];
        _searchMark.contentMode = UIViewContentModeScaleAspectFit;
        _searchMark.userInteractionEnabled = NO;
        [_searchBar addSubview:_searchMark];
        _searchHint = [[UILabel alloc] initWithFrame:CGRectZero];
        _searchHint.backgroundColor = [UIColor clearColor];
        _searchHint.userInteractionEnabled = NO;
        [_searchBar addSubview:_searchHint];
        [self addSubview:_searchBar];
    }
    CGFloat width = self.bounds.size.width;
    CGFloat barWidth = MIN(width - 32, (CGFloat)520), barHeight = 48;
    _searchBar.hidden = NO;
    _searchBar.frame = CGRectMake(floor((width - barWidth) / 2), top, barWidth, barHeight);
    _searchBar.backgroundColor = [YZTheme addressFieldColor];
    _searchBar.layer.cornerRadius = [YZTheme isClassic] ? 10 : [YZTheme isFlat] ? 10 : barHeight / 2;
    _searchBar.layer.shadowOpacity = [YZTheme isFloatingBar] ? ([YZTheme isDark] ? 0.5f : 0.12f) : 0;
    _searchBar.layer.shadowPath = [[UIBezierPath bezierPathWithRoundedRect:_searchBar.bounds cornerRadius:_searchBar.layer.cornerRadius] CGPath];
    NSArray *logos = [NSArray arrayWithObjects:@"google", @"duckduckgo", @"yandex", nil];
    NSUInteger engine = (NSUInteger)[YZSettings searchEngine];
    UIImage *mark = engine < [logos count] ? [YZTheme logoNamed:[logos objectAtIndex:engine]] : nil;
    _searchMark.image = mark ? mark : [YZTheme icon:YZIconSearch size:24 color:[YZTheme fieldHintColor]];
    _searchHint.font = [YZTheme systemFontOfSize:16];
    _searchHint.textColor = [YZTheme fieldHintColor];
    _searchHint.text = YZT(@"Поиск или адрес");
    _searchHint.frame = CGRectMake(50, 0, MAX((CGFloat)0, barWidth - 64), barHeight);
    _searchBar.accessibilityLabel = YZT(@"Поиск или адрес");
    return top + barHeight;
}

- (void)searchPressed {
    [_homeDelegate homeViewDidTapSearch:self];
}

// the private session shows its note in place of the tiles. returns whether it did
- (BOOL)layoutHero {
    BOOL incognito = [YZTheme isIncognito];
    _heroDisc.hidden = !incognito;
    _heroTitle.hidden = !incognito;
    _heroText.hidden = !incognito;
    _brandImage.hidden = incognito;
    _brandGlow.hidden = incognito || ![YZSettings mascotGlow];
    _brandName.hidden = incognito;
    _searchBar.hidden = incognito;
    if (!incognito)
        return NO;
    if (!_heroDisc) {
        _heroDisc = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 96, 96)];
        _heroDisc.layer.cornerRadius = 48;
        [self addSubview:_heroDisc];
        _heroIcon = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 96, 96)];
        _heroIcon.contentMode = UIViewContentModeCenter;
        [_heroDisc addSubview:_heroIcon];
        _heroTitle = [[UILabel alloc] initWithFrame:CGRectZero];
        _heroTitle.font = [YZTheme boldSystemFontOfSize:22];
        _heroTitle.textAlignment = YZTextAlignmentCenter;
        _heroTitle.backgroundColor = [UIColor clearColor];
        [self addSubview:_heroTitle];
        _heroText = [[UILabel alloc] initWithFrame:CGRectZero];
        _heroText.font = [YZTheme systemFontOfSize:15];
        _heroText.numberOfLines = 0;
        _heroText.textAlignment = YZTextAlignmentCenter;
        _heroText.backgroundColor = [UIColor clearColor];
        [self addSubview:_heroText];
    }
    _heroDisc.hidden = NO;
    _heroTitle.hidden = NO;
    _heroText.hidden = NO;
    _heroDisc.backgroundColor = [YZTheme stateColor];
    _heroIcon.image = [YZTheme icon:YZIconIncognito size:48 color:[YZTheme accentColor]];
    _heroTitle.text = YZT(@"Приватный просмотр");
    _heroTitle.textColor = [YZTheme textColor];
    _heroText.text = [NSString stringWithFormat:@"%@\n\n%@", YZT(@"Страницы не попадают в историю. Cookie и данные сайтов удаляются, когда закрыта последняя приватная вкладка."),
                      YZT(@"Загруженные файлы и избранное сохраняются.")];
    _heroText.textColor = [YZTheme subtleTextColor];
    for (UIView *tile in self.subviews) {
        if ([tile isKindOfClass:[YZTileButton class]])
            tile.hidden = YES;
    }
    _bookmarksHeading.hidden = YES;
    // the blocker still runs in a private tab, but the page of the private session says only what the session keeps
    _protectedPill.hidden = YES;
    CGFloat width = self.bounds.size.width, textWidth = MIN(width - 48, (CGFloat)360);
    CGFloat top = 40;
    _heroDisc.bounds = CGRectMake(0, 0, 96, 96);
    _heroDisc.center = CGPointMake(width / 2, top + 48);
    top += 96 + 24;
    _heroTitle.frame = CGRectMake((width - textWidth) / 2, top, textWidth, 28);
    top += 28 + 12;
    CGSize fit = [_heroText sizeThatFits:CGSizeMake(textWidth, 10000)];
    _heroText.frame = CGRectMake((width - textWidth) / 2, top, textWidth, fit.height);
    self.contentSize = CGSizeMake(width, top + fit.height + 32);
    _contentDirty = NO;
    return YES;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // scrolling does not change tile geometry or content, and a dragged tile keeps the section as it is until it is let go
    if (self.bounds.size.width < 1 || _builtWidth == self.bounds.size.width || _dragTile)
        return;
    _builtWidth = self.bounds.size.width;
    if ([self layoutHero])
        return;
    NSArray *sites = _sites;
    if (![sites count] && ![_bookmarks count]) {
        // a first run has no history, so a few neutral starting points are shown
        NSMutableArray *defaults = [NSMutableArray array];
        NSArray *pairs = [NSArray arrayWithObjects:@"https://ru.wikipedia.org/", YZT(@"Википедия"), @"https://duckduckgo.com/", @"DuckDuckGo", nil];
        for (NSUInteger i = 0; i + 1 < [pairs count]; i += 2) {
            YZRecord *record = [[[YZRecord alloc] init] autorelease];
            record.url = [pairs objectAtIndex:i];
            record.title = [pairs objectAtIndex:i + 1];
            [defaults addObject:record];
        }
        sites = defaults;
    }
    sites = YZArrangedRecords(sites, [YZSettings homeSiteOrder], [YZSettings homeHiddenSites]);
    NSArray *bookmarks = YZArrangedRecords(_bookmarks, [YZSettings homeFavoriteOrder], nil);
    // the blocks stand in the order the person chose
    CGFloat top = 16;
    for (NSNumber *block in [YZSettings homeOrder]) {
        switch ([block intValue]) {
        case YOZORA_HOME_BRAND:
            top = [self layoutBrandFromTop:top];
            break;
        case YOZORA_HOME_SITES:
            // the recent sites can be taken off the page, the key that adds a site goes with them and the menu of the held page still adds one
            if ([YZSettings homeShows:YZHomePartRecent])
                top = [self layoutSection:nil records:sites limit:YZTilesPerSection plus:YES tiles:_siteTiles title:nil top:top];
            else
                top = [self layoutSection:nil records:nil limit:0 plus:NO tiles:_siteTiles title:nil top:top];
            break;
        case YOZORA_HOME_FAVORITES:
            top = [self layoutSection:YZT(@"Избранное") records:bookmarks limit:YZFavoritesMax plus:NO tiles:_bookmarkTiles title:_bookmarksHeading top:top];
            break;
        }
    }
    top = [self layoutProtectedPillFromTop:top];
    self.contentSize = CGSizeMake(self.bounds.size.width, top + 16);
    _contentDirty = NO;
}

static const CGFloat YZPillHeight = 44;

// shown while the blocker of trackers is on and in no private tab: the page makes no claim that is not true. the pill stands under
// the last block and scrolls with it
- (CGFloat)layoutProtectedPillFromTop:(CGFloat)top {
    BOOL shown = [YZSettings blockTrackers] && ![YZTheme isIncognito];
    if (!shown) {
        _protectedPill.hidden = YES;
        return top;
    }
    if (!_protectedPill) {
        _protectedPill = [[YZPlateView alloc] initWithFrame:CGRectZero];
        _protectedPill.layer.cornerRadius = YZPillHeight / 2;
        _protectedIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
        _protectedIcon.contentMode = UIViewContentModeCenter;
        [_protectedPill addSubview:_protectedIcon];
        _protectedLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _protectedLabel.font = [YZTheme boldSystemFontOfSize:15];
        _protectedLabel.backgroundColor = [UIColor clearColor];
        _protectedLabel.text = YZT(@"Вы защищены");
        [_protectedPill addSubview:_protectedLabel];
        [self addSubview:_protectedPill];
    }
    _protectedPill.hidden = NO;
    [(YZPlateView *)_protectedPill applyTheme];
    _protectedPill.layer.cornerRadius = YZPillHeight / 2;
    _protectedLabel.textColor = [YZTheme textColor];
    _protectedIcon.image = [YZTheme icon:YZIconShield size:22 color:[YZTheme fieldAccentColor]];
    CGSize text = YZTextSize(_protectedLabel.text, _protectedLabel.font);
    CGFloat width = MIN(ceil(text.width) + 22 + 8 + 2 * 20, self.bounds.size.width - 32);
    top += 12;
    _protectedPill.frame = CGRectMake(floor((self.bounds.size.width - width) / 2), top, width, YZPillHeight);
    _protectedIcon.frame = CGRectMake(20, 0, 22, YZPillHeight);
    _protectedLabel.frame = CGRectMake(20 + 22 + 8, 0, width - 20 - 22 - 8 - 20, YZPillHeight);
    return top + YZPillHeight;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_siteTiles release];
    [_bookmarkTiles release];
    [_bookmarksHeading release];
    [_protectedPill release];
    [_protectedIcon release];
    [_protectedLabel release];
    [_ground removeFromSuperview];
    [_ground release];
    [_backdrop release];
    [_gradient release];
    [_topEdgeColor release];
    [_bottomEdgeColor release];
    [_dragTile release];
    [_dragOrder release];
    [_searchBar release];
    [_searchMark release];
    [_searchHint release];
    [_brandGlow release];
    [_brandImage release];
    [_brandName release];
    [_heroDisc release];
    [_heroIcon release];
    [_heroTitle release];
    [_heroText release];
    [_sites release];
    [_bookmarks release];
    [super dealloc];
}
@end
