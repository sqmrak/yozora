#ifndef YOZORA_BUDGET_H
#define YOZORA_BUDGET_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define YOZORA_RASTER_BUDGET_MAX_MB 512

/* what the memory of the phone allows the engine to keep. the tiers are the phones of 128 MB and one core up to 6 GB and more. the memory a phone
   reports is a little under what it has (a 3 GB iPhone says about 2.8 GB, a 4 GB one about 3.8 GB), so the limits sit under the round numbers */
typedef enum {
    YOZORA_TIER_SMALL,
    YOZORA_TIER_CONSTRAINED,
    YOZORA_TIER_MEDIUM,
    YOZORA_TIER_LARGE,
    YOZORA_TIER_ROOMY,
    YOZORA_TIER_SPACIOUS
} yozora_memory_tier;

typedef struct {
    yozora_memory_tier tier;
    /* the cache of decoded resources, the cache of glyphs, the scripts waiting to be written to the bytecode cache */
    unsigned resource_cache_mb;
    unsigned font_cache_kb;
    unsigned bytecode_pending_mb;
    /* how far the script heap may grow over its live size before a collection, in percent (the mini vm, which has no jit, uses it) */
    unsigned heap_growth_percent;
    /* the optimizing compiler of the engine may run: its compilation needs memory and time that small phones do not have */
    int ftl;
} yozora_memory_limits;

/* the limits for a phone of memory_mb. under 400: 8 MB of resources, 1 MB of glyphs, 6 MB of bytecode, growth 130. up to 512: the same with growth 150.
   under 900: 16, 2, 12, 150. under 1700: 48, 4, 24, 180. under 3400: 96, 8, 48, 200, with the optimizing compiler. from 3400: 192, 16, 96, 220 */
void yozora_memory_limits_for(unsigned memory_mb, yozora_memory_limits *out);

/* the pixel budget of one page core in MiB. the raster cache and up to four held scenes can each reach it, so
   the worst case is about five times it, kept near 30 percent of memory: 16 below 400 MiB, 24 up to 512, 6
   percent above, from 48 to YOZORA_RASTER_BUDGET_MAX_MB */
unsigned yozora_raster_budget_mb(unsigned memory_mb);

/* the surface pool and ganesh scratch resources share one raster budget across pages */
void yozora_metal_budget(size_t raster_bytes, size_t *surface_bytes, size_t *scratch_bytes);

/* the threads that paint tiles in all, the one that owns the pass included: 1 on a single core, 2 on two or three, 3 on four or five, 4 from six cores
   (the phones of the A11 and later have six). 0 cores count as one */
unsigned yozora_raster_threads_for(unsigned cores);

#ifdef __cplusplus
}
#endif
#endif
