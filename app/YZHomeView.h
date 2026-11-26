#import <UIKit/UIKit.h>

@protocol YZHomeViewDelegate;

/* the page of a blank tab: the most visited sites and the bookmarks as tiles, or in the private session a note about what it keeps */
@interface YZHomeView : UIScrollView {
    id<YZHomeViewDelegate> _homeDelegate;
    NSArray *_sites;
    NSArray *_bookmarks;
    CGFloat _builtWidth;
    BOOL _contentDirty;
    NSMutableArray *_siteTiles;
    NSMutableArray *_bookmarkTiles;
    UILabel *_bookmarksHeading;
    // the ground behind the tiles, the bars and the strips of the screen: the surface with the photo or the gradient on it. the browser
    // gives it the whole screen
    UIView *_ground;
    // the photo of the person on the ground
    UIImageView *_backdrop;
    // lettering over a photo: 0 the colors of the theme, 1 dark over a light photo, 2 light over a dark one
    int _photoInk;
    // the picture and the name at the top of the start page
    UIImageView *_brandImage;
    // the pill at the end of the page that says the blocker is on, as the start page of Firefox does
    UIView *_protectedPill;
    UIImageView *_protectedIcon;
    UILabel *_protectedLabel;
    UIImageView *_brandGlow;
    UILabel *_brandName;
    // the search line under the name: a tap opens the address field
    UIButton *_searchBar;
    UIImageView *_searchMark;
    UILabel *_searchHint;
    // the page of a private tab: a glyph, a title and what the session keeps and drops
    UIView *_heroDisc;
    UIImageView *_heroIcon;
    UILabel *_heroTitle;
    UILabel *_heroText;
    // the gradient of the accent on the ground in the modern design when no photo is set
    UIView *_gradient;
    // the colors at the top and the bottom edge of the ground, for the clock of the status bar, and the size they were taken at
    UIColor *_topEdgeColor;
    UIColor *_bottomEdgeColor;
    CGSize _edgeSize;
    // a tile lifted by a held finger: it follows the finger and the other tiles of its section (dragTiles, one of the two arrays) make room.
    // dragOrder is the section in the order the tiles stand now, dragLead the plus tile that leads the visited sites and never moves
    UIButton *_dragTile;
    NSMutableArray *_dragTiles;
    NSMutableArray *_dragOrder;
    NSUInteger _dragLead;
    CGPoint _dragGrab;
    CGPoint _dragStart;
    BOOL _dragMoved;
    // where the tiles of each section begin, under the heading, so a dragged tile finds the slots of its section
    CGFloat _siteTop;
    CGFloat _bookmarkTop;
}
@property(nonatomic, assign) id<YZHomeViewDelegate> homeDelegate;
/* sites and bookmarks are YZRecord arrays */
- (void)showSites:(NSArray *)sites bookmarks:(NSArray *)bookmarks;
- (void)animateContents;
/* the order of the blocks or the favorites changed: lays the page out again with the tiles and the logo sliding to their places */
- (void)relayoutAnimated;
/* the ground of the page: the surface, the gradient or the photo. the browser puts it under the page and the bars, gives it the whole screen,
   shows and hides it with the page and calls groundResized after a new frame */
@property(nonatomic, readonly) UIView *groundView;
- (void)groundResized;
/* the color at the top and at the bottom edge of the ground, so the clock of the status bar is dark over a light one and light over a dark one */
@property(nonatomic, readonly) UIColor *topEdgeColor;
@property(nonatomic, readonly) UIColor *bottomEdgeColor;
/* updates the colors and texts of the chosen theme and language */
- (void)applyTheme;
@end

@protocol YZHomeViewDelegate <NSObject>
- (void)homeView:(YZHomeView *)view didSelectURL:(NSString *)url;
/* a finger held a place of the page, point is in the coordinates of the view that holds the page. siteURL is the address of the tile under the
   finger, nil on any other place, favorite says the tile is a favorite and not a visited site. a held tile that was dragged to a new place
   is stored in its new order by the page and is not reported here */
- (void)homeView:(YZHomeView *)view didHoldAt:(CGPoint)point siteURL:(NSString *)siteURL favorite:(BOOL)favorite;
/* the plus tile was tapped */
- (void)homeViewDidTapAdd:(YZHomeView *)view;
/* the search line under the logo was tapped */
- (void)homeViewDidTapSearch:(YZHomeView *)view;
@end
