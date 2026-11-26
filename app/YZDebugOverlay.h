#import <UIKit/UIKit.h>
#include "yozora_core.h"

/* process numbers in a corner for the debug setting, every number is measured. the GPU line is what the core counts
   (Metal tiles and the tiles that went to the cpu), the system has no public reading of the load of the chip */
@interface YZDebugOverlay : UIView {
    NSMutableArray *_keys;
    NSMutableArray *_values;
    UIView *_dot;
    NSString *_site;
    NSString *_device;
    UILabel *_deviceLabel;
    UILabel *_siteLabel;
    unsigned _frames;
    unsigned _scenes;
    CFTimeInterval _windowStart;
    double _fps;
    double _sceneRate;
    long long _cpuWindowMicros;
    long long _previousPaintMs;
}
/* the host of the page on screen, nil for none */
@property(nonatomic, copy) NSString *site;
+ (CGSize)preferredSize;
/* once for each frame of the display link, and once for each scene put on screen */
- (void)noteFrame;
- (void)noteScene;
/* reads the system and the core and redraws, a few times a second is enough. core may be NULL */
- (void)refreshWithCore:(yozora_core *)core;
@end
