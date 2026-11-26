#include "yozora_budget.h"
#include <limits.h>
#include <stdio.h>

static int failures;

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "test_budget: %s:%d: %s\n", __FILE__, __LINE__, #condition); ++failures; } } while (0)

int main(void)
{
    static const struct { unsigned memory; unsigned budget; } cases[] = {
        { 0, 16 }, { 128, 16 }, { 256, 16 }, { 399, 16 },
        { 400, 24 }, { 512, 24 },
        { 513, 48 }, { 768, 48 }, { 900, 54 }, { 1024, 61 },
        { 2048, 122 }, { 3072, 184 }, { 4096, 245 }, { 6144, 368 },
        { 8192, 491 }, { 9000, 512 }, { 16384, 512 }, { UINT_MAX, 512 }
    };
    size_t i;
    unsigned previous = 0;
    for (i = 0; i < sizeof cases / sizeof cases[0]; ++i) {
        unsigned budget = yozora_raster_budget_mb(cases[i].memory);
        CHECK(budget == cases[i].budget);
        /* more memory never gives a smaller budget */
        CHECK(budget >= previous);
        previous = budget;
        /* five budgets stay within a third of the memory from 800 MiB, where the floor of 48 MiB no longer dominates */
        if (cases[i].memory >= 800 && cases[i].memory < UINT_MAX)
            CHECK((unsigned long long)budget * 15 <= cases[i].memory);
    }
    {
        static const struct { unsigned memory; yozora_memory_tier tier; unsigned resources; unsigned fonts; unsigned bytecode; unsigned growth; int ftl; } limits[] = {
            { 0, YOZORA_TIER_SMALL, 8, 1024, 6, 130, 0 }, { 399, YOZORA_TIER_SMALL, 8, 1024, 6, 130, 0 },
            { 400, YOZORA_TIER_CONSTRAINED, 8, 1024, 6, 150, 0 }, { 512, YOZORA_TIER_CONSTRAINED, 8, 1024, 6, 150, 0 },
            { 513, YOZORA_TIER_MEDIUM, 16, 2048, 12, 150, 0 }, { 899, YOZORA_TIER_MEDIUM, 16, 2048, 12, 150, 0 },
            { 900, YOZORA_TIER_LARGE, 48, 4096, 24, 180, 0 }, { 1699, YOZORA_TIER_LARGE, 48, 4096, 24, 180, 0 },
            { 1700, YOZORA_TIER_ROOMY, 96, 8192, 48, 200, 1 }, { 2824, YOZORA_TIER_ROOMY, 96, 8192, 48, 200, 1 }, { 3399, YOZORA_TIER_ROOMY, 96, 8192, 48, 200, 1 },
            { 3400, YOZORA_TIER_SPACIOUS, 192, 16384, 96, 220, 1 }, { 3800, YOZORA_TIER_SPACIOUS, 192, 16384, 96, 220, 1 }, { UINT_MAX, YOZORA_TIER_SPACIOUS, 192, 16384, 96, 220, 1 }
        };
        unsigned last_resources = 0, last_bytecode = 0, last_growth = 0;
        int last_tier = -1;
        for (i = 0; i < sizeof limits / sizeof limits[0]; ++i) {
            yozora_memory_limits got = { YOZORA_TIER_SMALL, 99, 99, 99, 99, 99 };
            yozora_memory_limits_for(limits[i].memory, &got);
            CHECK(got.tier == limits[i].tier);
            CHECK(got.resource_cache_mb == limits[i].resources);
            CHECK(got.font_cache_kb == limits[i].fonts);
            CHECK(got.bytecode_pending_mb == limits[i].bytecode);
            CHECK(got.heap_growth_percent == limits[i].growth);
            CHECK(got.ftl == limits[i].ftl);
            /* more memory never lowers a limit or the tier */
            CHECK(got.resource_cache_mb >= last_resources && got.bytecode_pending_mb >= last_bytecode && got.heap_growth_percent >= last_growth);
            CHECK((int)got.tier >= last_tier);
            last_resources = got.resource_cache_mb;
            last_bytecode = got.bytecode_pending_mb;
            last_growth = got.heap_growth_percent;
            last_tier = (int)got.tier;
        }
        yozora_memory_limits_for(2048, NULL);
    }
    {
        static const struct { unsigned cores; unsigned threads; } threads[] = {
            { 0, 1 }, { 1, 1 }, { 2, 2 }, { 3, 2 }, { 4, 3 }, { 5, 3 }, { 6, 4 }, { 8, 4 }, { 64, 4 }, { UINT_MAX, 4 }
        };
        for (i = 0; i < sizeof threads / sizeof threads[0]; ++i)
            CHECK(yozora_raster_threads_for(threads[i].cores) == threads[i].threads);
    }
    {
        const size_t sizes[] = { 0, 1, 1024, 48U * 1024 * 1024, (size_t)-1 };
        for (i = 0; i < sizeof sizes / sizeof sizes[0]; ++i) {
            size_t surfaces, scratch;
            yozora_metal_budget(sizes[i], &surfaces, &scratch);
            CHECK(scratch == sizes[i] / 4);
            CHECK(surfaces == sizes[i] - scratch);
        }
    }
    if (failures)
        return 1;
    puts("budget: tiers, the percent rule, the ceiling, overflow, the memory limits and the raster threads passed");
    return 0;
}
