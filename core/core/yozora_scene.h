#ifndef YOZORA_SCENE_H
#define YOZORA_SCENE_H

#include <stddef.h>
#include <stdint.h>
#include "../yozora_render_plan.h"
#include "yozora_canvas.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct yozora_scene yozora_scene;
typedef struct yozora_image yozora_image;
/* the most keyframes one compositor animation holds, a turning or scaling transform is sampled into many (see
   GraphicsLayerYozora.cpp) */
#define YOZORA_ANIMATION_MAX_FRAMES 2048
typedef struct {
    double time;
    double values[16];
    float bezier[4];
} yozora_scene_keyframe;
typedef struct {
    uint64_t id;
    /* 1 is opacity, 2 is a transform: a translation, or any other transform sampled into keyframes */
    unsigned property, count;
    double duration, iterations, elapsed;
    int alternate, fill, paused;
    const yozora_scene_keyframe *frames;
} yozora_scene_animation;
typedef struct {
    const uint8_t *pixels;
    size_t row_bytes;
    unsigned width, height;
    float x, y, scale;
    yozora_image *image;
    void *surface;
} yozora_scene_tile;
typedef struct {
    uint64_t id, parent, mask;
    float x, y, width, height;
    float anchor_x, anchor_y, anchor_z;
    float bounds_x, bounds_y;
    double transform[16], children_transform[16];
    float opacity;
    uint32_t background;
    int clips, hidden, backface_visible, preserves_3d;
    /* native clipping stays at the viewport, raster preparation extends beyond it */
    int viewport_clip;
    /* positive ids refer to scrollable blocks, 1 is the main frame */
    uint64_t scroll_id;
    float scroll_x, scroll_y;
    /* a viewport anchored layer compensates its scrolling ancestor */
    int fixed;
    yozora_sticky sticky;
    /* a WebGL canvas that shows its frames in a native layer, NULL for a layer that has none. the surface is
       drawn into canvas_x, canvas_y, canvas_width, canvas_height of this layer, over its tiles. alive while the scene is */
    yozora_canvas *canvas;
    float canvas_x, canvas_y, canvas_width, canvas_height;
    unsigned tile_count;
    const yozora_scene_tile *tiles;
    unsigned animation_count;
    const yozora_scene_animation *animations;
} yozora_scene_layer;

/* evaluates supported compositor animations, returns zero outside their active and fill ranges */
int yozora_scene_animation_values(const yozora_scene_animation *animation, double elapsed, double values[16]);

/* the app checks the renderer layout before reading a tile */
size_t yozora_scene_tile_size(void);

/* scene metadata is immutable, image providers retain individual pixel owners */
void yozora_scene_retain(yozora_scene *scene);
void yozora_scene_release(yozora_scene *scene);
/* providers hold one immutable image, retaining a scene for one unchanged tile would pin every tile in it */
void yozora_image_retain(yozora_image *image);
void yozora_image_release(yozora_image *image);
unsigned yozora_scene_layer_count(const yozora_scene *scene);
const yozora_scene_layer *yozora_scene_layers(const yozora_scene *scene);
int yozora_scene_scroll_y(const yozora_scene *scene);
uint64_t yozora_scene_generation(const yozora_scene *scene);
int yozora_scene_page_zoom(const yozora_scene *scene);
const char *yozora_scene_error(const yozora_scene *scene);

#ifdef __cplusplus
}
#endif
#endif
