#import "YZBackground.h"
#import "YZSettings.h"
#import "YZStore.h"
#import "yozora_blur.h"
#import <CoreGraphics/CoreGraphics.h>

static UIImage *YZCachedPicture;
static NSInteger YZCachedStamp = -1;

static NSString *YZBackgroundPath(void) {
    return [[YZStore profileDirectory] stringByAppendingPathComponent:@"home-background.jpg"];
}

@implementation YZBackground

+ (UIImage *)image {
    NSInteger stamp = [YZSettings homeBackgroundStamp];
    if (!stamp)
        return nil;
    if (stamp != YZCachedStamp) {
        [YZCachedPicture release];
        YZCachedPicture = [[UIImage imageWithContentsOfFile:YZBackgroundPath()] retain];
        YZCachedStamp = stamp;
    }
    return YZCachedPicture;
}

+ (CGFloat)lightnessOfImage:(UIImage *)picture {
    enum { side = 16 };
    uint8_t pixels[side * side * 4];
    memset(pixels, 0, sizeof pixels);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = picture.CGImage ? CGBitmapContextCreate(pixels, side, side, 8, side * 4, space, kCGImageAlphaPremultipliedLast) : NULL;
    CGColorSpaceRelease(space);
    if (!context) {
        NSLog(@"yozora: the lightness of the background could not be read");
        return 0;
    }
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, side, side), picture.CGImage);
    CGContextRelease(context);
    return yozora_luma_average(pixels, side, side, side * 4) / 255.0f;
}

+ (BOOL)storePicture:(UIImage *)picture {
    CGSize size = picture.size;
    if (size.width < 1 || size.height < 1)
        return NO;
    // a photo is decoded at full size only once, here: the screen never needs more than its own long side
    CGSize screen = [[UIScreen mainScreen] bounds].size;
    CGFloat pixels = MAX(screen.width, screen.height) * [[UIScreen mainScreen] scale];
    CGFloat longSide = MAX(size.width, size.height);
    CGFloat factor = longSide > pixels ? pixels / longSide : 1;
    CGSize target = CGSizeMake(MAX((CGFloat)1, round(size.width * factor)), MAX((CGFloat)1, round(size.height * factor)));
    UIGraphicsBeginImageContextWithOptions(target, YES, 1);
    [picture drawInRect:CGRectMake(0, 0, target.width, target.height)];
    UIImage *scaled = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    NSData *data = scaled ? UIImageJPEGRepresentation(scaled, 0.82f) : nil;
    if (![data length])
        return NO;
    NSString *path = YZBackgroundPath();
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:&error]
        || ![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        NSLog(@"yozora: the background was not written: %@", error);
        return NO;
    }
    // the photo is stored away from the main thread, the stamp posts the settings notification that the screens answer with UIKit
    if ([NSThread isMainThread])
        [YZSettings noteHomeBackgroundChanged:YES];
    else
        dispatch_sync(dispatch_get_main_queue(), ^{ [YZSettings noteHomeBackgroundChanged:YES]; });
    return YES;
}

+ (void)remove {
    NSError *error = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:YZBackgroundPath()] && ![[NSFileManager defaultManager] removeItemAtPath:YZBackgroundPath() error:&error])
        NSLog(@"yozora: the background was not deleted: %@", error);
    [YZSettings noteHomeBackgroundChanged:NO];
}

@end
