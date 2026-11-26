#import <UIKit/UIKit.h>

/* the picture behind the start page: one file in the profile, made from a photo of the person and cut down to what the screen can show */
@interface YZBackground : NSObject
/* the stored picture, nil without one */
+ (UIImage *)image;
/* the mean lightness of the picture, 0 (black) to 1 (white), taken from a copy of 16 by 16 pixels. a picture that cannot be read counts as dark and is logged */
+ (CGFloat)lightnessOfImage:(UIImage *)picture;
/* stores the picture, scaled so its long side is at most the long side of this device's screen in pixels, as a jpeg. NO when it could not be written */
+ (BOOL)storePicture:(UIImage *)picture;
/* deletes the picture and the stamp of it */
+ (void)remove;
@end
