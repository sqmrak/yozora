#import "YZSettingsController.h"
#import "YZCrash.h"
#import <objc/message.h>
#import "YZCompat.h"
#import "YZAccentEditor.h"
#import "YZTintPicker.h"
#if defined(__arm64__)
#import "../core/core/YozoraMetal.h"
// the row exists where the core can paint tiles on the gpu: arm64 from ios 11
#define YZMetalRows ([[[UIDevice currentDevice] systemVersion] floatValue] >= 11.0f ? row(YZRowMetal) : nil),
#else
#define YZMetalRows
#endif
#import "YZBackground.h"
#import "YZBackgroundPreview.h"
#import "YZDnsPopup.h"
#import "YZMascotPreview.h"
#import "YZAppIcon.h"
#import "YZClassic.h"
#import "YZControls.h"
#import "YZDialog.h"
#import "YZLog.h"
#import "YZAdblockController.h"
#import "YZLogController.h"
#import "YZSitesController.h"
#import "YZCertificates.h"
#import "YZCertificatesController.h"
#import "YZShape.h"
#import "YZMotion.h"
#import "YZSettings.h"
#import "YZStrings.h"
#import "YZTheme.h"
#import "YZUpdateUI.h"
#include "yozora_core.h"
#import <QuartzCore/QuartzCore.h>


typedef enum {
    YZRowLanguage,
    YZRowTheme,
    YZRowDesign,
    YZRowTabsLayout,
    YZRowMascotGlow,
    YZRowAccent,
    YZRowPrivateAccent,
    YZRowMascot,
    YZRowBackground,
    YZRowSearchEngine,
    YZRowTextSize,
    YZRowAppIcons,
    YZRowBlockTrackers,
    YZRowAdblockRules,
    YZRowSitePermissions,
    YZRowDns,
    YZRowCertificates,
    YZRowBlockThirdPartyCookies,
    YZRowSaveHistory,
    YZRowClearHistory,
    YZRowClearSiteData,
    YZRowJavascript,
    YZRowEconomy,
    YZRowReduceMotion,
    YZRowHideBars,
    YZRowWebFonts,
    YZRowDebug,
    YZRowLogging,
    YZRowLogOpen,
    YZRowZombies,
    YZRowUnlockDesigns,
    YZRowJit,
    YZRowJitState,
    YZRowMetal,
    YZRowUpdate,
    YZRowAbout
} YZRow;

// the navigation bar and the table take the colors of the chosen theme
static void YZStyleTable(UITableViewController *controller) {
    // every layer behind the rows takes the theme ground: a table, its controller and the navigation
    // controller each have a view that shows through when the table is short. a ground view is the table
    // background because the table's own background color left a dark ground between light rows on ios 6
    UIView *ground = controller.tableView.backgroundView;
    if (!ground || ground.tag != 9001) {
        ground = [[[UIView alloc] initWithFrame:controller.tableView.bounds] autorelease];
        ground.tag = 9001;
        ground.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        controller.tableView.backgroundView = ground;
    }
    ground.backgroundColor = [YZTheme screenColor];
    controller.tableView.opaque = YES;
    controller.tableView.backgroundColor = [YZTheme screenColor];
    controller.view.backgroundColor = [YZTheme screenColor];
    YZPaintBehindScreens(controller.navigationController);
    controller.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    // the bar is clear on every settings screen and each has its own fill behind it, a shared bar fill showed
    // the other screen's color during push and pop
    [YZTheme styleTransparentNavigationBar:controller.navigationController.navigationBar];
}

// a rounded rectangle with a radius of its own at each corner, the rows of a group share one outline
static UIBezierPath *YZCornerPath(CGRect r, CGFloat tl, CGFloat tr, CGFloat br, CGFloat bl) {
    UIBezierPath *path = [UIBezierPath bezierPath];
    CGFloat left = CGRectGetMinX(r), top = CGRectGetMinY(r), right = CGRectGetMaxX(r), bottom = CGRectGetMaxY(r);
    [path moveToPoint:CGPointMake(left + tl, top)];
    [path addLineToPoint:CGPointMake(right - tr, top)];
    [path addArcWithCenter:CGPointMake(right - tr, top + tr) radius:tr startAngle:-(CGFloat)M_PI_2 endAngle:0 clockwise:YES];
    [path addLineToPoint:CGPointMake(right, bottom - br)];
    [path addArcWithCenter:CGPointMake(right - br, bottom - br) radius:br startAngle:0 endAngle:(CGFloat)M_PI_2 clockwise:YES];
    [path addLineToPoint:CGPointMake(left + bl, bottom)];
    [path addArcWithCenter:CGPointMake(left + bl, bottom - bl) radius:bl startAngle:(CGFloat)M_PI_2 endAngle:(CGFloat)M_PI clockwise:YES];
    [path addLineToPoint:CGPointMake(left, top + tl)];
    [path addArcWithCenter:CGPointMake(left + tl, top + tl) radius:tl startAngle:(CGFloat)M_PI endAngle:(CGFloat)(M_PI + M_PI_2) clockwise:YES];
    [path closePath];
    return path;
}

typedef enum {
    YZPositionSingle,
    YZPositionFirst,
    YZPositionMiddle,
    YZPositionLast
} YZPosition;

static const CGFloat YZGroupRadius = 22;
static const CGFloat YZInnerRadius = 6;

// a row card is a stretchable picture and not a view cut by a mask: a mask makes the render server draw every
// row twice, and a list of twenty rows dropped frames on an old phone. one picture per place in a group and
// color, kept for the next row
static UIImage *YZCardImage(YZPosition position, UIColor *color) {
    static NSMutableDictionary *cache;
    if (!cache)
        cache = [[NSMutableDictionary alloc] init];
    CGFloat c[4] = { 0, 0, 0, 1 };
    [color getRed:&c[0] green:&c[1] blue:&c[2] alpha:&c[3]];
    BOOL classic = [YZTheme isClassic];
    NSString *key = [NSString stringWithFormat:@"%d:%d:%.3f:%.3f:%.3f:%.3f", classic ? 1 : 0, (int)position, c[0], c[1], c[2], c[3]];
    UIImage *image = [cache objectForKey:key];
    if (image)
        return image;
    // a bound on the pictures held, a new accent makes a new set
    if ([cache count] > 80)
        [cache removeAllObjects];
    CGFloat big = classic ? [YZTheme cardRadius] : YZGroupRadius, small = classic ? 0 : YZInnerRadius;
    CGFloat top = (position == YZPositionSingle || position == YZPositionFirst) ? big : small;
    CGFloat bottom = (position == YZPositionSingle || position == YZPositionLast) ? big : small;
    CGFloat side = 2 * big + 2;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, 0);
    [color setFill];
    [YZCornerPath(CGRectMake(0, 0, side, side), top, top, bottom, bottom) fill];
    if (classic) {
        // a grouped list of the old system: a thin outline around the group. a row below another leaves out its top line, which is the
        // bottom line of the row above, so two rows meet in one line
        BOOL opensGroup = position == YZPositionSingle || position == YZPositionFirst;
        CGRect box = opensGroup ? CGRectMake(0.5f, 0.5f, side - 1, side - 1) : CGRectMake(0.5f, -0.5f, side - 1, side);
        UIBezierPath *outline = YZCornerPath(box, top, top, bottom, bottom);
        outline.lineWidth = 1;
        [[YZTheme separatorColor] setStroke];
        [outline stroke];
    }
    image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    [cache setObject:image forKey:key];
    return image;
}

// the height of a text at a width is asked twice per row (table and row) and again on every scroll of a new
// row, so it is kept
static NSMutableDictionary *YZHeightCache(void) {
    static NSMutableDictionary *cache;
    if (!cache)
        cache = [[NSMutableDictionary alloc] init];
    return cache;
}

// the height of a text at a width, wrapped on words: the titles of the rows are as long as they are and are never cut
static CGFloat YZMeasureHeight(NSString *text, UIFont *font, CGFloat width) {
    if (![text length])
        return 0;
    NSMutableDictionary *cache = YZHeightCache();
    NSString *key = [NSString stringWithFormat:@"%.1f|%.0f|%@", font.pointSize, width, text];
    NSNumber *known = [cache objectForKey:key];
    if (known)
        return (CGFloat)[known doubleValue];
    if ([cache count] > 600)
        [cache removeAllObjects];
    static UILabel *probe;
    if (!probe) {
        probe = [[UILabel alloc] initWithFrame:CGRectZero];
        probe.numberOfLines = 0;
        probe.lineBreakMode = YZLineBreakWordWrapping;
    }
    probe.font = font;
    probe.text = text;
    CGFloat height = ceil([probe sizeThatFits:CGSizeMake(MAX(width, (CGFloat)10), 2000)].height);
    [cache setObject:[NSNumber numberWithDouble:height] forKey:key];
    return height;
}

// the width left for a row's texts: the card is 16 points in on each side, the glyph disc, switch and chevron
// take their room
static CGFloat YZRowTextWidth(CGFloat tableWidth, BOOL disc, BOOL toggle, BOOL accessory) {
    if ([YZTheme isFlat]) {
        // rows of ios 7 to 12 run the whole width: 15 points in, a square of 29 for the glyph, 51 for the switch
        CGFloat flatLeft = disc ? 15 + 29 + 12 : 15;
        CGFloat flatRight = toggle ? 15 + 51 + 12 : (accessory ? 34 : 15);
        return MAX((CGFloat)0, tableWidth - flatLeft - flatRight);
    }
    CGFloat left = disc ? 16 + 40 + 14 : 16;
    CGFloat right = toggle ? 16 + [YZToggle controlSize].width + 12 : (accessory ? 12 + 24 + 4 : 16);
    return MAX((CGFloat)0, tableWidth - 32 - left - right);
}

static CGFloat YZRowHeight(NSString *title, NSString *detail, CGFloat tableWidth, BOOL disc, BOOL toggle, BOOL accessory) {
    CGFloat width = YZRowTextWidth(tableWidth, disc, toggle, accessory);
    BOOL flat = [YZTheme isFlat];
    CGFloat titleHeight = YZMeasureHeight(title, [YZTheme systemFontOfSize:flat ? 17 : 16], width);
    CGFloat detailHeight = YZMeasureHeight(detail, [YZTheme systemFontOfSize:13], width);
    if (flat) {
        CGFloat flatHeight = 11 + titleHeight + (detailHeight > 0 ? 2 + detailHeight : 0) + 11;
        return MAX(detailHeight > 0 ? (CGFloat)58 : (CGFloat)44, flatHeight);
    }
    CGFloat height = 16 + titleHeight + (detailHeight > 0 ? 3 + detailHeight : 0) + 16;
    return MAX(detailHeight > 0 ? (CGFloat)68 : (CGFloat)58, height);
}

// a settings row: a card with corners by its place in the group, a glyph in a tonal disc, a title, a line
// under it and a chevron or a switch. texts wrap and the row is as tall as they are
@interface YZSettingsCell : UITableViewCell {
@public
    UIView *card;
    UIView *disc;
    UIImageView *icon;
    UILabel *title;
    UILabel *detail;
    UIImageView *accessory;
    YZToggle *toggle;
    // the dark veil and the lock of an option that this system cannot take, built when the first locked option asks
    UIView *veil;
    UIImageView *lock;
    // the hairlines of a row of the flat design: under it (from the text, or the whole width at the end of a group) and over the first
    UIView *lineBelow;
    UIView *lineAbove;
    // the color ball of a row that shows a color and morphs, hidden in every other row
    YZMorphView *ball;
    // the color of the card at rest: the card color, or the tint of a chosen option
    UIColor *restColor;
    // the colors of the texts while a pressed row of the classic design is filled with the accent and its texts are white
    UIColor *savedTitleColor;
    UIColor *savedDetailColor;
    YZPosition position;
    BOOL withDisc;
    // the mark fills the disc's place without a disc: a flag or a preview in a Material shape
    BOOL bareMark;
}
@end

@implementation YZSettingsCell
- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    (void)style;
    if (!self)
        return nil;
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    card = [[UIView alloc] initWithFrame:CGRectZero];
    // the picture has transparent corners: a view that is opaque would show them black
    card.opaque = NO;
    card.backgroundColor = [UIColor clearColor];
    card.userInteractionEnabled = YES;
    [self.contentView addSubview:card];
    disc = [[UIView alloc] initWithFrame:CGRectZero];
    disc.layer.cornerRadius = 20;
    [card addSubview:disc];
    icon = [[UIImageView alloc] initWithFrame:CGRectZero];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [disc addSubview:icon];
    title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.font = [YZTheme systemFontOfSize:16];
    title.backgroundColor = [UIColor clearColor];
    title.numberOfLines = 0;
    title.lineBreakMode = YZLineBreakWordWrapping;
    [card addSubview:title];
    detail = [[UILabel alloc] initWithFrame:CGRectZero];
    detail.font = [YZTheme systemFontOfSize:13];
    detail.backgroundColor = [UIColor clearColor];
    detail.numberOfLines = 0;
    detail.lineBreakMode = YZLineBreakWordWrapping;
    [card addSubview:detail];
    accessory = [[UIImageView alloc] initWithFrame:CGRectZero];
    accessory.contentMode = UIViewContentModeCenter;
    [card addSubview:accessory];
    return self;
}

// the switch and the morphing ball belong to a few rows and are built when the first of those asks: a cell
// that never shows them carries neither, and every ball in a visible cell runs two animations on the render
// server while the table scrolls
- (YZToggle *)switchControl {
    if (!toggle) {
        toggle = [[YZToggle alloc] initWithFrame:CGRectZero];
        [card addSubview:toggle];
    }
    return toggle;
}

- (YZMorphView *)morphBall {
    if (!ball) {
        ball = [[YZMorphView alloc] initWithFrame:CGRectZero];
        [disc addSubview:ball];
    }
    return ball;
}

- (BOOL)showsSwitch {
    return toggle && !toggle.hidden;
}

- (void)setLocked:(BOOL)locked {
    if (!locked && !veil)
        return;
    if (!veil) {
        veil = [[UIView alloc] initWithFrame:CGRectZero];
        veil.opaque = NO;
        veil.userInteractionEnabled = NO;
        lock = [[UIImageView alloc] initWithFrame:CGRectZero];
        lock.contentMode = UIViewContentModeCenter;
        [card addSubview:veil];
        [card addSubview:lock];
    }
    veil.hidden = lock.hidden = !locked;
    if (locked) {
        [YZTheme stretchImage:YZCardImage(position, [UIColor colorWithWhite:0 alpha:0.5f]) caps:YZGroupRadius onView:veil];
        lock.image = [YZTheme icon:YZIconLock size:26 color:[UIColor whiteColor]];
        [card bringSubviewToFront:veil];
        [card bringSubviewToFront:lock];
    }
    [self setNeedsLayout];
}

// the card is the picture of its place in the group in the given color
- (void)showCardColor:(UIColor *)color {
    if ([YZTheme isFlat]) {
        card.layer.contents = nil;
        card.backgroundColor = color;
        return;
    }
    card.backgroundColor = [UIColor clearColor];
    [YZTheme stretchImage:YZCardImage(position, color) caps:YZGroupRadius onView:card];
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    // a row with a switch changes by its switch, so only the other rows light up and bounce their glyph
    BOOL pressed = highlighted && ![self showsSwitch];
    if ([YZTheme isClassic]) {
        // the row of ios 5 and 6 fills with the color of the selection while it is held, its texts turn white: the accent of the bars
        if (pressed && !savedTitleColor) {
            savedTitleColor = [title.textColor retain];
            savedDetailColor = [detail.textColor retain];
            title.textColor = [UIColor whiteColor];
            detail.textColor = [UIColor colorWithWhite:1 alpha:0.8f];
        } else if (!pressed && savedTitleColor) {
            title.textColor = savedTitleColor;
            detail.textColor = savedDetailColor;
            [savedTitleColor release];
            [savedDetailColor release];
            savedTitleColor = nil;
            savedDetailColor = nil;
        }
        [self showCardColor:pressed ? [YZClassic barMidColor] : (restColor ? restColor : [YZTheme cardColor])];
        if (pressed)
            [YZTheme animateFeedbackOfView:disc];
        return;
    }
    [self showCardColor:pressed ? [YZTheme pressedColor] : (restColor ? restColor : [YZTheme cardColor])];
    if (pressed)
        [YZTheme animateFeedbackOfView:disc];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width, height = self.contentView.bounds.size.height;
    if ([YZTheme isFlat]) {
        [self layoutFlatWidth:width height:height];
        return;
    }
    lineBelow.hidden = lineAbove.hidden = YES;
    // the rows of a classic group touch, the modern cards stand a point apart
    card.frame = [YZTheme isClassic] ? CGRectMake(16, 0, width - 32, height) : CGRectMake(16, 1, width - 32, height - 2);
    CGFloat cw = card.bounds.size.width, ch = card.bounds.size.height;
    disc.hidden = !withDisc;
    if (withDisc) {
        disc.bounds = CGRectMake(0, 0, 40, 40);
        disc.center = CGPointMake(16 + 20, ch / 2);
        icon.frame = bareMark ? disc.bounds : CGRectInset(disc.bounds, 8, 8);
        ball.frame = CGRectInset(disc.bounds, 6, 6);
    }
    if ([self showsSwitch]) {
        CGSize size = [YZToggle controlSize];
        toggle.frame = CGRectMake(cw - 16 - size.width, (ch - size.height) / 2, size.width, size.height);
    }
    if (accessory.image)
        accessory.frame = CGRectMake(cw - 12 - 24, (ch - 24) / 2, 24, 24);
    veil.frame = card.bounds;
    lock.frame = card.bounds;
    CGFloat textWidth = YZRowTextWidth(width, withDisc, [self showsSwitch], accessory.image != nil);
    CGFloat left = withDisc ? 16 + 40 + 14 : 16;
    CGFloat titleHeight = YZMeasureHeight(title.text, title.font, textWidth);
    CGFloat detailHeight = YZMeasureHeight(detail.text, detail.font, textWidth);
    CGFloat block = titleHeight + (detailHeight > 0 ? 3 + detailHeight : 0);
    CGFloat y = floor((ch - block) / 2);
    title.frame = CGRectMake(left, y, textWidth, titleHeight);
    detail.frame = detailHeight > 0 ? CGRectMake(left, y + titleHeight + 3, textWidth, detailHeight) : CGRectZero;
}

- (void)layoutFlatWidth:(CGFloat)width height:(CGFloat)height {
    if (!lineBelow) {
        lineBelow = [[UIView alloc] initWithFrame:CGRectZero];
        lineAbove = [[UIView alloc] initWithFrame:CGRectZero];
        [card addSubview:lineBelow];
        [card addSubview:lineAbove];
    }
    card.frame = CGRectMake(0, 0, width, height);
    CGFloat cw = width, ch = height;
    disc.hidden = !withDisc;
    if (withDisc) {
        disc.bounds = CGRectMake(0, 0, 29, 29);
        disc.center = CGPointMake(15 + 14.5f, ch / 2);
        icon.frame = bareMark ? disc.bounds : CGRectInset(disc.bounds, 4, 4);
        ball.frame = CGRectInset(disc.bounds, 4, 4);
    }
    if ([self showsSwitch]) {
        CGSize size = [YZToggle controlSize];
        toggle.frame = CGRectMake(cw - 15 - size.width, (ch - size.height) / 2, size.width, size.height);
    }
    if (accessory.image)
        accessory.frame = CGRectMake(cw - 8 - 24, (ch - 24) / 2, 24, 24);
    CGFloat textWidth = YZRowTextWidth(width, withDisc, [self showsSwitch], accessory.image != nil);
    CGFloat left = withDisc ? 15 + 29 + 12 : 15;
    CGFloat titleHeight = YZMeasureHeight(title.text, title.font, textWidth);
    CGFloat detailHeight = YZMeasureHeight(detail.text, detail.font, textWidth);
    CGFloat block = titleHeight + (detailHeight > 0 ? 2 + detailHeight : 0);
    CGFloat y = floor((ch - block) / 2);
    title.frame = CGRectMake(left, y, textWidth, titleHeight);
    detail.frame = detailHeight > 0 ? CGRectMake(left, y + titleHeight + 2, textWidth, detailHeight) : CGRectZero;
    BOOL opens = position == YZPositionSingle || position == YZPositionFirst;
    BOOL ends = position == YZPositionSingle || position == YZPositionLast;
    CGFloat line = 1.0f / [[UIScreen mainScreen] scale];
    lineAbove.hidden = !opens;
    lineAbove.frame = CGRectMake(0, 0, cw, line);
    lineBelow.hidden = NO;
    lineBelow.frame = ends ? CGRectMake(0, ch - line, cw, line) : CGRectMake(left, ch - line, MAX((CGFloat)0, cw - left), line);
    lineAbove.backgroundColor = lineBelow.backgroundColor = [YZTheme separatorColor];
    veil.frame = card.bounds;
    lock.frame = card.bounds;
}

- (void)dealloc {
    [lineBelow release];
    [lineAbove release];
    [card release];
    [disc release];
    [icon release];
    [ball release];
    [title release];
    [detail release];
    [accessory release];
    [toggle release];
    [veil release];
    [lock release];
    [restColor release];
    [savedTitleColor release];
    [savedDetailColor release];
    [super dealloc];
}
@end

// fills a cell: texts, theme colors, glyph or mark, place in the group. plate is the color of a chosen
// option, nil for a row at rest. a bare mark has no disc
// what a logo or a picture stands on: white on the light theme, dark on the dark and black ones, so the disc behind the mark of a search engine
// is not a white spot in a dark list
static UIColor *YZMarkGround(void) {
    if (![YZTheme isDark])
        return [UIColor whiteColor];
    return [UIColor colorWithWhite:[YZSettings theme] == YZThemeBlack ? 0.06f : 0.14f alpha:1];
}

static void YZConfigureCell(YZSettingsCell *cell, NSString *title, NSString *detail, YZIcon glyph, UIImage *picture, BOOL hasGlyph, BOOL bare,
                            BOOL destructive, YZPosition position, UIColor *plate, BOOL chevron) {
    cell->position = position;
    [cell setLocked:NO];
    cell->withDisc = hasGlyph || picture;
    cell->bareMark = bare && picture;
    [cell->savedTitleColor release];
    [cell->savedDetailColor release];
    cell->savedTitleColor = nil;
    cell->savedDetailColor = nil;
    [cell->restColor release];
    cell->restColor = [(plate ? plate : [YZTheme cardColor]) retain];
    [cell showCardColor:cell->restColor];
    BOOL flat = [YZTheme isFlat];
    cell->disc.layer.cornerRadius = cell->bareMark ? 0 : (flat ? 7 : 20);
    cell->disc.backgroundColor = cell->bareMark ? [UIColor clearColor]
        : (picture ? YZMarkGround() : (flat ? (destructive ? [YZTheme errorColor] : [YZTheme accentColor]) : (destructive ? [[YZTheme errorColor] colorWithAlphaComponent:0.16f] : [YZTheme stateColor])));
    cell->disc.layer.borderWidth = (picture && !cell->bareMark) ? 1 : 0;
    cell->disc.layer.borderColor = [[YZTheme separatorColor] CGColor];
    cell->icon.image = picture ? picture : (hasGlyph ? [YZTheme icon:glyph size:flat ? 21 : 24 color:flat ? [UIColor whiteColor] : (destructive ? [YZTheme errorColor] : [YZTheme accentColor])] : nil);
    // the classic glyph is white on a lit rounded tile of the accent (or of the error red), the tile of the settings of the old system
    if ([YZTheme isClassic] && !picture && hasGlyph) {
        CGFloat radius = 9;
        UIColor *tile = destructive ? [YZTheme errorColor] : [YZClassic barMidColor];
        cell->disc.layer.cornerRadius = radius;
        cell->disc.backgroundColor = [UIColor clearColor];
        cell->disc.layer.borderWidth = 0;
        [YZClassic lightView:cell->disc color:tile radius:radius];
        cell->icon.image = [YZClassic stampedImage:[YZTheme icon:glyph size:24 color:[UIColor whiteColor]]];
    } else {
        [YZClassic unlightView:cell->disc];
        cell->disc.layer.contents = nil;
    }
    cell->ball.hidden = YES;
    cell->icon.hidden = NO;
    // a row that is reused takes the size of the text of the moment
    cell->title.font = [YZTheme systemFontOfSize:flat ? 17 : 16];
    cell->detail.font = [YZTheme systemFontOfSize:13];
    cell->title.text = title;
    cell->title.textColor = destructive ? [YZTheme errorColor] : [YZTheme textColor];
    cell->detail.text = detail;
    cell->detail.textColor = [YZTheme subtleTextColor];
    cell->accessory.image = chevron ? [YZTheme icon:YZIconChevron size:flat ? 20 : 24 color:flat ? [[YZTheme subtleTextColor] colorWithAlphaComponent:0.7f] : [YZTheme subtleTextColor]] : nil;
    [cell setNeedsLayout];
}

// the head of a section is its first row: the name in the accent, a chevron that turns down while open, a
// material 3 pill under it while pressed. a row and not a table header because headers of a plain table stay
// at the top while their rows go by
@interface YZSectionCell : UITableViewCell {
@public
    UILabel *name;
    UIImageView *mark;
    UIImageView *chevron;
    UIView *pill;
    BOOL expanded;
}
@end

@implementation YZSectionCell
- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    (void)style;
    if (!self)
        return nil;
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    pill = [[UIView alloc] initWithFrame:CGRectZero];
    pill.alpha = 0;
    pill.userInteractionEnabled = NO;
    [self.contentView addSubview:pill];
    mark = [[UIImageView alloc] initWithFrame:CGRectZero];
    [self.contentView addSubview:mark];
    name = [[UILabel alloc] initWithFrame:CGRectZero];
    name.backgroundColor = [UIColor clearColor];
    [self.contentView addSubview:name];
    chevron = [[UIImageView alloc] initWithFrame:CGRectZero];
    chevron.contentMode = UIViewContentModeCenter;
    [self.contentView addSubview:chevron];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width, height = self.contentView.bounds.size.height;
    if ([YZTheme isFlat]) {
        // the header of a group of ios 7 to 12: small gray capitals over the group, a chevron at the end for folding it
        CGFloat flatLeft = mark.image ? 15 + 24 : 15;
        mark.frame = CGRectMake(15, height - 27, 18, 18);
        name.frame = CGRectMake(flatLeft, height - 28, MAX((CGFloat)0, width - flatLeft - 50), 20);
        chevron.bounds = CGRectMake(0, 0, 20, 20);
        chevron.center = CGPointMake(width - 25, height - 18);
        pill.alpha = 0;
        return;
    }
    CGFloat labelLeft = mark.image ? 32 + 24 : 32;
    mark.frame = CGRectMake(32, height - 28, 20, 20);
    name.frame = CGRectMake(labelLeft, height - 28, MAX((CGFloat)0, width - labelLeft - 72), 20);
    chevron.bounds = CGRectMake(0, 0, 20, 20);
    chevron.center = CGPointMake(width - 42, height - 18);
    pill.bounds = CGRectMake(0, 0, 44, 32);
    pill.center = chevron.center;
    pill.layer.cornerRadius = 16;
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    pill.backgroundColor = [YZTheme stateColor];
    if (highlighted) {
        if (pill.alpha == 0)
            pill.transform = CGAffineTransformMakeScale(0.7f, 0.7f);
        YZMotionAnimateView(pill, CGAffineTransformIdentity, 1, YOZORA_MOTION_WOBBLE, 0, nil);
    } else {
        YZMotionAnimateView(pill, CGAffineTransformMakeScale(0.92f, 0.92f), 0, YOZORA_MOTION_DISMISS, 0, nil);
    }
}

- (void)dealloc {
    [name release];
    [mark release];
    [chevron release];
    [pill release];
    [super dealloc];
}
@end

// one icon of the picker: its picture and name, a ring in the accent around the one the home screen shows. the
// pictures carry their own corners, so nothing masks them
// the icons of ios 7 to 12 are 60 points, the other designs keep 64
#define YZIconTileSide ([YZTheme isFlat] ? (CGFloat)60 : (CGFloat)64)
static const CGFloat YZIconTileWidth = 88;
static const CGFloat YZIconTilesHead = 44;

@interface YZIconTile : UIControl {
@public
    NSString *iconName;
    UIImageView *picture;
    UIView *ring;
    UILabel *label;
}
- (id)initWithName:(NSString *)name;
- (void)showSelected:(BOOL)selected;
@end

@implementation YZIconTile
- (id)initWithName:(NSString *)name {
    self = [super initWithFrame:CGRectMake(0, 0, YZIconTileWidth, YZIconTileSide + 28)];
    if (!self)
        return nil;
    iconName = [name copy];
    ring = [[UIView alloc] initWithFrame:CGRectMake((YZIconTileWidth - YZIconTileSide) / 2 - 4, -4, YZIconTileSide + 8, YZIconTileSide + 8)];
    // the ring runs concentric with the corner of the picture, a ring with a wider corner than the picture's left a dark wedge of the card in
    // each corner of a selected icon
    ring.layer.cornerRadius = YZIconTileSide * ([YZTheme isFlat] ? 0.2237f : 0.175f) + 4;
    ring.layer.borderWidth = 3;
    ring.userInteractionEnabled = NO;
    [self addSubview:ring];
    picture = [[UIImageView alloc] initWithFrame:CGRectMake((YZIconTileWidth - YZIconTileSide) / 2, 0, YZIconTileSide, YZIconTileSide)];
    picture.contentMode = UIViewContentModeScaleAspectFit;
    picture.userInteractionEnabled = NO;
    // the files are cut with a corner of 0.175, the icons of ios 7 to 12 have 0.2237: the flat design cuts the picture to that corner, so the
    // ring around it fits
    if ([YZTheme isFlat]) {
        picture.layer.cornerRadius = YZIconTileSide * 0.2237f;
        picture.layer.masksToBounds = YES;
    }
    // an install that has to overwrite the Icon files keeps the real ones in its own folder, and the tile of the
    // icon of the app shows those, the files of the bundle may hold the icon chosen
    NSString *bundle = [[NSBundle mainBundle] bundlePath];
    NSString *path = name ? [[NSBundle mainBundle] pathForResource:[name stringByAppendingString:@"-60@3x"] ofType:@"png"]
                          : [bundle stringByAppendingPathComponent:@"yozora-original-icons/Icon-60@3x.png"];
    if (!name && ![[NSFileManager defaultManager] fileExistsAtPath:path])
        path = [[NSBundle mainBundle] pathForResource:@"Icon-60@3x" ofType:@"png"];
    picture.image = path ? [UIImage imageWithContentsOfFile:path] : nil;
    [self addSubview:picture];
    label = [[UILabel alloc] initWithFrame:CGRectMake(0, YZIconTileSide + 8, YZIconTileWidth, 18)];
    label.backgroundColor = [UIColor clearColor];
    label.textAlignment = YZTextAlignmentCenter;
    label.font = [YZTheme systemFontOfSize:12];
    // the file prefix of the alternate icon stays "Fox" (Info.plist and the stored choice use it), the name shown is the full one
    label.text = !name ? @"Yozora" : ([name isEqualToString:@"Fox"] ? @"YozoraFox" : name);
    [self addSubview:label];
    self.accessibilityLabel = label.text;
    return self;
}

- (void)showSelected:(BOOL)selected {
    ring.layer.borderColor = [[YZTheme accentColor] CGColor];
    ring.hidden = !selected;
    label.textColor = selected ? [YZTheme accentColor] : [YZTheme subtleTextColor];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.7f : 1;
}

- (void)dealloc {
    [iconName release];
    [picture release];
    [ring release];
    [label release];
    [super dealloc];
}
@end

static CGFloat YZIconTilesHeight(CGFloat tableWidth, NSString *note) {
    CGFloat noteHeight = YZMeasureHeight(note, [YZTheme systemFontOfSize:13], MAX((CGFloat)0, tableWidth - 64));
    return YZIconTilesHead + YZIconTileSide + 28 + 12 + (noteHeight > 0 ? noteHeight + 12 : 0);
}

// the row of the app icons in the group of the first section: a card with a title, a tile for the icon of the app
// and one for each alternate icon, and under them what keeps the choice from working where that is so
@interface YZIconTilesCell : UITableViewCell {
@public
    UIView *card;
    UILabel *title;
    UILabel *note;
    NSMutableArray *tiles;
    YZPosition position;
    UIView *lineAbove;
    UIView *lineBelow;
    void (^choose)(NSString *name);
}
- (void)showNote:(NSString *)text enabled:(BOOL)enabled position:(YZPosition)place;
- (void)refreshSelection;
@end

@implementation YZIconTilesCell
- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    (void)style;
    if (!self)
        return nil;
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    card = [[UIView alloc] initWithFrame:CGRectZero];
    card.opaque = NO;
    card.backgroundColor = [UIColor clearColor];
    [self.contentView addSubview:card];
    title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.backgroundColor = [UIColor clearColor];
    title.font = [YZTheme systemFontOfSize:16];
    [card addSubview:title];
    note = [[UILabel alloc] initWithFrame:CGRectZero];
    note.backgroundColor = [UIColor clearColor];
    note.font = [YZTheme systemFontOfSize:13];
    note.numberOfLines = 0;
    note.lineBreakMode = YZLineBreakWordWrapping;
    [card addSubview:note];
    tiles = [[NSMutableArray alloc] init];
    NSMutableArray *names = [NSMutableArray arrayWithObject:[NSNull null]];
    [names addObjectsFromArray:YZAlternateIconNames()];
    for (id name in names) {
        YZIconTile *tile = [[[YZIconTile alloc] initWithName:name == [NSNull null] ? nil : name] autorelease];
        [tile addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:tile];
        [tiles addObject:tile];
    }
    return self;
}

- (void)showNote:(NSString *)text enabled:(BOOL)enabled position:(YZPosition)place {
    position = place;
    if ([YZTheme isFlat]) {
        card.layer.contents = nil;
        card.backgroundColor = [YZTheme cardColor];
    } else {
        card.backgroundColor = [UIColor clearColor];
        [YZTheme stretchImage:YZCardImage(position, [YZTheme cardColor]) caps:YZGroupRadius onView:card];
    }
    title.font = [YZTheme systemFontOfSize:[YZTheme isFlat] ? 17 : 16];
    title.text = YZT(@"Значок приложения");
    title.textColor = [YZTheme textColor];
    note.text = text;
    note.textColor = [YZTheme subtleTextColor];
    card.userInteractionEnabled = enabled;
    for (YZIconTile *tile in tiles)
        tile.alpha = enabled ? 1 : 0.4f;
    [self refreshSelection];
    [self setNeedsLayout];
}

- (void)refreshSelection {
    NSString *current = YZAlternateIconName();
    for (YZIconTile *tile in tiles)
        [tile showSelected:(!tile->iconName && !current) || [tile->iconName isEqualToString:current]];
}

- (void)tapped:(YZIconTile *)tile {
    NSString *current = YZAlternateIconName();
    if ((!tile->iconName && !current) || [tile->iconName isEqualToString:current])
        return;
    if (choose)
        choose(tile->iconName);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width, height = self.contentView.bounds.size.height;
    BOOL flat = [YZTheme isFlat];
    // a row of the flat design runs the whole width with its hairlines, the others are cards
    card.frame = flat ? CGRectMake(0, 0, width, height) : CGRectMake(16, 1, width - 32, height - 2);
    CGFloat cw = card.bounds.size.width, side = flat ? 15 : 16;
    if (!lineAbove) {
        lineAbove = [[UIView alloc] initWithFrame:CGRectZero];
        lineBelow = [[UIView alloc] initWithFrame:CGRectZero];
        [card addSubview:lineAbove];
        [card addSubview:lineBelow];
    }
    lineAbove.hidden = lineBelow.hidden = !flat;
    if (flat) {
        CGFloat line = 1.0f / [[UIScreen mainScreen] scale];
        lineAbove.frame = CGRectMake(0, 0, cw, line);
        lineBelow.frame = CGRectMake(0, height - line, cw, line);
        lineAbove.backgroundColor = lineBelow.backgroundColor = [YZTheme separatorColor];
    }
    title.frame = CGRectMake(side, 14, cw - 2 * side, 22);
    CGFloat x = side - (YZIconTileWidth - YZIconTileSide) / 2;
    for (YZIconTile *tile in tiles) {
        tile.frame = CGRectMake(x, YZIconTilesHead, YZIconTileWidth, YZIconTileSide + 28);
        x += YZIconTileWidth;
    }
    CGFloat noteHeight = YZMeasureHeight(note.text, note.font, cw - 32);
    note.frame = noteHeight > 0 ? CGRectMake(side, YZIconTilesHead + YZIconTileSide + 28 + 4, cw - 2 * side, noteHeight) : CGRectZero;
}

- (void)dealloc {
    [lineAbove release];
    [lineBelow release];
    [card release];
    [title release];
    [note release];
    [tiles release];
    [choose release];
    [super dealloc];
}
@end

static YZPosition YZPositionOf(NSInteger row, NSInteger count) {
    if (count == 1)
        return YZPositionSingle;
    if (row == 0)
        return YZPositionFirst;
    return row == count - 1 ? YZPositionLast : YZPositionMiddle;
}

// a color between two others, t from 0 (the first) to 1 (the second)
static UIColor *YZMixColors(UIColor *first, UIColor *second, CGFloat t) {
    CGFloat a[4] = { 0, 0, 0, 1 }, b[4] = { 0, 0, 0, 1 };
    [first getRed:&a[0] green:&a[1] blue:&a[2] alpha:&a[3]];
    [second getRed:&b[0] green:&b[1] blue:&b[2] alpha:&b[3]];
    return [UIColor colorWithRed:a[0] + (b[0] - a[0]) * t green:a[1] + (b[1] - a[1]) * t blue:a[2] + (b[2] - a[2]) * t alpha:1];
}

// the accent screen: the editor and a button back to the palette purple. a color is taken when a track is let
// go, a chip picked or the digits finished, and the app follows through the changed block
@interface YZAccentController : UIViewController {
    UIScrollView *_scroll;
    UIControl<YZTintControl> *_editor;
    UIButton *_reset;
    // the name of the screen, set in the bar next to the back arrow
    NSString *_heading;
    // the private accent screen shows the private palette whatever the session is, the disc morphs and a glow
    // of the accent lies behind the title
    BOOL _private;
    CAGradientLayer *_glow;
    void (^_changed)(void);
}
- (id)initWithChanged:(void (^)(void))changed;
- (id)initPrivateWithChanged:(void (^)(void))changed;
@end

@implementation YZAccentController
- (id)initWithChanged:(void (^)(void))changed {
    self = [super initWithNibName:nil bundle:nil];
    if (!self)
        return nil;
    _heading = [YZT(@"Цвет акцента") copy];
    _changed = [changed copy];
    return self;
}

- (id)initPrivateWithChanged:(void (^)(void))changed {
    self = [self initWithChanged:changed];
    if (!self)
        return nil;
    _private = YES;
    [_heading release];
    _heading = [YZT(@"Акцент приватной вкладки") copy];
    return self;
}

// the editor shows the accent in use, the purple of the palette when none is chosen
- (void)loadAccent {
    // the private palette starts from its own purple, 269 degrees, and the normal one from the 286 of the app
    yozora_accent accent = { _private ? YOZORA_PRIVATE_PALETTE_HUE : YOZORA_ACCENT_PALETTE_HUE, YOZORA_ACCENT_PALETTE_SATURATION, 1 };
    if (_private)
        [YZSettings customPrivateAccent:&accent];
    else
        [YZSettings customAccent:&accent];
    _editor.hue = accent.hue;
    _editor.saturation = accent.saturation;
    _editor.brightness = accent.brightness;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_scroll];
    // ios 5 and 6: the view reaches under the bar (later systems do it for a clear bar by themselves)
    if ([self respondsToSelector:NSSelectorFromString(@"setWantsFullScreenLayout:")])
        [self setValue:[NSNumber numberWithBool:YES] forKey:@"wantsFullScreenLayout"];
    // the classic design has its own picker: a square of colors with discs of metal. a design chosen later shows at the next visit of this screen
    _editor = [YZTheme isClassic] ? (UIControl<YZTintControl> *)[[YZTintPicker alloc] initWithFrame:CGRectZero] : (UIControl<YZTintControl> *)[[YZAccentEditor alloc] initWithFrame:CGRectZero];
    // both accent screens look the same: gradient ground, clear bar, gradient card, the morphing ball. the
    // private one adds its palette and its own stored color
    _editor.morphing = YES;
    [self loadAccent];
    [_editor addTarget:self action:@selector(commit) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:_editor];
    _reset = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    [_reset setTitle:YZT(@"Фиолетовый по умолчанию") forState:UIControlStateNormal];
    _reset.titleLabel.font = [YZTheme boldSystemFontOfSize:16];
    _reset.layer.cornerRadius = 24;
    [_reset addTarget:self action:@selector(resetAccent) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:_reset];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardShown:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardHidden:) name:UIKeyboardWillHideNotification object:nil];
    [self restyle];
}

// the colors of the screen come from the accent that was just taken
- (void)restyle {
    self.view.backgroundColor = [YZTheme screenColor];
    {
        // the whole ground is one gradient: the accent mixed into the private ground at the top, the private
        // ground in the middle, darker below. it runs under the clear status strip and bar so no part is a
        // flat color
        if (!_glow) {
            _glow = [[CAGradientLayer alloc] init];
            [self.view.layer insertSublayer:_glow atIndex:0];
        }
        UIColor *base = [YZTheme surfaceColor], *accent = [YZTheme accentColor];
        // the accent runs through the whole screen, deepest at the top left and fading to the dark of the private ground at the bottom right
        _glow.startPoint = CGPointMake(0, 0);
        _glow.endPoint = CGPointMake(0.85f, 1);
        // a dark ground deepens toward black at the bottom, a light one toward a pale touch of the accent
        UIColor *bottom = [YZTheme isDark] ? YZMixColors(base, [UIColor blackColor], 0.55f) : YZMixColors(base, accent, 0.07f);
        _glow.colors = [NSArray arrayWithObjects:(id)YZMixColors(base, accent, [YZTheme isDark] ? 0.8f : 0.5f).CGColor,
                        (id)YZMixColors(base, accent, [YZTheme isDark] ? 0.45f : 0.28f).CGColor, (id)YZMixColors(base, accent, 0.16f).CGColor, (id)bottom.CGColor, nil];
        _glow.locations = [NSArray arrayWithObjects:[NSNumber numberWithFloat:0], [NSNumber numberWithFloat:0.3f], [NSNumber numberWithFloat:0.65f], [NSNumber numberWithFloat:1], nil];
        _glow.frame = self.view.bounds;
        // the classic screen is the grouped ground of the system under the bar of the system, without the accent gradient
        _glow.hidden = [YZTheme isClassic];
        if ([YZTheme isClassic])
            self.view.backgroundColor = [YZTheme screenColor];
        YZPaintBehindScreens(self.navigationController);
        _scroll.backgroundColor = [UIColor clearColor];
        [YZTheme styleTransparentNavigationBar:self.navigationController.navigationBar];
    }
    if ([YZTheme isClassic]) {
        [YZClassic styleKey:_reset color:[YZClassic barMidColor] radius:9 modernRadius:24];
    } else {
        [_reset setBackgroundImage:nil forState:UIControlStateNormal];
        [_reset setBackgroundImage:nil forState:UIControlStateHighlighted];
        _reset.layer.cornerRadius = 24;
        _reset.backgroundColor = [YZTheme cardColor];
        [_reset setTitleColor:[YZTheme accentColor] forState:UIControlStateNormal];
    }
    [_editor applyTheme];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [YZCrash note:[NSString stringWithFormat:@"screen %@", NSStringFromClass([self class])]];
    // the private palette is on for as long as this screen is, the settings list restyles itself when it comes back
    if (_private)
        [YZTheme setPrivatePalettePreview:YES];
    YZInstallBarTitle(self, _heading, self, @selector(back));
    [self restyle];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (_private)
        [YZTheme setPrivatePalettePreview:NO];
}

// the private palette goes off before the pop starts, the settings behind restyle while this screen still
// slides away and took the private colors for a moment
- (void)back {
    if (_private)
        [YZTheme setPrivatePalettePreview:NO];
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = MIN((CGFloat)480, _scroll.bounds.size.width);
    CGFloat x = floor((_scroll.bounds.size.width - width) / 2);
    // the screen reaches under the bar, so its content starts below it
    CGFloat inset = [YZTheme barOverlap:self.navigationController.navigationBar];
    CGFloat top = inset + 8;
    YZInstallBarTitle(self, _heading, self, @selector(back));
    _glow.frame = self.view.bounds;
    _editor.frame = CGRectMake(x, top, width, _editor.preferredHeight);
    _reset.frame = CGRectMake(x + 16, top + _editor.preferredHeight + 8, width - 32, 48);
    _scroll.contentSize = CGSizeMake(_scroll.bounds.size.width, top + _editor.preferredHeight + 72);
}

- (void)commit {
    yozora_accent accent = { _editor.hue, _editor.saturation, _editor.brightness };
    if (_private)
        [YZSettings setCustomPrivateAccent:accent];
    else
        [YZSettings setCustomAccent:accent];
    [self applied];
}

- (void)resetAccent {
    if (_private)
        [YZSettings resetPrivateAccent];
    else
        [YZSettings resetAccent];
    [self loadAccent];
    [YZTheme animateFeedbackOfView:_reset];
    [self applied];
}

- (void)applied {
    // the settings behind and the browser restyle in the palette of the session, not the private one this
    // screen shows
    if (_private)
        [YZTheme setPrivatePalettePreview:NO];
    if (_changed)
        _changed();
    if (_private)
        [YZTheme setPrivatePalettePreview:YES];
    [self restyle];
    [self.view setNeedsLayout];
}

- (void)keyboardShown:(NSNotification *)note {
    CGRect frame = [[[note userInfo] objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect keyboard = [self.view convertRect:frame fromView:nil];
    CGFloat overlap = MAX((CGFloat)0, CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(keyboard));
    _scroll.contentInset = UIEdgeInsetsMake(0, 0, overlap, 0);
    _scroll.scrollIndicatorInsets = _scroll.contentInset;
    [_scroll scrollRectToVisible:[_editor convertRect:_editor.editingRect toView:_scroll] animated:YES];
}

- (void)keyboardHidden:(NSNotification *)note {
    (void)note;
    _scroll.contentInset = UIEdgeInsetsZero;
    _scroll.scrollIndicatorInsets = UIEdgeInsetsZero;
}

- (void)dealloc {
    [YZCrash noteLifecycle:@"dealloc" object:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_scroll release];
    [_editor release];
    [_reset release];
    [_heading release];
    [_glow removeFromSuperlayer];
    [_glow release];
    [_changed release];
    [super dealloc];
}
@end

// the text size screen: a sample card, a track of the percent and a button back to 100. the browser and
// settings take the size when the finger leaves the track
@interface YZTextSizeController : UIViewController {
    UIScrollView *_scroll;
    UIView *_card;
    UILabel *_value;
    UILabel *_sample;
    YZAccentTrack *_track;
    UILabel *_low;
    UILabel *_high;
    UIButton *_reset;
    YZBarFill *_fill;
    NSInteger _percent;
    void (^_changed)(void);
}
- (id)initWithChanged:(void (^)(void))changed;
@end

@interface YZBackgroundController : UIViewController <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIPopoverControllerDelegate> {
    YZBackgroundPreview *_preview;
    YZStore *_store;
    UIView *_card;
    UIButton *_backKey;
    UILabel *_value;
    YZAccentTrack *_track;
    UIButton *_choose;
    UIButton *_remove;
    UIPopoverController *_popover;
    NSInteger _percent;
    NSInteger _shownStamp;
    BOOL _storing;
    void (^_changed)(void);
}
- (id)initWithStore:(YZStore *)store changed:(void (^)(void))changed;
@end

@interface YZAboutController : UITableViewController {
    YZBarFill *_barFill;
    UIImageView *_hero;
    CGFloat _heroWidth;
    void (^_openAddress)(NSString *);
}
// the settings screen answers with a tab of Yozora, so a link of this screen does not leave for Safari
@property (nonatomic, copy) void (^openAddress)(NSString *address);
@end

// sections fold: the developer one starts folded, the choice is kept between visits. a section is told by its
// place, the names change with the language
// the handles of the people who tested the builds, the same list as the about screen of Senko
static NSString *const YZAboutTesters =
    @"@menstry, @kfrom7, @Lineysom, @inraxx, @LimeDev, @shizotoaster, "
    @"@xaxaxaxaxxaxaxaxaxaxaxaxaxaxa, @fly1ngangel, @CookieValerka, @Siqvw, "
    @"@rakamaqfo, @s3dativee, @appIebionic, @merwleem, @libertea, @not_a_modder";

static NSString *const YZCollapsedSectionsKey = @"yozora.settings.collapsed";
static const NSInteger YZDeveloperSection = 3;

static BOOL YZSectionCollapsed(NSInteger section) {
    NSDictionary *stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:YZCollapsedSectionsKey];
    NSNumber *value = [stored objectForKey:[NSString stringWithFormat:@"%ld", (long)section]];
    return value ? [value boolValue] : section == YZDeveloperSection;
}

static void YZSetSectionCollapsed(NSInteger section, BOOL collapsed) {
    NSMutableDictionary *stored = [NSMutableDictionary dictionaryWithDictionary:[[NSUserDefaults standardUserDefaults] dictionaryForKey:YZCollapsedSectionsKey]];
    [stored setObject:[NSNumber numberWithBool:collapsed] forKey:[NSString stringWithFormat:@"%ld", (long)section]];
    [[NSUserDefaults standardUserDefaults] setObject:stored forKey:YZCollapsedSectionsKey];
}

// the marks of the choice screens are drawn here and clipped to a Material shape of YZShape, as the avatar of exteria is
static void YZBeginMark(CGFloat side, UIBezierPath **shape, YZShape kind) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, 0);
    // the old system has no Material shapes: a mark is a rounded square, the shape of an icon of its home screen
    *shape = [YZTheme isClassic] ? [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side) cornerRadius:side * 0.22f] : YZShapePath(kind, side);
    CGContextSaveGState(UIGraphicsGetCurrentContext());
    [*shape addClip];
}

static UIImage *YZEndMark(UIBezierPath *shape) {
    // the clip is undone so the hairline outline is not cut at its outer half
    CGContextRestoreGState(UIGraphicsGetCurrentContext());
    [[UIColor colorWithWhite:0 alpha:0.16f] setStroke];
    shape.lineWidth = 1;
    [shape stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static UIColor *YZHex(unsigned rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 255) / 255.0f green:((rgb >> 8) & 255) / 255.0f blue:(rgb & 255) / 255.0f alpha:1];
}

// the options are in YZLanguage order and use their own language names
static NSArray *YZLanguageNames(void) {
    return [NSArray arrayWithObjects:@"Русский", @"English", @"日本語", nil];
}

static NSString *YZMascotTitle(YZMascot mascot) {
    switch (mascot) {
    case YZMascotFox: return @"Yozora (Fox)";
    case YZMascotSenko: return @"Senko";
    default: return @"Yozora";
    }
}

// the sticker of a mascot as it is, fitted into a square, for the picker: its outline is its own shape
static UIImage *YZMascotMark(YZMascot mascot, CGFloat side) {
    UIImage *picture = [YZTheme mascotImage:@"sticker" mascot:mascot];
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, 0);
    [picture drawInRect:CGRectMake(0, 0, side, side)];
    UIImage *mark = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return mark;
}

static UIImage *YZFlagMark(YZLanguage language, CGFloat side) {
    UIBezierPath *shape = nil;
    // the sun shape for the country of the rising sun, the flower for the union jack, the cookie for the bands
    YZShape kind = language == YZLanguageEnglish ? YZShapeFlower : (language == YZLanguageJapanese ? YZShapeSunny : YZShapeCookie);
    YZBeginMark(side, &shape, kind);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (language == YZLanguageJapanese) {
        // the disc is three fifths of the height, as the flag is made, and a little lighter at the top left
        [[UIColor whiteColor] setFill];
        CGContextFillRect(ctx, CGRectMake(0, 0, side, side));
        CGRect disc = CGRectMake(side * 0.2f, side * 0.2f, side * 0.6f, side * 0.6f);
        CGContextSaveGState(ctx);
        CGContextAddEllipseInRect(ctx, disc);
        CGContextClip(ctx);
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        const CGFloat colors[8] = { 0.835f, 0.0f, 0.2f, 1.0f, 0.737f, 0.0f, 0.176f, 1.0f };
        CGGradientRef gradient = CGGradientCreateWithColorComponents(space, colors, NULL, 2);
        if ([YZTheme isClassic]) {
            // a plain red disc, as the flag is
            [YZHex(0xBC002D) setFill];
            CGContextFillRect(ctx, disc);
        } else
            CGContextDrawLinearGradient(ctx, gradient, disc.origin, CGPointMake(CGRectGetMaxX(disc), CGRectGetMaxY(disc)), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
        CGContextRestoreGState(ctx);
    } else if (language == YZLanguageRussian) {
        [[UIColor whiteColor] setFill];
        CGContextFillRect(ctx, CGRectMake(0, 0, side, side / 3));
        [YZHex(0x0039A6) setFill];
        CGContextFillRect(ctx, CGRectMake(0, side / 3, side, side / 3));
        [YZHex(0xD52B1E) setFill];
        CGContextFillRect(ctx, CGRectMake(0, 2 * side / 3, side, side / 3 + 1));
    } else {
        [YZHex(0x012169) setFill];
        CGContextFillRect(ctx, CGRectMake(0, 0, side, side));
        [[UIColor whiteColor] setStroke];
        CGContextSetLineWidth(ctx, side * 0.2f);
        CGContextMoveToPoint(ctx, 0, 0);
        CGContextAddLineToPoint(ctx, side, side);
        CGContextMoveToPoint(ctx, side, 0);
        CGContextAddLineToPoint(ctx, 0, side);
        CGContextStrokePath(ctx);
        [YZHex(0xC8102E) setStroke];
        CGContextSetLineWidth(ctx, side * 0.07f);
        CGContextMoveToPoint(ctx, 0, 0);
        CGContextAddLineToPoint(ctx, side, side);
        CGContextMoveToPoint(ctx, side, 0);
        CGContextAddLineToPoint(ctx, 0, side);
        CGContextStrokePath(ctx);
        [[UIColor whiteColor] setFill];
        CGContextFillRect(ctx, CGRectMake(side * 0.33f, 0, side * 0.34f, side));
        CGContextFillRect(ctx, CGRectMake(0, side * 0.33f, side, side * 0.34f));
        [YZHex(0xC8102E) setFill];
        CGContextFillRect(ctx, CGRectMake(side * 0.4f, 0, side * 0.2f, side));
        CGContextFillRect(ctx, CGRectMake(0, side * 0.4f, side, side * 0.2f));
    }
    return YZEndMark(shape);
}

// what a theme looks like: its ground, a card with two lines of text and the accent as a dot, in the three
// themes' own colors whatever theme is on
static UIImage *YZThemeMark(YZThemeKind kind, UIColor *accent, CGFloat side) {
    UIColor *ground, *card, *lines;
    switch (kind) {
    case YZThemeDark: ground = YZHex(0x1e1a2b); card = YZHex(0x2f2a44); lines = YZHex(0xc9c3dd); break;
    case YZThemeBlack: ground = YZHex(0x000000); card = YZHex(0x1c1c1e); lines = YZHex(0x98989d); break;
    default: ground = YZHex(0xfbf8ff); card = YZHex(0xe9e1f5); lines = YZHex(0x655a7a); break;
    }
    UIBezierPath *shape = nil;
    YZBeginMark(side, &shape, YZShapeSunny);
    [ground setFill];
    CGContextFillRect(UIGraphicsGetCurrentContext(), CGRectMake(0, 0, side, side));
    if ([YZTheme isClassic]) {
        // simpler: the ground, a card on it and one line of text, no accent dot
        [card setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(side * 0.18f, side * 0.3f, side * 0.64f, side * 0.4f) cornerRadius:side * 0.08f] fill];
        [lines setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(side * 0.3f, side * 0.46f, side * 0.4f, side * 0.07f) cornerRadius:side * 0.035f] fill];
        return YZEndMark(shape);
    }
    [accent setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(side * 0.5f - side * 0.09f, side * 0.18f, side * 0.18f, side * 0.18f)] fill];
    [card setFill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(side * 0.2f, side * 0.44f, side * 0.6f, side * 0.34f) cornerRadius:side * 0.1f] fill];
    [lines setFill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(side * 0.3f, side * 0.53f, side * 0.4f, side * 0.05f) cornerRadius:side * 0.025f] fill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(side * 0.3f, side * 0.64f, side * 0.26f, side * 0.05f) cornerRadius:side * 0.025f] fill];
    return YZEndMark(shape);
}

// the address each engine answers at, under its name
static NSArray *YZEngineAddresses(void) {
    return [NSArray arrayWithObjects:@"https://www.google.com", @"https://duckduckgo.com", @"https://yandex.ru", nil];
}

// the color of each brand, which tints the chosen engine's plate
static NSArray *YZEngineTints(void) {
    return [NSArray arrayWithObjects:YZHex(0x4285f4), YZHex(0xde5833), YZHex(0xfc3f1d), nil];
}

@implementation YZSettingsController
@synthesize settingsDelegate = _settingsDelegate;

- (id)initWithStore:(YZStore *)store {
    self = [super initWithStyle:UITableViewStylePlain];
    if (!self)
        return nil;
    _store = [store retain];
    return self;
}

- (void)dealloc {
    [YZCrash noteLifecycle:@"dealloc" object:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    YZShapeSetMorphPaused(NO);
    [_barFill removeFromSuperview];
    [_barFill release];
    [_store release];
    [_sections release];
    [_jitText release];
    [super dealloc];
}

#pragma mark content

- (NSArray *)generalSection:(NSNumber *(^)(YZRow))row {
    NSMutableArray *section = [NSMutableArray arrayWithObjects:YZT(@"Основные"), row(YZRowLanguage), row(YZRowTheme), nil];
    [section addObject:row(YZRowDesign)];
    [section addObjectsFromArray:[NSArray arrayWithObjects:row(YZRowAccent), row(YZRowPrivateAccent), row(YZRowMascot), row(YZRowMascotGlow), row(YZRowBackground), row(YZRowSearchEngine), row(YZRowTabsLayout), row(YZRowTextSize), row(YZRowAppIcons), nil]];
    return section;
}

- (NSArray *)buildSections {
    NSNumber *(^row)(YZRow) = ^(YZRow kind) { return [NSNumber numberWithInt:kind]; };
    return [NSArray arrayWithObjects:
        [self generalSection:row],
        [NSArray arrayWithObjects:YZT(@"Приватность и безопасность"), row(YZRowBlockTrackers), row(YZRowAdblockRules), row(YZRowSitePermissions), row(YZRowDns), row(YZRowCertificates), row(YZRowBlockThirdPartyCookies),
         row(YZRowSaveHistory), row(YZRowClearHistory), row(YZRowClearSiteData), nil],
        [NSArray arrayWithObjects:YZT(@"Страницы"), row(YZRowJavascript), row(YZRowEconomy), row(YZRowReduceMotion), row(YZRowWebFonts), nil],
        [NSArray arrayWithObjects:YZT(@"Для разработчиков"), row(YZRowDebug), row(YZRowLogging), row(YZRowLogOpen), row(YZRowZombies), row(YZRowUnlockDesigns), row(YZRowJit), row(YZRowJitState), YZMetalRows nil],
        [NSArray arrayWithObjects:YZT(@"О программе"), row(YZRowUpdate), row(YZRowAbout), nil],
        nil];
}

- (void)refresh {
    [YZCrash note:@"settings: refresh"];
    YZInstallBarTitle(self, YZT(@"Настройки"), self, @selector(finish));
    [_sections release];
    _sections = [[self buildSections] retain];
    [_jitText release];
    _jitText = [[self jitStateText] retain];
    YZStyleTable(self);
    [self styleBar];
    self.tableView.tableHeaderView = nil;
    [self.tableView reloadData];
}

#pragma mark bar over the list

// the list runs under the bar: the fill behind the bar is the solid ground at the top of the list and the
// blur of what is under it once the list has gone by
- (void)styleBar {
    if (!self.navigationController.navigationBar)
        return;
    [YZTheme styleTransparentNavigationBar:self.navigationController.navigationBar];
    if (!_barFill)
        _barFill = [[YZBarFill alloc] initWithFrame:CGRectZero];
    [_barFill applyTheme];
    [_barFill attachToScrollView:self.tableView controller:self];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [_barFill attachToScrollView:scrollView controller:self];
}

// ios 5 and 6 put the list below the bar unless the controller asks for the whole screen, then the bar inset
// is the controller's. it runs on every scroll step, so it touches the bar and fill only when the bar or the
// list width changed
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UINavigationBar *bar = self.navigationController.navigationBar;
    BOOL moved = NO;
    if (bar && [[[UIDevice currentDevice] systemVersion] floatValue] < 7.0f) {
        CGFloat top = [YZTheme barOverlap:bar];
        UIEdgeInsets inset = self.tableView.contentInset;
        if (fabs(inset.top - top) > 0.5) {
            BOOL atTop = self.tableView.contentOffset.y <= -inset.top + 1;
            inset.top = top;
            self.tableView.contentInset = inset;
            self.tableView.scrollIndicatorInsets = inset;
            if (atTop)
                self.tableView.contentOffset = CGPointMake(0, -top);
            moved = YES;
        }
    }
    CGFloat width = self.tableView.bounds.size.width;
    if (fabs(width - _layoutWidth) > 0.5) {
        _layoutWidth = width;
        moved = YES;
    }
    if (moved) {
        YZInstallBarTitle(self, YZT(@"Настройки"), self, @selector(finish));
        [_barFill attachToScrollView:self.tableView controller:self];
    }
}

// the balls of the accent rows hold still while the list is dragged or coasts, and go on when it rests
- (void)setBallsMoving:(BOOL)moving {
    YZShapeSetMorphPaused(!moving);
    for (UITableViewCell *cell in [self.tableView visibleCells]) {
        if ([cell isKindOfClass:[YZSettingsCell class]])
            [((YZSettingsCell *)cell)->ball sync];
    }
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView { [self setBallsMoving:NO]; }

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate)
        [self setBallsMoving:YES];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView { [self setBallsMoving:YES]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    // ios 5 and 6: the table reaches under the bar
    if ([self respondsToSelector:NSSelectorFromString(@"setWantsFullScreenLayout:")])
        [self setValue:[NSNumber numberWithBool:YES] forKey:@"wantsFullScreenLayout"];
    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [YZCrash note:[NSString stringWithFormat:@"screen %@", NSStringFromClass([self class])]];
    [self refresh];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [YZCrash noteLifecycle:@"disappear" object:self];
    // a screen left in the middle of a drag must not leave the balls of the next one stopped
    YZShapeSetMorphPaused(NO);
}

- (void)finish {
    [YZCrash note:@"settings: closing"];
    [_settingsDelegate settingsControllerDidFinish:self];
}

- (void)changed {
    [YZCrash note:@"settings: changed"];
    [self refresh];
    [_settingsDelegate settingsControllerDidChange:self];
}

#pragma mark app icon

// why the picker is dimmed, empty where the choice works
- (NSString *)iconNote {
    return YZAppIconCurrentMode() == YZAppIconUnavailable ? YZT(@"Значок меняется на iOS 10.3 и новее или на джейлбрейке, где приложению можно записывать в свой пакет") : nil;
}

- (UITableViewCell *)iconTilesCellForTable:(UITableView *)table path:(NSIndexPath *)path {
    YZIconTilesCell *cell = (YZIconTilesCell *)[table dequeueReusableCellWithIdentifier:@"YZIconTiles"];
    if (!cell)
        cell = [[[YZIconTilesCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"YZIconTiles"] autorelease];
    YZSettingsController *me = self;
    [cell->choose release];
    cell->choose = [^(NSString *name) { [me chooseIcon:name]; } copy];
    [cell showNote:[self iconNote] enabled:YZAppIconCurrentMode() != YZAppIconUnavailable
          position:YZPositionOf(path.row - 1, (NSInteger)[[_sections objectAtIndex:path.section] count] - 1)];
    return cell;
}

- (void)refreshIconTiles {
    for (UITableViewCell *cell in [self.tableView visibleCells]) {
        if ([cell isKindOfClass:[YZIconTilesCell class]])
            [(YZIconTilesCell *)cell refreshSelection];
    }
}

// the screen is covered while the change runs: before ios 10.3 it ends with SpringBoard starting again, which
// takes the app with it
- (UIView *)showIconBusy {
    UIView *host = [self dialogHost];
    UIView *cover = [[[UIView alloc] initWithFrame:host.bounds] autorelease];
    cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    cover.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35f];
    UIActivityIndicatorView *spinner = [[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge] autorelease];
    spinner.center = CGPointMake(host.bounds.size.width / 2, host.bounds.size.height / 2);
    spinner.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [spinner startAnimating];
    [cover addSubview:spinner];
    [host addSubview:cover];
    return cover;
}

- (void)chooseIcon:(NSString *)name {
    YZSettingsController *me = self;
    if (YZAppIconCurrentMode() != YZAppIconRewrite) {
        [self changeIconTo:name];
        return;
    }
    YZDialog *dialog = [YZDialog dialogWithTitle:YZT(@"Сменить значок?") message:YZT(@"Значок поменяется после перезапуска SpringBoard: экран мигнёт и приложение закроется")
                                     cancelTitle:YZT(@"Отмена") confirmTitle:YZT(@"Сменить") destructive:NO handler:^(NSInteger index, NSArray *texts) {
        (void)texts;
        if (index == 1)
            [me changeIconTo:name];
    }];
    [dialog showInView:[self dialogHost]];
}

- (void)changeIconTo:(NSString *)name {
    YZSettingsController *me = self;
    YZAppIconMode mode = YZAppIconCurrentMode();
    UIView *busy = [self showIconBusy];
    YZSetAlternateIcon(name, ^(NSError *error) {
        [busy removeFromSuperview];
        [me refreshIconTiles];
        if (!error)
            return;
        NSLog(@"yozora: the app icon was not changed: %@", error);
        NSString *detail = [NSString stringWithFormat:@"%@\n\n%@ (%@ %ld)", YZT(@"Не удалось сменить значок"), [error localizedDescription], [error domain], (long)[error code]];
        // the call of ios 10.3 refused, and the bundle can be written: the old way is offered
        if (mode == YZAppIconNative && YZAppIconCanRewrite()) {
            YZDialog *ask = [YZDialog dialogWithTitle:YZT(@"Сменить значок?") message:[detail stringByAppendingFormat:@"\n\n%@", YZT(@"Значок поменяется после перезапуска SpringBoard: экран мигнёт и приложение закроется")]
                                          cancelTitle:YZT(@"Отмена") confirmTitle:YZT(@"Сменить") destructive:NO handler:^(NSInteger index, NSArray *texts) {
                (void)texts;
                if (index != 1)
                    return;
                UIView *again = [me showIconBusy];
                YZRewriteAppIcon(name, ^(NSError *rewriteError) {
                    [again removeFromSuperview];
                    [me refreshIconTiles];
                    if (rewriteError)
                        [me showIconError:[rewriteError localizedDescription]];
                });
            }];
            [ask showInView:[me dialogHost]];
            return;
        }
        [me showIconError:detail];
    });
}

- (void)showIconError:(NSString *)text {
    YZDialog *dialog = [YZDialog dialogWithTitle:YZT(@"Ошибка") message:text cancelTitle:nil confirmTitle:YZT(@"Готово") destructive:NO handler:nil];
    [dialog showInView:[self dialogHost]];
}

#pragma mark values

- (NSString *)languageName { return [YZLanguageNames() objectAtIndex:[YZSettings language]]; }

// the hex digits of the chosen accent, or the word for the purple of the palette
- (NSString *)accentName {
    yozora_accent accent;
    if (![YZSettings customAccent:&accent])
        return YZT(@"Фиолетовый по умолчанию");
    char hex[7];
    yozora_accent_hex(&accent, hex);
    return [NSString stringWithFormat:@"#%s", hex];
}

- (NSString *)privateAccentName {
    yozora_accent accent;
    if (![YZSettings customPrivateAccent:&accent])
        return YZT(@"Фиолетовый по умолчанию");
    char hex[7];
    yozora_accent_hex(&accent, hex);
    return [NSString stringWithFormat:@"#%s", hex];
}

// what the jit is doing in this run, from what JavaScriptCore reports after it started, and whether the setting waits for a restart
- (NSString *)jitStateText {
    yozora_jit_info info;
    yozora_jit_info_read(&info);
    NSString *state;
    if (!info.compiled)
        state = YZT(@"В этой сборке JIT нет, скрипты идут в интерпретаторе");
    else if (info.forced_off)
        state = YZT(@"Выключен переменной YOZORA_NO_JIT, скрипты идут в интерпретаторе");
    else if (!info.requested)
        state = YZT(@"Выключен, скрипты идут в интерпретаторе");
    else if (!info.active)
        state = YZT(@"Система не дала исполняемую память, JIT не работает");
    else {
        NSMutableArray *tiers = [NSMutableArray arrayWithObject:@"Baseline"];
        if (info.dfg)
            [tiers addObject:@"DFG"];
        if (info.ftl)
            [tiers addObject:@"FTL"];
        if (info.regexp)
            [tiers addObject:@"RegExp"];
        state = [NSString stringWithFormat:YZT(@"Работает: %@"), [tiers componentsJoinedByString:@" · "]];
        // the pool of compiled code: when it is full the functions that are left run in the interpreter, which nothing else shows
        if (info.pool_size)
            state = [state stringByAppendingFormat:YZT(@". Код: %.1f из %.0f МБ"), info.pool_used / 1048576.0, info.pool_size / 1048576.0];
    }
    if (([YZSettings jit] ? 1 : 0) != info.requested)
        state = [state stringByAppendingString:YZT(@". Изменение вступит в силу после перезапуска")];
    return state;
}

// the names of the mascots are names, they stay as they are in every language
// the server the pages are resolved through: the name of a known one, the host of another, or the system
- (NSString *)dnsName {
    char label[64];
    yozora_dns_label([[YZSettings dnsServer] UTF8String], label, sizeof label);
    return label[0] ? [NSString stringWithUTF8String:label] : YZT(@"Системный");
}

- (NSString *)mascotName {
    return YZMascotTitle([YZSettings mascot]);
}

- (NSString *)designName {
    switch ([YZSettings design]) {
    case YZDesignClassic: return YZT(@"Классическое");
    case YZDesignFlat: return YZT(@"Плоское");
    default: return YZT(@"Современное");
    }
}

- (NSString *)themeName {
    switch ([YZSettings theme]) {
    case YZThemeDark: return YZT(@"Тёмная");
    case YZThemeBlack: return YZT(@"Чёрная");
    default: return YZT(@"Светлая");
    }
}

// the engines in the order of yozora_search_engine: the name of each and the file of its mark
static NSArray *YZEngineNames(void) { return [NSArray arrayWithObjects:@"Google", @"DuckDuckGo", YZT(@"Яндекс"), nil]; }
// a mark missing from the bundle is an NSNull, arrayWithObjects: would stop at a nil and shorten the list
static NSArray *YZEngineLogos(void) {
    NSMutableArray *marks = [NSMutableArray array];
    for (NSString *name in [NSArray arrayWithObjects:@"google", @"duckduckgo", @"yandex", nil]) {
        UIImage *mark = [YZTheme logoNamed:name];
        [marks addObject:mark ? (id)mark : (id)[NSNull null]];
    }
    return marks;
}

- (NSString *)coreName { return [YZEngineNames() objectAtIndex:[YZSettings searchEngine]]; }

- (NSString *)titleForRow:(YZRow)kind {
    switch (kind) {
    case YZRowLanguage: return YZT(@"Язык");
    case YZRowTheme: return YZT(@"Тема");
    case YZRowDesign: return YZT(@"Оформление");
    case YZRowTabsLayout: return YZT(@"Вид вкладок");
    case YZRowMascotGlow: return YZT(@"Свечение маскота");
    case YZRowAccent: return YZT(@"Цвет акцента");
    case YZRowPrivateAccent: return YZT(@"Акцент приватной вкладки");
    case YZRowMascot: return YZT(@"Маскот");
    case YZRowBackground: return YZT(@"Фон");
    case YZRowSearchEngine: return YZT(@"Поисковая система");
    case YZRowTextSize: return YZT(@"Размер текста");
    case YZRowBlockTrackers: return YZT(@"Блокировать рекламу и трекеры");
    case YZRowAdblockRules: return YZT(@"Правила блокировщика");
    case YZRowSitePermissions: return YZT(@"Разрешения сайтов");
    case YZRowDns: return @"DNS";
    case YZRowCertificates: return YZT(@"Сертификаты");
    case YZRowBlockThirdPartyCookies: return YZT(@"Блокировать cookie сторонних сайтов");
    case YZRowSaveHistory: return YZT(@"Сохранять историю");
    case YZRowClearHistory: return YZT(@"Очистить историю");
    case YZRowClearSiteData: return YZT(@"Очистить данные сайтов");
    case YZRowJavascript: return @"JavaScript";
    case YZRowEconomy: return YZT(@"Экономная отрисовка");
    case YZRowReduceMotion: return YZT(@"Меньше анимаций");
    case YZRowHideBars: return YZT(@"Прятать адресную строку при прокрутке");
    case YZRowWebFonts: return YZT(@"Шрифты сайтов");
    case YZRowDebug: return YZT(@"Отладка");
    case YZRowLogging: return YZT(@"Логирование");
    case YZRowLogOpen: return YZT(@"Логи");
    case YZRowZombies: return YZT(@"Зомби-объекты");
    case YZRowUnlockDesigns: return YZT(@"Все оформления");
    case YZRowJit: return @"JIT";
    case YZRowJitState: return YZT(@"Состояние JIT");
    case YZRowMetal: return @"Metal";
    case YZRowUpdate: return YZT(@"Обновление");
    case YZRowAbout: return YZT(@"Об Yozora");
    // the row of the icon tiles has a title of its own inside its card
    case YZRowAppIcons: return @"";
    }
    return @"";
}

- (NSString *)detailForRow:(YZRow)kind {
    switch (kind) {
    case YZRowLanguage: return [self languageName];
    case YZRowTheme: return [self themeName];
    case YZRowDesign: return [self designName];
    case YZRowTabsLayout: return [YZSettings tabsLayout] == YZTabsLayoutPages ? YZT(@"Страницы") : YZT(@"Сетка");
    case YZRowAccent: return [self accentName];
    case YZRowPrivateAccent: return [self privateAccentName];
    case YZRowMascot: return [self mascotName];
    case YZRowBackground: return [YZBackground image] ? [NSString stringWithFormat:@"%d%%", (int)[YZSettings homeBackgroundBlur]] : YZT(@"Нет");
    case YZRowSearchEngine: return [self coreName];
    case YZRowTextSize: return [NSString stringWithFormat:@"%d%%", (int)[YZSettings textZoom]];
    case YZRowUpdate: {
        YZRelease *release = [YZUpdate cachedRelease];
        return [YZUpdate isNewer:release] ? [NSString stringWithFormat:YZT(@"Доступна %@"), release.tag] : [NSString stringWithFormat:YZT(@"Установлена %@"), [YZUpdate installedVersion]];
    }
    case YZRowAdblockRules: return YZT(@"Свои правила, как в списках Adblock Plus");
    case YZRowSitePermissions: return YZT(@"Место, уведомления и сайты без блокировщика");
    case YZRowDns: return [self dnsName];
    case YZRowCertificates: {
        NSUInteger count = [[YZCertificates entries] count];
        return count ? [NSString stringWithFormat:YZT(@"Свои корневые сертификаты: %lu"), (unsigned long)count] : YZT(@"Свои корневые сертификаты для сайтов и сетей");
    }
    case YZRowEconomy: return YZT(@"Страницы рисуются быстрее и мягче");
    case YZRowReduceMotion: return YZT(@"Сайты анимируют меньше и реже");
    case YZRowHideBars: return YZT(@"Страница занимает весь экран, адрес возвращается наверху страницы");
    case YZRowWebFonts: return YZT(@"Без них страницы грузятся быстрее");
    case YZRowDebug: return YZT(@"Нагрузка, память, трафик и fps в углу экрана");
    case YZRowLogging: return YZT(@"Копить журнал приложения и страниц");
    case YZRowLogOpen: return [YZLog capturing] ? YZT(@"Терминал с записями, захват идёт") : YZT(@"Терминал с записями, захват выключен");
    case YZRowZombies: return YZT(@"Называет класс освобождённого, но использованного объекта, нужен перезапуск и больше памяти");
    case YZRowUnlockDesigns: return YZT(@"Оформления, которых нет для этой версии iOS, возможны баги");
    case YZRowJit: return YZT(@"Нужен перезапуск приложения");
    case YZRowJitState: return _jitText ? _jitText : [self jitStateText];
    case YZRowMetal: return YZT(@"Плитки страниц рисует видеочип, выключите, если они мигают или не обновляются");
    default: return nil;
    }
}

- (YZIcon)glyphForRow:(YZRow)kind {
    switch (kind) {
    case YZRowLanguage: return YZIconLanguage;
    case YZRowTheme: return YZIconPalette;
    case YZRowDesign: return YZIconSwap;
    case YZRowTabsLayout: return YZIconTabs;
    case YZRowAccent: return YZIconPalette;
    case YZRowPrivateAccent: return YZIconBrush;
    case YZRowMascot: return YZIconImage;
    case YZRowBackground: return YZIconImage;
    case YZRowSearchEngine: return YZIconSearch;
    case YZRowTextSize: return YZIconTextSize;
    case YZRowBlockTrackers: return YZIconShield;
    case YZRowAdblockRules: return YZIconCode;
    case YZRowSitePermissions: return YZIconLink;
    case YZRowDns: return YZIconShield;
    case YZRowCertificates: return YZIconLock;
    case YZRowBlockThirdPartyCookies: return YZIconCookie;
    case YZRowSaveHistory: return YZIconHistory;
    case YZRowClearHistory: return YZIconDelete;
    case YZRowClearSiteData: return YZIconSweep;
    case YZRowJavascript: return YZIconCode;
    case YZRowEconomy: return YZIconSpeed;
    case YZRowMascotGlow: return YZIconBrush;
    case YZRowReduceMotion: return YZIconAnimation;
    case YZRowHideBars: return YZIconArrowDown;
    case YZRowWebFonts: return YZIconFont;
    case YZRowDebug: return YZIconBugReport;
    case YZRowLogging: return YZIconTerminal;
    case YZRowZombies: return YZIconBugReport;
    case YZRowUnlockDesigns: return YZIconSwap;
    case YZRowLogOpen: return YZIconReceiptLong;
    case YZRowJit: return YZIconBolt;
    case YZRowJitState: return YZIconMemory;
    case YZRowMetal: return YZIconBolt;
    case YZRowUpdate: return YZIconDownload;
    case YZRowAbout: return YZIconInfo;
    case YZRowAppIcons: return YZIconImage;
    }
    return YZIconInfo;
}

- (BOOL)isSwitch:(YZRow)kind {
    return kind == YZRowBlockTrackers || kind == YZRowBlockThirdPartyCookies || kind == YZRowSaveHistory
        || kind == YZRowJavascript || kind == YZRowEconomy || kind == YZRowMascotGlow || kind == YZRowReduceMotion || kind == YZRowWebFonts
        || kind == YZRowDebug || kind == YZRowLogging || kind == YZRowZombies || kind == YZRowUnlockDesigns || kind == YZRowJit || kind == YZRowMetal;
}

- (BOOL)switchValue:(YZRow)kind {
    switch (kind) {
    case YZRowBlockTrackers: return [YZSettings blockTrackers];
    case YZRowBlockThirdPartyCookies: return [YZSettings blockThirdPartyCookies];
    case YZRowSaveHistory: return [YZSettings saveHistory];
    case YZRowJavascript: return [YZSettings javascript];
    case YZRowEconomy: return [YZSettings economyRaster];
    case YZRowMascotGlow: return [YZSettings mascotGlow];
    case YZRowReduceMotion: return [YZSettings reduceMotion];
    case YZRowHideBars: return [YZSettings hideBarsOnScroll];
    case YZRowWebFonts: return [YZSettings webFonts];
    case YZRowDebug: return [YZSettings debugOverlay];
    case YZRowLogging: return [YZSettings logging];
    case YZRowZombies: return [YZSettings zombies];
    case YZRowUnlockDesigns: return [YZSettings unlockAllDesigns];
    case YZRowJit: return [YZSettings jit];
    case YZRowMetal: return [YZSettings metal];
    default: return NO;
    }
}

- (void)switchChanged:(YZToggle *)toggle {
    BOOL on = toggle.on;
    switch ((YZRow)toggle.tag) {
    case YZRowBlockTrackers: [YZSettings setBlockTrackers:on]; break;
    case YZRowBlockThirdPartyCookies: [YZSettings setBlockThirdPartyCookies:on]; break;
    case YZRowSaveHistory: [YZSettings setSaveHistory:on]; break;
    case YZRowJavascript: [YZSettings setJavascript:on]; break;
    case YZRowEconomy: [YZSettings setEconomyRaster:on]; break;
    case YZRowMascotGlow:
        [YZSettings setMascotGlow:on];
        // the start page takes the glow away or brings it back
        [_settingsDelegate settingsControllerDidChange:self];
        break;
    case YZRowReduceMotion: [YZSettings setReduceMotion:on]; break;
    case YZRowHideBars: [YZSettings setHideBarsOnScroll:on]; break;
    case YZRowWebFonts: [YZSettings setWebFonts:on]; break;
    case YZRowDebug:
        [YZSettings setDebugOverlay:on];
        // the browser shows or hides the overlay
        [_settingsDelegate settingsControllerDidChange:self];
        break;
    case YZRowLogging:
        [YZSettings setLogging:on];
        [YZLog setCapturing:on];
        [self refreshAfterSwitch];
        break;
    case YZRowZombies:
        // the names of freed objects come through the log, so it is kept while they are on
        [YZSettings setZombies:on];
        if (on) {
            [YZSettings setLogging:YES];
            [YZLog setCapturing:YES];
        }
        [self refreshAfterSwitch];
        break;
    case YZRowUnlockDesigns:
        if (on)
            [self confirmUnlockDesigns:toggle];
        else {
            [YZSettings setUnlockAllDesigns:NO];
            [_settingsDelegate settingsControllerDidChange:self];
        }
        break;
    case YZRowJit:
        [YZSettings setJit:on];
        [self refreshAfterSwitch];
        break;
    case YZRowMetal:
        [YZSettings setMetal:on];
#if defined(__arm64__)
        yozora_metal_set_allowed(on);
#endif
        break;
    default: break;
    }
}

- (void)confirmUnlockDesigns:(YZToggle *)toggle {
    YZSettingsController *me = self;
    YZDialog *dialog = [YZDialog dialogWithTitle:YZT(@"Открыть все оформления?")
                                         message:YZT(@"Оформления, которых нет для вашей версии iOS, могут работать с багами и недоработками. Включая это, вы соглашаетесь с тем, что можете с ними столкнуться.")
                                     cancelTitle:YZT(@"Отмена") confirmTitle:YZT(@"Согласен") destructive:NO handler:^(NSInteger index, NSArray *texts) {
        (void)texts;
        if (index == 1) {
            [YZSettings setUnlockAllDesigns:YES];
            [me->_settingsDelegate settingsControllerDidChange:me];
        } else {
            [toggle setOn:NO animated:YES];
        }
    }];
    dialog.picture = [YZTheme mascotImage:@"error"];
    [dialog showInView:self.navigationController.view];
}

// rows that read from the switch (the state of the jit, the line of the log) change once the switch has finished moving
- (void)refreshAfterSwitch {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(refresh) object:nil];
    [self performSelector:@selector(refresh) withObject:nil afterDelay:0.4];
}

#pragma mark table

// the first row of a section is its head, so the place in the section array is the row
- (YZRow)rowAtIndexPath:(NSIndexPath *)path {
    return (YZRow)[[[_sections objectAtIndex:path.section] objectAtIndex:path.row] intValue];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return [_sections count]; }

// the rows of a folded section are not in the table but its head is, the table must be told the same count as
// the rows it inserts or deletes or the update is refused
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return YZSectionCollapsed(section) ? 1 : (NSInteger)[[_sections objectAtIndex:section] count];
}

- (BOOL)isDestructive:(YZRow)kind { return kind == YZRowClearHistory || kind == YZRowClearSiteData; }

// the rows that open another screen carry a chevron
- (BOOL)hasChevron:(YZRow)kind { return ![self isSwitch:kind] && ![self isDestructive:kind] && kind != YZRowJitState; }

- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section { return 0; }
- (CGFloat)tableView:(UITableView *)table heightForFooterInSection:(NSInteger)section { return 4; }
- (UIView *)tableView:(UITableView *)table viewForFooterInSection:(NSInteger)section { return [[[UIView alloc] initWithFrame:CGRectZero] autorelease]; }

- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    if (path.row == 0)
        return [YZTheme isFlat] ? (path.section == 0 ? 46 : 52) : (path.section == 0 ? 48 : 60);
    YZRow kind = [self rowAtIndexPath:path];
    if (kind == YZRowAppIcons)
        return YZIconTilesHeight(table.bounds.size.width, [self iconNote]);
    return YZRowHeight([self titleForRow:kind], [self detailForRow:kind], table.bounds.size.width, YES, [self isSwitch:kind], [self hasChevron:kind]);
}

- (UITableViewCell *)headCellForSection:(NSInteger)section table:(UITableView *)table {
    YZSectionCell *cell = (YZSectionCell *)[table dequeueReusableCellWithIdentifier:@"YZSectionHead"];
    if (!cell)
        cell = [[[YZSectionCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"YZSectionHead"] autorelease];
    cell.accessibilityLabel = [[_sections objectAtIndex:section] objectAtIndex:0];
    cell->name.text = [YZTheme isFlat] ? [[[_sections objectAtIndex:section] objectAtIndex:0] uppercaseString] : [[_sections objectAtIndex:section] objectAtIndex:0];
    cell->name.font = [YZTheme isFlat] ? [YZTheme systemFontOfSize:13] : [YZTheme boldSystemFontOfSize:13];
    cell->name.textColor = [YZTheme isFlat] ? [YZTheme subtleTextColor] : [YZTheme accentColor];
    // the developer section carries the hammer in front of its name
    cell->mark.image = section == YZDeveloperSection ? [YZTheme icon:YZIconHardware size:20 color:[YZTheme accentColor]] : nil;
    cell->chevron.image = [YZTheme icon:YZIconChevron size:20 color:[YZTheme subtleTextColor]];
    cell->expanded = !YZSectionCollapsed(section);
    cell->chevron.transform = cell->expanded ? CGAffineTransformMakeRotation((CGFloat)M_PI_2) : CGAffineTransformIdentity;
    [cell setNeedsLayout];
    return cell;
}

// folds or opens a section: the chevron turns on the app spring and passes its mark, rows fade out together,
// on opening they fade in and rise one after another
- (void)toggleSection:(NSInteger)section {
    BOOL collapse = !YZSectionCollapsed(section);
    NSInteger count = (NSInteger)[[_sections objectAtIndex:section] count] - 1;
    NSMutableArray *paths = [NSMutableArray array];
    for (NSInteger i = 1; i <= count; ++i)
        [paths addObject:[NSIndexPath indexPathForRow:i inSection:section]];
    YZSetSectionCollapsed(section, collapse);
    YZSectionCell *head = (YZSectionCell *)[self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:section]];
    if (head) {
        head->expanded = !collapse;
        YZMotionAnimateView(head->chevron, collapse ? CGAffineTransformIdentity : CGAffineTransformMakeRotation((CGFloat)M_PI_2), 1, YOZORA_MOTION_WOBBLE, 0, nil);
    }
    [self.tableView beginUpdates];
    if (collapse)
        [self.tableView deleteRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationFade];
    else
        [self.tableView insertRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationFade];
    [self.tableView endUpdates];
    if (!collapse) {
        for (NSInteger i = 1; i <= count; ++i) {
            YZSettingsCell *cell = (YZSettingsCell *)[self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:i inSection:section]];
            if (cell)
                [YZTheme animateEntranceOfView:cell->card offset:CGPointMake(0, -16) delay:0.04 * (i - 1)];
        }
    }
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    if (path.row == 0)
        return [self headCellForSection:path.section table:table];
    YZRow kind = [self rowAtIndexPath:path];
    if (kind == YZRowAppIcons)
        return [self iconTilesCellForTable:table path:path];
    NSString *detail = [self detailForRow:kind];
    BOOL toggle = [self isSwitch:kind];
    YZSettingsCell *cell = (YZSettingsCell *)[table dequeueReusableCellWithIdentifier:@"YZSettingsRow"];
    if (!cell)
        cell = [[[YZSettingsCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"YZSettingsRow"] autorelease];
    BOOL destructive = [self isDestructive:kind];
    // the search engine shows its own mark in place of a glyph
    id mark = kind == YZRowSearchEngine ? [YZEngineLogos() objectAtIndex:[YZSettings searchEngine]] : nil;
    UIImage *picture = [mark isKindOfClass:[UIImage class]] ? mark : nil;
    YZConfigureCell(cell, [self titleForRow:kind], detail, [self glyphForRow:kind], picture, YES, NO, destructive,
                    YZPositionOf(path.row - 1, (NSInteger)[[_sections objectAtIndex:path.section] count] - 1), nil, [self hasChevron:kind]);
    if (kind == YZRowAccent) {
        // the accent shows itself as a ball of its color that changes its form, the way the private accent does
        cell->disc.backgroundColor = [YZTheme cardColor];
        cell->disc.layer.borderWidth = 1;
        cell->disc.layer.borderColor = [[[YZTheme accentColor] colorWithAlphaComponent:0.5f] CGColor];
        cell->icon.hidden = YES;
        if ([YZTheme isClassic]) {
            // the old system has no animated Material shapes: the accent is a lit chip of its color
            cell->disc.backgroundColor = [UIColor clearColor];
            cell->disc.layer.borderColor = [[UIColor colorWithWhite:0 alpha:0.45f] CGColor];
            cell->disc.layer.cornerRadius = 9;
            [YZClassic lightView:cell->disc color:[YZTheme accentColor] radius:9];
        } else {
            YZMorphView *ball = [cell morphBall];
            ball.hidden = NO;
            ball.color = [YZTheme accentColor];
        }
    }
    if (kind == YZRowPrivateAccent) {
        // the private accent is a ball of its color that morphs, on a disc of the private ground
        yozora_accent shown = { YOZORA_PRIVATE_PALETTE_HUE, YOZORA_ACCENT_PALETTE_SATURATION, 1 };
        [YZSettings customPrivateAccent:&shown];
        float r, g, b;
        yozora_accent_rgb(&shown, &r, &g, &b);
        [YZTheme setPrivatePalettePreview:YES];
        cell->disc.backgroundColor = [YZTheme cardColor];
        cell->disc.layer.borderWidth = 1;
        cell->disc.layer.borderColor = [[[YZTheme accentColor] colorWithAlphaComponent:0.5f] CGColor];
        [YZTheme setPrivatePalettePreview:NO];
        cell->icon.hidden = YES;
        if ([YZTheme isClassic]) {
            // the chip is lit in the private accent: the lit surface the cell gave every glyph row is tinted with the accent of the normal
            // session, so it is made again with the color of this row
            cell->disc.backgroundColor = [UIColor clearColor];
            cell->disc.layer.borderColor = [[UIColor colorWithWhite:0 alpha:0.45f] CGColor];
            cell->disc.layer.cornerRadius = 9;
            [YZClassic lightView:cell->disc color:[UIColor colorWithRed:r green:g blue:b alpha:1] radius:9];
        } else {
            YZMorphView *ball = [cell morphBall];
            ball.hidden = NO;
            ball.color = [UIColor colorWithRed:r green:g blue:b alpha:1];
        }
    }
    cell->toggle.hidden = !toggle;
    if (toggle) {
        YZToggle *control = [cell switchControl];
        control.hidden = NO;
        control.tag = kind;
        [control removeTarget:self action:NULL forControlEvents:UIControlEventValueChanged];
        [control addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        [control setOn:[self switchValue:kind] animated:NO];
        [control applyTheme];
    }
    return cell;
}

- (UIView *)dialogHost {
    return self.navigationController ? self.navigationController.view : self.view;
}

- (void)confirmClearHistory {
    YZSettingsController *me = self;
    YZDialog *dialog = [YZDialog dialogWithTitle:YZT(@"Очистить историю?") message:nil cancelTitle:YZT(@"Отмена") confirmTitle:YZT(@"Очистить") destructive:YES
                                         handler:^(NSInteger index, NSArray *texts) {
        (void)texts;
        // stored pages are history too
        if (index == 1 && [me->_store clearHistory]) {
            yozora_clear_http_cache();
            yozora_clear_bytecode_cache();
        }
    }];
    [dialog showInView:[self dialogHost]];
}

- (void)confirmClearSiteData {
    YZDialog *dialog = [YZDialog dialogWithTitle:YZT(@"Очистить данные сайтов?")
                                         message:YZT(@"Cookie и локальные данные будут удалены, во все сайты придётся войти заново.")
                                     cancelTitle:YZT(@"Отмена") confirmTitle:YZT(@"Очистить") destructive:YES
                                         handler:^(NSInteger index, NSArray *texts) {
        (void)texts;
        if (index == 1)
            yozora_clear_site_data();
    }];
    [dialog showInView:[self dialogHost]];
}

// a choice screen shows the setting read again each time, a choice can change the language the screen is
// written in
- (void)fillChoice:(YZChoiceController *)choice kind:(YZRow)kind {
    switch (kind) {
    case YZRowLanguage:
        choice.heading = YZT(@"Язык");
        choice.titles = YZLanguageNames();
        choice.details = nil;
        choice.pictures = [NSArray arrayWithObjects:YZFlagMark(YZLanguageRussian, 40), YZFlagMark(YZLanguageEnglish, 40),
                           YZFlagMark(YZLanguageJapanese, 40), nil];
        choice.tints = nil;
        choice.bareMarks = YES;
        choice.selected = [YZSettings language];
        break;
    case YZRowTheme:
        choice.heading = YZT(@"Тема");
        choice.titles = [NSArray arrayWithObjects:YZT(@"Светлая"), YZT(@"Тёмная"), YZT(@"Чёрная"), nil];
        choice.details = nil;
        choice.pictures = [NSArray arrayWithObjects:YZThemeMark(YZThemeLight, [YZTheme accentColor], 40), YZThemeMark(YZThemeDark, [YZTheme accentColor], 40),
                           YZThemeMark(YZThemeBlack, [YZTheme accentColor], 40), nil];
        choice.tints = nil;
        choice.bareMarks = YES;
        choice.selected = [YZSettings theme];
        break;
    case YZRowDesign:
        choice.heading = YZT(@"Оформление");
        choice.titles = [NSArray arrayWithObjects:YZT(@"Современное"), YZT(@"Классическое"), YZT(@"Плоское"), nil];
        choice.details = [NSArray arrayWithObjects:YZT(@"Современный браузер для старого железа"), YZT(@"Классический вид Safari снаружи, всё новое внутри"),
                          YZT(@"Белые панели и серое поле адреса, как в Safari на iOS 7, в цветах Yozora"), nil];
        choice.pictures = nil;
        choice.tints = nil;
        choice.bareMarks = NO;
        choice.selected = [YZSettings design];
        choice.locked = [NSArray arrayWithObjects:[NSNumber numberWithBool:NO], [NSNumber numberWithBool:![YZSettings classicDesignAvailable]],
                         [NSNumber numberWithBool:![YZSettings flatDesignAvailable]], nil];
        choice.lockedMessages = [NSArray arrayWithObjects:@"", YZT(@"Классическое оформление поддерживается на iOS с 5 по 7"),
                                 YZT(@"Плоское оформление поддерживается на iOS с 5 по 15"), nil];
        break;
    case YZRowTabsLayout:
        choice.heading = YZT(@"Вид вкладок");
        choice.titles = [NSArray arrayWithObjects:YZT(@"Сетка"), YZT(@"Страницы"), nil];
        choice.details = [NSArray arrayWithObjects:YZT(@"Карточки в сетке, как в Firefox"), YZT(@"Страницы, которые листают вбок, как в Safari"), nil];
        choice.pictures = nil;
        choice.tints = nil;
        choice.bareMarks = NO;
        choice.selected = [YZSettings tabsLayout];
        choice.locked = [NSArray arrayWithObjects:[NSNumber numberWithBool:NO], [NSNumber numberWithBool:[YZSettings design] == YZDesignModern], nil];
        choice.lockedMessages = [NSArray arrayWithObjects:@"", YZT(@"Страницы есть в классическом и плоском оформлении, в современном только сетка"), nil];
        break;
    case YZRowMascot:
        choice.heading = YZT(@"Маскот");
        choice.titles = [NSArray arrayWithObjects:YZMascotTitle(YZMascotSan), YZMascotTitle(YZMascotFox), YZMascotTitle(YZMascotSenko), nil];
        choice.details = nil;
        choice.pictures = [NSArray arrayWithObjects:YZMascotMark(YZMascotSan, 40), YZMascotMark(YZMascotFox, 40), YZMascotMark(YZMascotSenko, 40), nil];
        choice.tints = nil;
        choice.bareMarks = YES;
        choice.selected = [YZSettings mascot];
        choice.mascotPreview = YES;
        break;
    case YZRowSearchEngine:
        choice.heading = YZT(@"Поисковая система");
        choice.titles = YZEngineNames();
        choice.details = YZEngineAddresses();
        choice.pictures = YZEngineLogos();
        choice.tints = YZEngineTints();
        choice.bareMarks = NO;
        choice.selected = [YZSettings searchEngine];
        break;
    default:
        break;
    }
}

- (void)pushChoice:(YZRow)kind {
    YZSettingsController *me = self;
    YZChoiceController *choice = [[YZChoiceController alloc] initWithTitle:@"" options:[NSArray array] selected:0 choose:^(NSInteger index) {
        switch (kind) {
        case YZRowLanguage: [YZSettings setLanguage:(YZLanguage)index]; break;
        case YZRowTheme: [YZSettings setTheme:(YZThemeKind)index]; break;
        case YZRowDesign: [YZSettings setDesign:(YZDesign)index]; break;
        case YZRowTabsLayout: [YZSettings setTabsLayout:(YZTabsLayout)index]; break;
        case YZRowMascot: [YZSettings setMascot:(YZMascot)index]; break;
        case YZRowSearchEngine: [YZSettings setSearchEngine:(yozora_search_engine)index]; break;
        default: break;
        }
        [me changed];
    }];
    choice.refill = ^(YZChoiceController *shown) { [me fillChoice:shown kind:kind]; };
    [self fillChoice:choice kind:kind];
    [self.navigationController pushViewController:choice animated:YES];
    [choice release];
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.row == 0) {
        [self toggleSection:path.section];
        return;
    }
    YZRow kind = [self rowAtIndexPath:path];
    YZSettingsController *me = self;
    switch (kind) {
    case YZRowLanguage:
    case YZRowTheme:
    case YZRowDesign:
    case YZRowTabsLayout:
    case YZRowMascot:
    case YZRowSearchEngine:
        [self pushChoice:kind];
        break;
    case YZRowAppIcons:
        // the tiles take the taps
        break;
    case YZRowAccent: {
        YZAccentController *accent = [[YZAccentController alloc] initWithChanged:^{ [me changed]; }];
        [self.navigationController pushViewController:accent animated:YES];
        [accent release];
        break;
    }
    case YZRowPrivateAccent: {
        YZAccentController *accent = [[YZAccentController alloc] initPrivateWithChanged:^{ [me changed]; }];
        [self.navigationController pushViewController:accent animated:YES];
        [accent release];
        break;
    }
    case YZRowAdblockRules: {
        YZAdblockController *rules = [[YZAdblockController alloc] init];
        [self.navigationController pushViewController:rules animated:YES];
        [rules release];
        break;
    }
    case YZRowDns:
        [YZDnsPopup presentInView:self.navigationController.view current:[YZSettings dnsServer] done:^(NSString *url) {
            [YZSettings setDnsServerText:url];
            [me changed];
        }];
        break;
    case YZRowCertificates: {
        YZCertificatesController *certificates = [[YZCertificatesController alloc] init];
        [self.navigationController pushViewController:certificates animated:YES];
        [certificates release];
        break;
    }
    case YZRowSitePermissions: {
        YZSitesController *sites = [[YZSitesController alloc] init];
        [self.navigationController pushViewController:sites animated:YES];
        [sites release];
        break;
    }
    case YZRowLogOpen: {
        [YZCrash note:@"logs: tapped"];
        YZLogController *log = [[YZLogController alloc] init];
        [YZCrash note:@"logs: created"];
        [self.navigationController pushViewController:log animated:YES];
        [log release];
        [YZCrash note:@"logs: pushed"];
        break;
    }
    case YZRowBackground: {
        YZBackgroundController *background = [[YZBackgroundController alloc] initWithStore:_store changed:^{ [me changed]; }];
        [self.navigationController pushViewController:background animated:YES];
        [background release];
        break;
    }
    case YZRowTextSize: {
        YZTextSizeController *size = [[YZTextSizeController alloc] initWithChanged:^{ [me changed]; }];
        [self.navigationController pushViewController:size animated:YES];
        [size release];
        break;
    }
    case YZRowClearHistory:
        [self confirmClearHistory];
        break;
    case YZRowClearSiteData:
        [self confirmClearSiteData];
        break;
    case YZRowUpdate: {
        YZUpdateController *update = [[YZUpdateController alloc] init];
        update.openPage = ^{ [_settingsDelegate settingsController:self openAddress:YZReleasePageAddress]; };
        [self.navigationController pushViewController:update animated:YES];
        [update release];
        break;
    }
    case YZRowAbout: {
        YZAboutController *about = [[YZAboutController alloc] init];
        about.openAddress = ^(NSString *address) { [_settingsDelegate settingsController:self openAddress:address]; };
        [self.navigationController pushViewController:about animated:YES];
        [about release];
        break;
    }
    default:
        break;
    }
}

@end

@implementation YZChoiceController
@synthesize heading = _heading;
@synthesize titles = _titles;
@synthesize details = _details;
@synthesize pictures = _pictures;
@synthesize tints = _tints;
@synthesize bareMarks = _bareMarks;
@synthesize selected = _selected;
@synthesize mascotPreview = _mascotPreview;
@synthesize locked = _locked;
@synthesize lockedMessages = _lockedMessages;
@synthesize refill = _refill;

- (id)initWithTitle:(NSString *)title options:(NSArray *)titles selected:(NSInteger)selected choose:(void (^)(NSInteger index))choose {
    self = [super initWithStyle:UITableViewStylePlain];
    if (!self)
        return nil;
    _heading = [title copy];
    _titles = [titles retain];
    _selected = selected;
    _choose = [choose copy];
    return self;
}

- (void)dealloc {
    [YZCrash noteLifecycle:@"dealloc" object:self];
    [_barFill removeFromSuperview];
    [_barFill release];
    [_preview release];
    [_heading release];
    [_titles release];
    [_locked release];
    [_lockedMessages release];
    [_details release];
    [_pictures release];
    [_tints release];
    [_refill release];
    [_choose release];
    [super dealloc];
}

- (void)restyle {
    YZStyleTable(self);
    if (!_barFill)
        _barFill = [[YZBarFill alloc] initWithFrame:CGRectZero];
    [_barFill applyTheme];
    [_barFill attachToScrollView:self.tableView controller:self];
    YZInstallBarTitle(self, _heading, self, @selector(back));
    self.tableView.tableHeaderView = nil;
    if (_mascotPreview) {
        // the footer is set once and again only for a new width: setting it on every choice rebuilt the layout of the table under the preview
        CGFloat width = self.tableView.bounds.size.width;
        if (!_preview) {
            _preview = [[YZMascotPreview alloc] initWithMascot:(YZMascot)_selected];
            _preview.frame = CGRectMake(0, 0, width, [YZMascotPreview preferredHeight]);
            self.tableView.tableFooterView = _preview;
        } else if (fabs(_preview.frame.size.width - width) > 0.5) {
            _preview.frame = CGRectMake(0, 0, width, [YZMascotPreview preferredHeight]);
            self.tableView.tableFooterView = _preview;
        }
        [_preview applyTheme];
    } else {
        self.tableView.tableFooterView = nil;
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if ([self respondsToSelector:NSSelectorFromString(@"setWantsFullScreenLayout:")])
        [self setValue:[NSNumber numberWithBool:YES] forKey:@"wantsFullScreenLayout"];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [YZCrash note:[NSString stringWithFormat:@"screen %@", NSStringFromClass([self class])]];
    [self restyle];
    [self.tableView reloadData];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UINavigationBar *bar = self.navigationController.navigationBar;
    if (bar && [[[UIDevice currentDevice] systemVersion] floatValue] < 7.0f) {
        CGFloat top = [YZTheme barOverlap:bar];
        UIEdgeInsets inset = self.tableView.contentInset;
        if (fabs(inset.top - top) > 0.5) {
            BOOL atTop = self.tableView.contentOffset.y <= -inset.top + 1;
            inset.top = top;
            self.tableView.contentInset = inset;
            self.tableView.scrollIndicatorInsets = inset;
            if (atTop)
                self.tableView.contentOffset = CGPointMake(0, -top);
        }
    }
    YZInstallBarTitle(self, _heading, self, @selector(back));
    [_barFill attachToScrollView:self.tableView controller:self];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [_barFill attachToScrollView:scrollView controller:self];
}

- (void)back { [self.navigationController popViewControllerAnimated:YES]; }

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return (NSInteger)[_titles count]; }

- (id)markAt:(NSInteger)row {
    id picture = row < (NSInteger)[_pictures count] ? [_pictures objectAtIndex:row] : nil;
    return [picture isKindOfClass:[UIImage class]] ? picture : nil;
}

- (NSString *)detailAt:(NSInteger)row {
    return row < (NSInteger)[_details count] ? [_details objectAtIndex:row] : nil;
}

- (BOOL)lockedAt:(NSInteger)row {
    return row < (NSInteger)[_locked count] && [[_locked objectAtIndex:row] boolValue];
}

- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    return YZRowHeight([_titles objectAtIndex:path.row], [self detailAt:path.row], table.bounds.size.width, [self markAt:path.row] != nil, NO, NO);
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    YZSettingsCell *cell = (YZSettingsCell *)[table dequeueReusableCellWithIdentifier:@"YZChoice"];
    if (!cell)
        cell = [[[YZSettingsCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"YZChoice"] autorelease];
    // the chosen option is a plate in its own color (the accent, or the brand of an engine), not a check mark
    UIColor *plate = nil;
    if (path.row == _selected) {
        id tint = path.row < (NSInteger)[_tints count] ? [_tints objectAtIndex:path.row] : nil;
        plate = YZMixColors([YZTheme cardColor], [tint isKindOfClass:[UIColor class]] ? tint : [YZTheme accentColor], [YZTheme isClassic] ? 0.45f : ([YZTheme isDark] ? 0.38f : 0.3f));
    }
    UIImage *mark = [self markAt:path.row];
    YZConfigureCell(cell, [_titles objectAtIndex:path.row], [self detailAt:path.row], YZIconCheck, mark, NO, _bareMarks, NO,
                    YZPositionOf(path.row, (NSInteger)[_titles count]), plate, NO);
    // the address under a name is a half-seen line
    cell->detail.textColor = [[YZTheme subtleTextColor] colorWithAlphaComponent:0.7f];
    cell->toggle.hidden = YES;
    [cell setLocked:[self lockedAt:path.row]];
    return cell;
}

// the screen stays when a value is chosen, the settings behind and the browser take the change and this
// screen does too, with a cross fade so a new theme does not snap
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:NO];
    if ([self lockedAt:path.row]) {
        [[YZDialog dialogWithTitle:YZT(@"Недоступно") message:path.row < (NSInteger)[_lockedMessages count] ? [_lockedMessages objectAtIndex:path.row] : nil cancelTitle:nil confirmTitle:YZT(@"Готово") destructive:NO handler:nil]
            showInView:self.navigationController.view];
        return;
    }
    if (path.row == _selected)
        return;
    _selected = path.row;
    if (_mascotPreview) {
        // the preview and the chosen plate answer first. the app takes the new mascot on the next turn of the run loop: the pages
        // behind this screen are styled again then, and doing that inside the touch held the fade back
        [_preview showMascot:(YZMascot)_selected];
        [self.tableView reloadData];
        NSInteger chosen = path.row;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (_choose)
                _choose(chosen);
            if (_refill)
                _refill(self);
        });
        return;
    }
    if (_choose)
        _choose(path.row);
    if (_refill)
        _refill(self);
    void (^apply)(void) = ^{
        [self restyle];
        [self.tableView reloadData];
    };
    if ([YZTheme animationsEnabled])
        [UIView transitionWithView:self.view duration:0.28 options:UIViewAnimationOptionTransitionCrossDissolve animations:apply completion:nil];
    else
        apply();
}

@end

// the screen of the text size: a card that shows the size, a slider like the ones of the accent and a button that goes back to 100
@implementation YZTextSizeController

- (id)initWithChanged:(void (^)(void))changed {
    self = [super initWithNibName:nil bundle:nil];
    if (!self)
        return nil;
    _changed = [changed copy];
    _percent = [YZSettings textZoom];
    return self;
}

- (void)dealloc {
    [YZCrash noteLifecycle:@"dealloc" object:self];
    [_scroll release];
    [_card release];
    [_value release];
    [_sample release];
    [_track release];
    [_low release];
    [_high release];
    [_reset release];
    [_fill release];
    [_changed release];
    [super dealloc];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if ([self respondsToSelector:NSSelectorFromString(@"setWantsFullScreenLayout:")])
        [self setValue:[NSNumber numberWithBool:YES] forKey:@"wantsFullScreenLayout"];
    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_scroll];
    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.layer.cornerRadius = 28;
    _card.clipsToBounds = YES;
    [_scroll addSubview:_card];
    _value = [[UILabel alloc] initWithFrame:CGRectZero];
    _value.backgroundColor = [UIColor clearColor];
    [_card addSubview:_value];
    _sample = [[UILabel alloc] initWithFrame:CGRectZero];
    _sample.backgroundColor = [UIColor clearColor];
    _sample.numberOfLines = 0;
    _sample.lineBreakMode = YZLineBreakWordWrapping;
    [_card addSubview:_sample];
    _track = [[YZAccentTrack alloc] initWithFrame:CGRectZero];
    _track.spokenName = YZT(@"Размер текста");
    [_track addTarget:self action:@selector(moved) forControlEvents:UIControlEventValueChanged];
    [_track addTarget:self action:@selector(commit) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:_track];
    _low = [[UILabel alloc] initWithFrame:CGRectZero];
    _low.backgroundColor = [UIColor clearColor];
    [_scroll addSubview:_low];
    _high = [[UILabel alloc] initWithFrame:CGRectZero];
    _high.backgroundColor = [UIColor clearColor];
    _high.textAlignment = YZTextAlignmentRight;
    [_scroll addSubview:_high];
    _reset = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _reset.layer.cornerRadius = 24;
    [_reset addTarget:self action:@selector(resetSize) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:_reset];
    _fill = [[YZBarFill alloc] initWithFrame:CGRectZero];
    [self restyle];
}

// the percent of the track: a step of 5 over the range of the setting
- (NSInteger)percentForFraction:(float)fraction {
    NSInteger raw = YZTextZoomMin + (NSInteger)lroundf(fraction * (YZTextZoomMax - YZTextZoomMin));
    return MIN((NSInteger)YZTextZoomMax, MAX((NSInteger)YZTextZoomMin, ((raw + 2) / 5) * 5));
}

- (void)showPercent {
    _value.text = [NSString stringWithFormat:@"%d%%", (int)_percent];
    // the sample is set at the size of a page, not scaled again by the text size of the interface
    _sample.font = [UIFont systemFontOfSize:round(16.0f * _percent / 100.0f * 2) / 2];
    _track.fraction = (float)(_percent - YZTextZoomMin) / (YZTextZoomMax - YZTextZoomMin);
    [self.view setNeedsLayout];
}

- (void)restyle {
    self.view.backgroundColor = [YZTheme screenColor];
    _scroll.backgroundColor = [UIColor clearColor];
    YZPaintBehindScreens(self.navigationController);
    [YZTheme styleTransparentNavigationBar:self.navigationController.navigationBar];
    [_fill applyTheme];
    _card.backgroundColor = [YZTheme cardColor];
    _value.font = [YZTheme boldSystemFontOfSize:40];
    _value.textColor = [YZTheme accentColor];
    _sample.text = YZT(@"Так страницы выглядят при выбранном размере текста. Быстрая бурая лиса прыгает через ленивую собаку.");
    _sample.textColor = [YZTheme textColor];
    [_track setColors:[NSArray arrayWithObjects:YZMixColors([YZTheme cardColor], [YZTheme accentColor], 0.3f), [YZTheme accentColor], nil]];
    [_track setHandleColor:[YZTheme accentColor]];
    _low.font = [YZTheme systemFontOfSize:13];
    _low.textColor = [YZTheme subtleTextColor];
    _low.text = [NSString stringWithFormat:@"%d%%", YZTextZoomMin];
    _high.font = _low.font;
    _high.textColor = [YZTheme subtleTextColor];
    _high.text = [NSString stringWithFormat:@"%d%%", YZTextZoomMax];
    _reset.backgroundColor = [YZTheme cardColor];
    _reset.titleLabel.font = [YZTheme boldSystemFontOfSize:16];
    [_reset setTitle:YZT(@"100% по умолчанию") forState:UIControlStateNormal];
    [_reset setTitleColor:[YZTheme accentColor] forState:UIControlStateNormal];
    YZInstallBarTitle(self, YZT(@"Размер текста"), self, @selector(back));
    [self showPercent];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [YZCrash note:[NSString stringWithFormat:@"screen %@", NSStringFromClass([self class])]];
    [self restyle];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat inset = [YZTheme barOverlap:self.navigationController.navigationBar];
    CGFloat width = MIN((CGFloat)480, _scroll.bounds.size.width);
    CGFloat x = floor((_scroll.bounds.size.width - width) / 2);
    CGFloat top = inset + 8;
    _card.frame = CGRectMake(x + 16, top, width - 32, 240);
    CGFloat cw = _card.bounds.size.width;
    _value.frame = CGRectMake(24, 16, cw - 48, 52);
    _sample.frame = CGRectMake(24, 74, cw - 48, 240 - 74 - 16);
    CGFloat trackTop = CGRectGetMaxY(_card.frame) + 28;
    _track.frame = CGRectMake(x + 16, trackTop, width - 32, 40);
    _low.frame = CGRectMake(x + 16 + 8, trackTop + 42, 80, 18);
    _high.frame = CGRectMake(x + width - 16 - 8 - 80, trackTop + 42, 80, 18);
    _reset.frame = CGRectMake(x + 16, trackTop + 84, width - 32, 48);
    _scroll.contentSize = CGSizeMake(_scroll.bounds.size.width, CGRectGetMaxY(_reset.frame) + 24);
    YZInstallBarTitle(self, YZT(@"Размер текста"), self, @selector(back));
    [_fill placeInView:self.view controller:self];
}

- (void)back { [self.navigationController popViewControllerAnimated:YES]; }

// the card follows the finger, the setting is taken when the finger is lifted
- (void)moved {
    _percent = [self percentForFraction:_track.fraction];
    _value.text = [NSString stringWithFormat:@"%d%%", (int)_percent];
    _sample.font = [UIFont systemFontOfSize:round(16.0f * _percent / 100.0f * 2) / 2];
}

- (void)commit {
    _percent = [self percentForFraction:_track.fraction];
    [YZSettings setTextZoom:_percent];
    if (_changed)
        _changed();
    [self restyle];
}

- (void)resetSize {
    _percent = 100;
    [YZSettings setTextZoom:100];
    [YZTheme animateFeedbackOfView:_reset];
    if (_changed)
        _changed();
    [self restyle];
}

@end

@implementation YZBackgroundController

- (id)initWithStore:(YZStore *)store changed:(void (^)(void))changed {
    self = [super initWithNibName:nil bundle:nil];
    if (!self)
        return nil;
    _store = [store retain];
    _changed = [changed copy];
    _percent = [YZSettings homeBackgroundBlur];
    _shownStamp = -1;
    return self;
}

- (void)dealloc {
    [YZCrash noteLifecycle:@"dealloc" object:self];
    _popover.delegate = nil;
    [_popover release];
    _preview.tapped = nil;
    [_preview release];
    [_card release];
    [_backKey release];
    [_store release];
    [_value release];
    [_track release];
    [_choose release];
    [_remove release];
    [_changed release];
    [super dealloc];
}

// the screen is the start page at its real size with the controls on a card over its foot, the bar of the navigation stack is not used
- (void)viewDidLoad {
    [super viewDidLoad];
    if ([self respondsToSelector:NSSelectorFromString(@"setWantsFullScreenLayout:")])
        [self setValue:[NSNumber numberWithBool:YES] forKey:@"wantsFullScreenLayout"];
    _preview = [[YZBackgroundPreview alloc] initWithFrame:self.view.bounds];
    _preview.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // a touch on the page while it has no photo opens the library, as the button does
    _preview.tapped = ^{ [self choosePicture]; };
    [self.view addSubview:_preview];
    _backKey = [[YZStateButton buttonWithType:UIButtonTypeCustom] retain];
    [_backKey addTarget:self action:@selector(back) forControlEvents:UIControlEventTouchUpInside];
    _backKey.accessibilityLabel = YZT(@"Назад");
    [self.view addSubview:_backKey];
    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.layer.shadowColor = [[UIColor blackColor] CGColor];
    _card.layer.shadowOpacity = 0.18f;
    _card.layer.shadowRadius = 10;
    _card.layer.shadowOffset = CGSizeMake(0, 3);
    [self.view addSubview:_card];
    _value = [[UILabel alloc] initWithFrame:CGRectZero];
    _value.backgroundColor = [UIColor clearColor];
    _value.textAlignment = YZTextAlignmentCenter;
    [_card addSubview:_value];
    _track = [[YZAccentTrack alloc] initWithFrame:CGRectZero];
    _track.spokenName = YZT(@"Размытие фона");
    [_track addTarget:self action:@selector(moved) forControlEvents:UIControlEventValueChanged];
    [_track addTarget:self action:@selector(commit) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:_track];
    _choose = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _choose.layer.cornerRadius = 18;
    [_choose addTarget:self action:@selector(choosePicture) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:_choose];
    _remove = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _remove.layer.cornerRadius = 18;
    [_remove addTarget:self action:@selector(removePicture) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:_remove];
    [self restyle];
}

- (NSString *)valueText {
    return [NSString stringWithFormat:@"%@ %d%%", YZT(@"Размытие"), (int)_percent];
}

- (void)showState {
    NSInteger stamp = [YZSettings homeBackgroundStamp];
    UIImage *picture = [YZBackground image];
    _value.text = [self valueText];
    _track.fraction = (float)_percent / 100.0f;
    // a new photo dissolves into the old one, a new blur follows the finger without it
    [_preview showPicture:[YZBackground imageBlurredBy:_percent] dissolve:stamp != _shownStamp && _shownStamp >= 0];
    _shownStamp = stamp;
    _track.enabled = picture != nil;
    _track.alpha = picture ? 1 : 0.4f;
    _remove.hidden = picture == nil;
    [_choose setTitle:picture ? YZT(@"Другое фото") : YZT(@"Выбрать фото") forState:UIControlStateNormal];
    _choose.enabled = !_storing;
    [self.view setNeedsLayout];
}

- (void)restyle {
    self.view.backgroundColor = [YZTheme screenColor];
    YZPaintBehindScreens(self.navigationController);
    [_preview restyle];
    // the tiles of the page are the person's own sites and bookmarks, ordered as the start page orders them
    NSMutableArray *sites = [NSMutableArray arrayWithArray:[_store recentHistory]];
    [sites sortUsingComparator:^NSComparisonResult(YZRecord *a, YZRecord *b) {
        if (a.visits == b.visits)
            return NSOrderedSame;
        return a.visits > b.visits ? NSOrderedAscending : NSOrderedDescending;
    }];
    [_preview showSites:sites bookmarks:[_store bookmarks]];
    [_backKey setImage:[YZTheme barIcon:YZIconBack size:24 disabled:NO] forState:UIControlStateNormal];
    // a little see-through, the page and the photo show faintly behind it
    _card.backgroundColor = [[YZTheme cardColor] colorWithAlphaComponent:0.9f];
    _card.layer.cornerRadius = MIN([YZTheme sheetRadius], (CGFloat)18);
    _value.font = [YZTheme boldSystemFontOfSize:15];
    _value.textColor = [YZTheme accentColor];
    [_track setColors:[NSArray arrayWithObjects:YZMixColors([YZTheme surfaceColor], [YZTheme accentColor], 0.3f), [YZTheme accentColor], nil]];
    [_track setHandleColor:[YZTheme accentColor]];
    for (UIButton *button in [NSArray arrayWithObjects:_choose, _remove, nil]) {
        button.backgroundColor = [YZTheme surfaceColor];
        button.titleLabel.font = [YZTheme boldSystemFontOfSize:14];
    }
    [_choose setTitleColor:[YZTheme accentColor] forState:UIControlStateNormal];
    [_remove setTitle:YZT(@"Убрать фон") forState:UIControlStateNormal];
    [_remove setTitleColor:[UIColor colorWithRed:0.86f green:0.22f blue:0.22f alpha:1] forState:UIControlStateNormal];
    [self showState];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [YZCrash note:[NSString stringWithFormat:@"screen %@", NSStringFromClass([self class])]];
    [self.navigationController setNavigationBarHidden:YES animated:animated];
    [self restyle];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // the screens of the stack show their own bar
    if (self.navigationController.topViewController != self)
        [self.navigationController setNavigationBarHidden:NO animated:animated];
}

// the status line, the notch and the home indicator, as the browser reads them
- (UIEdgeInsets)screenInsets {
    UIEdgeInsets insets = UIEdgeInsetsZero;
    if ([self.view respondsToSelector:NSSelectorFromString(@"safeAreaInsets")])
        insets = [[self.view valueForKey:@"safeAreaInsets"] UIEdgeInsetsValue];
    CGFloat status = [[UIApplication sharedApplication] statusBarFrame].size.height;
    insets.top = MAX(insets.top, MIN(status, (CGFloat)44));
    return insets;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets insets = [self screenInsets];
    _preview.insets = insets;
    [_preview layoutIfNeeded];
    _backKey.frame = [_preview backKeyFrame];
    CGFloat viewWidth = self.view.bounds.size.width;
    CGFloat width = MIN((CGFloat)340, viewWidth - 32), pad = 10;
    BOOL removable = !_remove.hidden;
    CGFloat height = pad + 20 + 30 + 6 + 36 + pad;
    CGFloat bottom = [_preview pageBottom] - 10;
    // a card that would cover more than the room between the bars keeps to it, the page above stays visible
    CGFloat top = MAX([_preview pageTop] + 8, bottom - height);
    _card.frame = CGRectMake(floor((viewWidth - width) / 2), top, width, bottom - top);
    _card.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_card.bounds cornerRadius:_card.layer.cornerRadius].CGPath;
    _value.frame = CGRectMake(pad, pad, width - 2 * pad, 20);
    _track.frame = CGRectMake(pad, pad + 20, width - 2 * pad, 30);
    CGFloat buttonsTop = pad + 20 + 30 + 6;
    CGFloat buttonWidth = removable ? floor((width - 3 * pad) / 2) : width - 2 * pad;
    _choose.frame = CGRectMake(pad, buttonsTop, buttonWidth, 36);
    _remove.frame = CGRectMake(pad * 2 + buttonWidth, buttonsTop, buttonWidth, 36);
}

- (void)back { [self.navigationController popViewControllerAnimated:YES]; }

// steps of 5 percent, the preview follows the finger and the setting is taken when the finger is lifted
- (NSInteger)percentForFraction:(float)fraction {
    NSInteger raw = (NSInteger)lroundf(fraction * 100);
    return MIN((NSInteger)100, MAX((NSInteger)0, ((raw + 2) / 5) * 5));
}

- (void)moved {
    NSInteger percent = [self percentForFraction:_track.fraction];
    if (percent == _percent)
        return;
    _percent = percent;
    _value.text = [self valueText];
    [_preview showPicture:[YZBackground imageBlurredBy:_percent] dissolve:NO];
}

- (void)commit {
    _percent = [self percentForFraction:_track.fraction];
    [YZSettings setHomeBackgroundBlur:_percent];
    if (_changed)
        _changed();
    [self showState];
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
        [self presentViewController:picker animated:YES completion:nil];
    }
}

- (void)closePicker {
    if (_popover) {
        [_popover dismissPopoverAnimated:YES];
        _popover.delegate = nil;
        [_popover release];
        _popover = nil;
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
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
                [dialog showInView:self.navigationController.view];
            }
            [self showState];
        });
        [pool drain];
    });
}

- (void)removePicture {
    [YZBackground remove];
    [YZTheme animateFeedbackOfView:_remove];
    if (_changed)
        _changed();
    [self showState];
}

@end

// the app screen: the sticker card, name, version from the bundle, a line about it and the links
@implementation YZAboutController

@synthesize openAddress = _openAddress;

- (id)init {
    self = [super initWithStyle:UITableViewStylePlain];
    return self;
}

- (void)dealloc {
    [YZCrash noteLifecycle:@"dealloc" object:self];
    [_barFill removeFromSuperview];
    [_barFill release];
    [_hero release];
    [_openAddress release];
    [super dealloc];
}

- (NSString *)versionText {
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (![version length])
        version = [[NSBundle mainBundle] objectForInfoDictionaryKey:(NSString *)kCFBundleVersionKey];
    return [NSString stringWithFormat:@"v%@", version ? version : @"?"];
}

// the card is made for the width of the table
- (UIView *)makeHero:(CGFloat)width {
    CGFloat cardWidth = MIN((CGFloat)520, width - 32);
    UIView *host = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 100)] autorelease];
    // the card of the classic design is the lit plate of the system tinted for the theme, with its outline and gloss
    YZPlateView *card = [[[YZPlateView alloc] initWithFrame:CGRectZero] autorelease];
    card.sheetCornersInModern = YES;
    [card applyTheme];
    [host addSubview:card];
    CGFloat inner = cardWidth - 48;
    CGFloat y = 28;
    UIImageView *sticker = [[[UIImageView alloc] initWithImage:[YZTheme mascotImage:@"sticker"]] autorelease];
    sticker.contentMode = UIViewContentModeScaleAspectFit;
    sticker.frame = CGRectMake((cardWidth - 144) / 2, y, 144, 144);
    [card addSubview:sticker];
    _hero = [sticker retain];
    y += 144 + 12;
    UILabel *name = [[[UILabel alloc] initWithFrame:CGRectMake(24, y, inner, 42)] autorelease];
    name.text = @"Yozora";
    name.font = [YZTheme isClassic] ? [UIFont boldSystemFontOfSize:32] : [YZTheme boldSystemFontOfSize:32];
    name.textColor = [YZTheme textColor];
    name.textAlignment = YZTextAlignmentCenter;
    name.backgroundColor = [UIColor clearColor];
    [card addSubview:name];
    y += 46;
    // the version in a pill of the accent: flat in the modern design, a lit key of the system with white stamped text in the classic one
    UILabel *version = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    version.text = [self versionText];
    version.font = [YZTheme boldSystemFontOfSize:13];
    version.textAlignment = YZTextAlignmentCenter;
    CGFloat pill = MIN(inner, YZTextSize(version.text, version.font).width + 28);
    if ([YZTheme isClassic]) {
        UIView *chip = [[[UIView alloc] initWithFrame:CGRectMake((cardWidth - pill) / 2, y, pill, 28)] autorelease];
        [card addSubview:chip];
        [YZClassic lightView:chip color:[YZClassic barMidColor] radius:8];
        chip.layer.borderWidth = 1;
        chip.layer.borderColor = [[UIColor colorWithWhite:0 alpha:0.45f] CGColor];
        chip.layer.cornerRadius = 8;
        version.frame = chip.bounds;
        version.backgroundColor = [UIColor clearColor];
        version.textColor = [UIColor whiteColor];
        version.shadowColor = [YZClassic stampColor];
        version.shadowOffset = CGSizeMake(0, -1);
        [chip addSubview:version];
    } else {
        version.textColor = [YZTheme accentColor];
        version.backgroundColor = [YZTheme stateColor];
        version.frame = CGRectMake((cardWidth - pill) / 2, y, pill, 28);
        version.layer.cornerRadius = 14;
        version.clipsToBounds = YES;
        [card addSubview:version];
    }
    y += 28 + 16;
    UILabel *text = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    text.text = YZT(@"Современный браузер для iOS 5 и новее на новейшем WebKit.");
    text.font = [YZTheme systemFontOfSize:15];
    text.textColor = [YZTheme subtleTextColor];
    text.textAlignment = YZTextAlignmentCenter;
    text.numberOfLines = 0;
    text.lineBreakMode = YZLineBreakWordWrapping;
    text.backgroundColor = [UIColor clearColor];
    CGFloat textHeight = YZMeasureHeight(text.text, text.font, inner);
    text.frame = CGRectMake(24, y, inner, textHeight);
    [card addSubview:text];
    y += textHeight + 28;
    card.frame = CGRectMake(floor((width - cardWidth) / 2), 8, cardWidth, y);
    host.frame = CGRectMake(0, 0, width, y + 8 + 12);
    return host;
}

- (void)restyle {
    YZStyleTable(self);
    if (!_barFill)
        _barFill = [[YZBarFill alloc] initWithFrame:CGRectZero];
    [_barFill applyTheme];
    [_barFill attachToScrollView:self.tableView controller:self];
    YZInstallBarTitle(self, YZT(@"Об Yozora"), self, @selector(back));
    [_hero release];
    _hero = nil;
    self.tableView.tableHeaderView = [self makeHero:self.tableView.bounds.size.width];
    _heroWidth = self.tableView.bounds.size.width;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if ([self respondsToSelector:NSSelectorFromString(@"setWantsFullScreenLayout:")])
        [self setValue:[NSNumber numberWithBool:YES] forKey:@"wantsFullScreenLayout"];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [YZCrash note:[NSString stringWithFormat:@"screen %@", NSStringFromClass([self class])]];
    [self restyle];
    [self.tableView reloadData];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // the sticker wobbles in once, like the one of the splash
    [YZTheme animateEntranceOfView:_hero offset:CGPointMake(0, 18) delay:0.05];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UINavigationBar *bar = self.navigationController.navigationBar;
    if (bar && [[[UIDevice currentDevice] systemVersion] floatValue] < 7.0f) {
        CGFloat top = [YZTheme barOverlap:bar];
        UIEdgeInsets inset = self.tableView.contentInset;
        if (fabs(inset.top - top) > 0.5) {
            BOOL atTop = self.tableView.contentOffset.y <= -inset.top + 1;
            inset.top = top;
            self.tableView.contentInset = inset;
            self.tableView.scrollIndicatorInsets = inset;
            if (atTop)
                self.tableView.contentOffset = CGPointMake(0, -top);
        }
    }
    // a turn of the device makes the card again for the new width
    if (fabs(self.tableView.bounds.size.width - _heroWidth) > 0.5) {
        [_hero release];
        _hero = nil;
        self.tableView.tableHeaderView = [self makeHero:self.tableView.bounds.size.width];
        _heroWidth = self.tableView.bounds.size.width;
    }
    YZInstallBarTitle(self, YZT(@"Об Yozora"), self, @selector(back));
    [_barFill attachToScrollView:self.tableView controller:self];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [_barFill attachToScrollView:scrollView controller:self];
}

- (void)back { [self.navigationController popViewControllerAnimated:YES]; }

// the engine version is written into Info.plist from the pin of the sources, a test keeps the two equal
- (NSString *)webKitVersion {
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"YozoraWebKitVersion"];
    if (![version isKindOfClass:[NSString class]] || ![version length]) {
        NSLog(@"yozora: Info.plist has no YozoraWebKitVersion");
        return @"?";
    }
    return version;
}

// the links: the title, the address under it
- (NSArray *)links {
    return [NSArray arrayWithObjects:
        [NSArray arrayWithObjects:@"GitHub", @"https://github.com/sqmrak/yozora", @"https://github.com/sqmrak/yozora", [NSNumber numberWithInt:YZIconCode], nil],
        [NSArray arrayWithObjects:YZT(@"Telegram-канал"), @"@sqmrakdev", @"https://t.me/sqmrakdev", [NSNumber numberWithInt:YZIconShare], nil],
        // no address: the row shows what it names. the version of the engine is the one this build was made from, `core/source.json`
        [NSArray arrayWithObjects:@"WebKit", [self webKitVersion], @"", [NSNumber numberWithInt:YZIconCode], nil],
        [NSArray arrayWithObjects:YZT(@"Официальные тестеры"), YZAboutTesters, @"", [NSNumber numberWithInt:YZIconInfo], nil],
        nil];
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return (NSInteger)[[self links] count]; }

- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    NSArray *link = [[self links] objectAtIndex:path.row];
    return YZRowHeight([link objectAtIndex:0], [link objectAtIndex:1], table.bounds.size.width, YES, NO, [[link objectAtIndex:2] length] > 0);
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    YZSettingsCell *cell = (YZSettingsCell *)[table dequeueReusableCellWithIdentifier:@"YZLink"];
    if (!cell)
        cell = [[[YZSettingsCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"YZLink"] autorelease];
    NSArray *link = [[self links] objectAtIndex:path.row];
    YZConfigureCell(cell, [link objectAtIndex:0], [link objectAtIndex:1], (YZIcon)[[link objectAtIndex:3] intValue], nil, YES, NO, NO,
                    YZPositionOf(path.row, (NSInteger)[[self links] count]), nil, [[link objectAtIndex:2] length] > 0);
    cell->toggle.hidden = YES;
    return cell;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    NSString *address = [[[self links] objectAtIndex:path.row] objectAtIndex:2];
    NSURL *url = [address length] ? [NSURL URLWithString:address] : nil;
    if (!url)
        return;
    // a web address opens in a tab of Yozora, the browser closes this screen first; openURL: would hand it to Safari
    NSString *scheme = [[url scheme] lowercaseString];
    BOOL web = [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
    if (web && _openAddress)
        _openAddress(address);
    else
        [[UIApplication sharedApplication] openURL:url];
}

@end
