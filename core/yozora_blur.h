#ifndef YOZORA_BLUR_H
#define YOZORA_BLUR_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* the mean lightness, 0 to 255, of 4 channel 8 bit pixels in the order red, green, blue, alpha (alpha is not read): the luma of each pixel with the weights
   77, 150 and 29 over 256, summed over the picture and rounded. 0 for an empty size or a stride shorter than a row. the start page uses it to take dark
   or light lettering over a photo */
uint32_t yozora_luma_average(const uint8_t *pixels, uint32_t width, uint32_t height, size_t stride);

#ifdef __cplusplus
}
#endif

#endif
