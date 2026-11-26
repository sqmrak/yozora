#pragma once

#ifdef __cplusplus
extern "C" {
#endif
void yozora_metal_set_allowed(int allowed);
void yozora_metal_trim(void);
typedef struct {
    /* 0 off (the setting, YOZORA_METAL=0 or the app is in the background), 1 ready, 2 the device or a surface could not be made, 3 on and not asked yet */
    int state;
    /* tiles painted by the gpu, and tiles that went to the cpu while the gpu was on */
    unsigned long long tiles;
    unsigned long long fallbacks;
    /* bytes of IOSurface held by the pool */
    unsigned long long surface_bytes;
} yozora_metal_info;
void yozora_metal_info_read(yozora_metal_info *info);
#ifdef __cplusplus
}

#include <skia/core/SkImage.h>

class SkCanvas;
sk_sp<SkImage> yozora_metal_tile(int width, int height, size_t budget, SkImage* previous, void* previousSurface,
    void (*draw)(SkCanvas&, SkImage*, void*), void* job, void** contents, bool* empty, bool* opaque);
#endif
