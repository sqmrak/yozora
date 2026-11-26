#import <UIKit/UIKit.h>

/* posted on the main thread when the icon of a site arrived, the object is the class and the userInfo has the host under @"host" */
extern NSString *const YZFaviconDidLoadNotification;

/* site icons for tiles, lists and tab cards: the favicon.ico over https, read once and kept in the caches
   directory, a site without one is not asked again for three days. nothing is asked in the private session,
   so the host of a private page goes nowhere */
typedef enum {
    /* a glyph or a logo with transparent parts: it stands on the plate with room around it */
    YZIconShapeGlyph,
    /* a square of at least 96 pixels with no transparency: it fills the whole tile */
    YZIconShapeFull,
    /* under 64 pixels, a favicon: it keeps about its own size on the plate instead of becoming a blur */
    YZIconShapeSmall
} YZIconShape;

@interface YZFavicons : NSObject
/* the icon of the address or nil. one that is not known to be absent is fetched in the background and a
   notification says when it is there */
+ (UIImage *)iconForURL:(NSString *)url;
/* the host of an address in lower case, nil when it has none */
+ (NSString *)hostOfURL:(NSString *)url;
/* the tile an icon stands on: the card color of the theme, so a dark theme has a dark tile. an icon that is
   a bare glyph and would vanish on it (a black logo on a dark tile, a white one on a light tile) gets the
   other tile instead. an icon that fills its square is left on the card */
+ (UIColor *)tileColorForIcon:(UIImage *)icon;
+ (YZIconShape)shapeOfIcon:(UIImage *)icon;
@end
