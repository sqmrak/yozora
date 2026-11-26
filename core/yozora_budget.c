#include "yozora_budget.h"

unsigned yozora_raster_budget_mb(unsigned memory_mb)
{
    unsigned budget;
    if (memory_mb < 400)
        return 16;
    if (memory_mb <= 512)
        return 24;
    /* the hundreds are divided first so the largest memory value cannot overflow */
    budget = memory_mb / 100 * 6 + memory_mb % 100 * 6 / 100;
    if (budget < 48)
        return 48;
    if (budget > YOZORA_RASTER_BUDGET_MAX_MB)
        return YOZORA_RASTER_BUDGET_MAX_MB;
    return budget;
}

void yozora_metal_budget(size_t raster_bytes, size_t *surface_bytes, size_t *scratch_bytes)
{
    size_t scratch = raster_bytes / 4;
    *scratch_bytes = scratch;
    *surface_bytes = raster_bytes - scratch;
}

void yozora_memory_limits_for(unsigned memory_mb, yozora_memory_limits *out)
{
    if (!out)
        return;
    if (memory_mb < 400) {
        yozora_memory_limits small = { YOZORA_TIER_SMALL, 8, 1024, 6, 130, 0 };
        *out = small;
    } else if (memory_mb <= 512) {
        yozora_memory_limits constrained = { YOZORA_TIER_CONSTRAINED, 8, 1024, 6, 150, 0 };
        *out = constrained;
    } else if (memory_mb < 900) {
        yozora_memory_limits medium = { YOZORA_TIER_MEDIUM, 16, 2048, 12, 150, 0 };
        *out = medium;
    } else if (memory_mb < 1700) {
        yozora_memory_limits large = { YOZORA_TIER_LARGE, 48, 4096, 24, 180, 0 };
        *out = large;
    } else if (memory_mb < 3400) {
        yozora_memory_limits roomy = { YOZORA_TIER_ROOMY, 96, 8192, 48, 200, 1 };
        *out = roomy;
    } else {
        yozora_memory_limits spacious = { YOZORA_TIER_SPACIOUS, 192, 16384, 96, 220, 1 };
        *out = spacious;
    }
}

unsigned yozora_raster_threads_for(unsigned cores)
{
    if (cores >= 6)
        return 4;
    if (cores >= 4)
        return 3;
    return cores >= 2 ? 2 : 1;
}
