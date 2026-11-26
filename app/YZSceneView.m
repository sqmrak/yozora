#import "YZSceneView.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

@interface YZSceneNode : NSObject {
@public
    CALayer *layer;
    CALayer *contents;
    CALayer *children;
    CALayer *canvas;
    NSMutableDictionary *tiles;
    NSMutableDictionary *pixels;
    uint32_t background;
    BOOL hasBackground;
}
- (id)initWithPreserves3D:(BOOL)preserves;
@end

@implementation YZSceneNode
- (id)initWithPreserves3D:(BOOL)preserves {
    self = [super init];
    if (!self)
        return nil;
    layer = preserves ? [[CATransformLayer alloc] init] : [[CALayer alloc] init];
    contents = [[CALayer alloc] init];
    children = [[CALayer alloc] init];
    contents.anchorPoint = CGPointZero;
    children.anchorPoint = CGPointZero;
    [layer addSublayer:contents];
    [layer addSublayer:children];
    tiles = [[NSMutableDictionary alloc] init];
    pixels = [[NSMutableDictionary alloc] init];
    return self;
}
- (void)dealloc {
    [layer removeFromSuperlayer];
    [layer release];
    [contents release];
    [children release];
    [canvas removeFromSuperlayer];
    [canvas release];
    [tiles release];
    [pixels release];
    [super dealloc];
}
@end

static CATransform3D YZSceneTransform(const double *values) {
    CATransform3D result;
    result.m11 = values[0]; result.m12 = values[1]; result.m13 = values[2]; result.m14 = values[3];
    result.m21 = values[4]; result.m22 = values[5]; result.m23 = values[6]; result.m24 = values[7];
    result.m31 = values[8]; result.m32 = values[9]; result.m33 = values[10]; result.m34 = values[11];
    result.m41 = values[12]; result.m42 = values[13]; result.m43 = values[14]; result.m44 = values[15];
    return result;
}

static void YZSceneReleasePixels(void *context, const void *data, size_t size) {
    (void)data;
    (void)size;
    yozora_image_release(context);
}

@implementation YZSceneView
- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    self.userInteractionEnabled = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backgroundColor = [UIColor clearColor];
    self.opaque = NO;
    _nodes = [[NSMutableDictionary alloc] init];
    return self;
}

- (void)dealloc {
    [self clearScene];
    [_nodes release];
    [super dealloc];
}

- (void)clearScene {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (YZSceneNode *node in [_nodes allValues])
        [node->layer removeFromSuperlayer];
    [_nodes removeAllObjects];
    [CATransaction commit];
    yozora_scene_release(_scene);
    _scene = NULL;
}

- (void)showScene:(yozora_scene *)scene {
    static CGColorSpaceRef space;
    if (!space)
        space = CGColorSpaceCreateDeviceRGB();
    if (!scene || *yozora_scene_error(scene))
        return;
    yozora_scene_retain(scene);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    NSMutableSet *present = [NSMutableSet set];
    const yozora_scene_layer *states = yozora_scene_layers(scene);
    unsigned count = yozora_scene_layer_count(scene);
    NSMutableDictionary *orders = [NSMutableDictionary dictionary];
    for (unsigned i = 0; i < count; ++i) {
        const yozora_scene_layer *state = &states[i];
        NSNumber *key = [NSNumber numberWithUnsignedLongLong:state->id];
        [present addObject:key];
        YZSceneNode *node = [_nodes objectForKey:key];
        if (node && [node->layer isKindOfClass:[CATransformLayer class]] != !!state->preserves_3d) {
            [_nodes removeObjectForKey:key];
            node = nil;
        }
        if (!node) {
            node = [[[YZSceneNode alloc] initWithPreserves3D:state->preserves_3d] autorelease];
            [_nodes setObject:node forKey:key];
        }
        CALayer *layer = node->layer;
        CGPoint anchor = CGPointMake(state->anchor_x, state->anchor_y);
        CGRect bounds = CGRectMake(state->bounds_x, state->bounds_y, state->width, state->height);
        CGPoint position = CGPointMake(state->x + state->anchor_x * state->width, state->y + state->anchor_y * state->height);
        CATransform3D transform = YZSceneTransform(state->transform);
        CATransform3D childrenTransform = YZSceneTransform(state->children_transform);
        if (!CGPointEqualToPoint(layer.anchorPoint, anchor))
            layer.anchorPoint = anchor;
        if (layer.anchorPointZ != state->anchor_z)
            layer.anchorPointZ = state->anchor_z;
        if (!CGRectEqualToRect(layer.bounds, bounds))
            layer.bounds = bounds;
        if (!CGPointEqualToPoint(layer.position, position))
            layer.position = position;
        if (!CATransform3DEqualToTransform(layer.transform, transform))
            layer.transform = transform;
        if (layer.opacity != state->opacity)
            layer.opacity = state->opacity;
        if (layer.doubleSided != !!state->backface_visible)
            layer.doubleSided = state->backface_visible;
        if (layer.masksToBounds != !!state->clips)
            layer.masksToBounds = state->clips;
        if (node->contents.hidden != !!state->hidden)
            node->contents.hidden = state->hidden;
        if (!CATransform3DEqualToTransform(node->children.sublayerTransform, childrenTransform))
            node->children.sublayerTransform = childrenTransform;
        if (!node->hasBackground || node->background != state->background) {
            uint32_t color = state->background;
            layer.backgroundColor = [UIColor colorWithRed:((color >> 16) & 255) / 255.0f
                                                    green:((color >> 8) & 255) / 255.0f
                                                     blue:(color & 255) / 255.0f alpha:(color >> 24) / 255.0f].CGColor;
            node->background = color;
            node->hasBackground = YES;
        }
        NSMutableSet *animationKeys = state->animation_count ? [NSMutableSet set] : nil;
        for (unsigned j = 0; j < state->animation_count; ++j) {
            const yozora_scene_animation *source = &state->animations[j];
            NSString *animationKey = [NSString stringWithFormat:@"yz:%llu", (unsigned long long)source->id];
            [animationKeys addObject:animationKey];
            if ([layer animationForKey:animationKey])
                continue;
            CAKeyframeAnimation *animation = [CAKeyframeAnimation animationWithKeyPath:source->property == 1 ? @"opacity" : @"transform"];
            NSMutableArray *values = [NSMutableArray array];
            NSMutableArray *times = [NSMutableArray array];
            NSMutableArray *timing = [NSMutableArray array];
            for (unsigned k = 0; k < source->count; ++k) {
                const yozora_scene_keyframe *frame = &source->frames[k];
                [times addObject:[NSNumber numberWithDouble:frame->time]];
                if (source->property == 1)
                    [values addObject:[NSNumber numberWithDouble:frame->values[0]]];
                else
                    [values addObject:[NSValue valueWithCATransform3D:YZSceneTransform(frame->values)]];
                if (k + 1 < source->count)
                    [timing addObject:[CAMediaTimingFunction functionWithControlPoints:frame->bezier[0] :frame->bezier[1] :frame->bezier[2] :frame->bezier[3]]];
            }
            animation.values = values;
            animation.keyTimes = times;
            animation.timingFunctions = timing;
            animation.duration = source->duration;
            animation.autoreverses = source->alternate;
            animation.repeatCount = source->iterations < 0 ? HUGE_VALF : source->iterations / (source->alternate ? 2 : 1);
            animation.removedOnCompletion = !(source->fill & 1);
            if (source->fill == 3)
                animation.fillMode = kCAFillModeBoth;
            else if (source->fill == 2)
                animation.fillMode = kCAFillModeBackwards;
            else if (source->fill == 1)
                animation.fillMode = kCAFillModeForwards;
            animation.beginTime = [layer convertTime:CACurrentMediaTime() fromLayer:nil] - source->elapsed;
            if (source->paused) {
                animation.speed = 0;
                animation.beginTime = 0;
                animation.timeOffset = source->elapsed;
            }
            [layer addAnimation:animation forKey:animationKey];
        }
        for (NSString *key in [layer animationKeys]) {
            if ([key hasPrefix:@"yz:"] && ![animationKeys containsObject:key])
                [layer removeAnimationForKey:key];
        }
        NSMutableSet *tileKeys = state->tile_count ? [NSMutableSet set] : nil;
        for (unsigned j = 0; j < state->tile_count; ++j) {
            const yozora_scene_tile *tile = &state->tiles[j];
            // one number per tile place, a string per tile per frame cost main thread time while the page
            // scrolled
            NSNumber *tileKey = [NSNumber numberWithLongLong:(long long)lroundf(tile->x) * 4294967296LL + (long long)(unsigned int)(int)lroundf(tile->y)];
            [tileKeys addObject:tileKey];
            NSValue *previous = [node->pixels objectForKey:tileKey];
            CALayer *picture = [node->tiles objectForKey:tileKey];
            if (picture) {
                CGPoint position = CGPointMake(tile->x, tile->y);
                CGRect bounds = CGRectMake(0, 0, tile->width / tile->scale, tile->height / tile->scale);
                if (!CGPointEqualToPoint(picture.position, position))
                    picture.position = position;
                if (!CGRectEqualToRect(picture.bounds, bounds))
                    picture.bounds = bounds;
                if (picture.contentsScale != tile->scale)
                    picture.contentsScale = tile->scale;
                if (previous && [previous pointerValue] == (tile->surface ? tile->surface : (void *)tile->image))
                    continue;
            }
            // unchanged tiles keep only their own pixels alive while other layers animate
            CGImageRef image = NULL;
            if (!tile->surface) {
                yozora_image_retain(tile->image);
                CGDataProviderRef provider = CGDataProviderCreateWithData(tile->image, tile->pixels, tile->row_bytes * tile->height, YZSceneReleasePixels);
                if (!provider) {
                    yozora_image_release(tile->image);
                    NSLog(@"yozora: cannot allocate scene image provider");
                    continue;
                }
                image = CGImageCreate(tile->width, tile->height, 8, 32, tile->row_bytes, space,
                    kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst, provider, NULL, NO, kCGRenderingIntentDefault);
                CGDataProviderRelease(provider);
                if (!image) {
                    NSLog(@"yozora: cannot allocate scene image");
                    continue;
                }
            }
            if (!picture) {
                picture = [CALayer layer];
                picture.anchorPoint = CGPointZero;
                [node->contents addSublayer:picture];
                [node->tiles setObject:picture forKey:tileKey];
            }
            picture.position = CGPointMake(tile->x, tile->y);
            picture.bounds = CGRectMake(0, 0, tile->width / tile->scale, tile->height / tile->scale);
            picture.contentsScale = tile->scale;
            picture.contents = tile->surface ? (id)tile->surface : (id)image;
            [node->pixels setObject:[NSValue valueWithPointer:(tile->surface ? tile->surface : (void *)tile->image)] forKey:tileKey];
            if (image)
                CGImageRelease(image);
        }
        for (NSNumber *tileKey in [node->tiles allKeys]) {
            if (![tileKeys containsObject:tileKey]) {
                [[node->tiles objectForKey:tileKey] removeFromSuperlayer];
                [node->tiles removeObjectForKey:tileKey];
                [node->pixels removeObjectForKey:tileKey];
            }
        }
        // a WebGL canvas: the layer that the context presents its frames into. its bounds are the pixels of the
        // canvas and belong to the context, so it is placed and scaled by position and transform only
        yozora_canvas *surface = state->canvas;
        CALayer *canvasLayer = surface && surface->layer && surface->width && surface->height ? (CALayer *)surface->layer : nil;
        if (canvasLayer != node->canvas) {
            [node->canvas removeFromSuperlayer];
            [node->canvas release];
            node->canvas = [canvasLayer retain];
        }
        if (canvasLayer) {
            CGPoint position = CGPointMake(state->canvas_x, state->canvas_y);
            CATransform3D scale = CATransform3DMakeScale(state->canvas_width / surface->width, state->canvas_height / surface->height, 1);
            if (!CGPointEqualToPoint(canvasLayer.position, position))
                canvasLayer.position = position;
            if (!CATransform3DEqualToTransform(canvasLayer.transform, scale))
                canvasLayer.transform = scale;
            // tiles that come later are added over it, so it is put last again whenever it is not
            if (canvasLayer.superlayer != node->contents || [node->contents.sublayers lastObject] != canvasLayer)
                [node->contents addSublayer:canvasLayer];
        }
    }
    for (NSNumber *key in [_nodes allKeys]) {
        if (![present containsObject:key])
            [_nodes removeObjectForKey:key];
    }
    for (unsigned i = 0; i < count; ++i) {
        const yozora_scene_layer *state = &states[i];
        YZSceneNode *node = [_nodes objectForKey:[NSNumber numberWithUnsignedLongLong:state->id]];
        YZSceneNode *parent = [_nodes objectForKey:[NSNumber numberWithUnsignedLongLong:state->parent]];
        CALayer *host = parent ? parent->children : self.layer;
        if (!parent || parent->layer.mask != node->layer) {
            NSNumber *parentKey = [NSNumber numberWithUnsignedLongLong:state->parent];
            NSUInteger index = [[orders objectForKey:parentKey] unsignedIntegerValue];
            NSArray *siblings = host.sublayers;
            // scrolling changes geometry, it does not need to reparent an unchanged tree
            if (node->layer.superlayer != host || index >= [siblings count] || [siblings objectAtIndex:index] != node->layer)
                [host insertSublayer:node->layer atIndex:(unsigned)index];
            [orders setObject:[NSNumber numberWithUnsignedInteger:index + 1] forKey:parentKey];
        }
        YZSceneNode *mask = [_nodes objectForKey:[NSNumber numberWithUnsignedLongLong:state->mask]];
        CALayer *maskLayer = mask ? mask->layer : nil;
        if (node->layer.mask != maskLayer) {
            [maskLayer removeFromSuperlayer];
            node->layer.mask = maskLayer;
        }
    }
    [CATransaction commit];
    yozora_scene_release(_scene);
    _scene = scene;
}

- (CALayer *)contentsLayerForLayerID:(uint64_t)identifier {
    if (!identifier)
        return nil;
    YZSceneNode *node = [_nodes objectForKey:[NSNumber numberWithUnsignedLongLong:identifier]];
    return node ? node->contents : nil;
}

- (void)scrollWithCore:(yozora_core *)core {
    if (!_scene)
        return;
    yozora_scroll_state scroll;
    yozora_core_read_scroll_state(core, &scroll);
    CGFloat delta = scroll.root_y - yozora_scene_scroll_y(_scene);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    const yozora_scene_layer *states = yozora_scene_layers(_scene);
    for (unsigned i = 0; i < yozora_scene_layer_count(_scene); ++i) {
        const yozora_scene_layer *state = &states[i];
        if (!state->scroll_id && !state->fixed && !state->sticky.scroll_id)
            continue;
        YZSceneNode *node = [_nodes objectForKey:[NSNumber numberWithUnsignedLongLong:state->id]];
        CGFloat dx = 0, dy = state->fixed ? delta : 0;
        int x, y;
        if (state->scroll_id && yozora_scroll_state_offset(&scroll, state->scroll_id, &x, &y)) {
            dx -= x - state->scroll_x;
            dy -= y - state->scroll_y;
        }
        if (state->sticky.scroll_id && yozora_scroll_state_offset(&scroll, state->sticky.scroll_id, &x, &y)) {
            float stickyX, stickyY;
            yozora_sticky_delta(&state->sticky, x - state->sticky.scroll_x, y - state->sticky.scroll_y, &stickyX, &stickyY);
            dx += stickyX;
            dy += stickyY;
        }
        CGPoint position = CGPointMake(state->x + state->anchor_x * state->width + dx, state->y + state->anchor_y * state->height + dy);
        if (!CGPointEqualToPoint(node->layer.position, position))
            node->layer.position = position;
    }
    [CATransaction commit];
}
@end
