#include "yozora_blur.h"

uint32_t yozora_luma_average(const uint8_t *pixels, uint32_t width, uint32_t height, size_t stride)
{
    if (!pixels || !width || !height || stride < (size_t)width * 4u)
        return 0;
    uint64_t sum = 0;
    for (uint32_t y = 0; y < height; ++y) {
        const uint8_t *row = pixels + (size_t)y * stride;
        for (uint32_t x = 0; x < width; ++x)
            sum += (77u * row[(size_t)x * 4u] + 150u * row[(size_t)x * 4u + 1] + 29u * row[(size_t)x * 4u + 2]) >> 8;
    }
    uint64_t count = (uint64_t)width * height;
    return (uint32_t)((sum + count / 2) / count);
}
