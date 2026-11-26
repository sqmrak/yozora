# performance

## memory tiers

the phones this runs on go from 128 MB and one core to 2 GB and more. caches and the reach of tiles follow the memory (`memory_tier()` in `core/core/yozora_core.cpp`):

| tier | memory | resource cache | font cache | pending bytecode | script heap growth |
|---|---|---|---|---|---|
| small | under 400 MB | 8 MB | 1 MB | 6 MB | 1.3 |
| constrained | 400 to 512 MB | 8 MB | 1 MB | 6 MB | 1.5 |
| medium | up to 900 MB | 16 MB | 2 MB | 12 MB | 1.5 |
| large | 900 MB and more | 48 MB | 4 MB | 24 MB | 1.8 |

the raster budget is separate, see [graphics](graphics.md). the limits are not one budget of the process: live scenes, the dom, the script heap and uikit add to them.

## memory warnings

handled without waiting for webcore, see [core](core.md). a memory warning drops the raster caches, the pictures of other tabs and the previews the tray holds.

## what the numbers were

measurements were taken on real armv7 hardware with about 500 MB and two cores, on local pages served over wifi, three runs each, medians. they are diagnostics, not ratings.

- the constrained tier lowered the resource cache from 16 to 8 MB, the font cache from 2 to 1 MB and pending bytecode from 12 to 6 MB. the process footprint after a scroll scenario fell by about 27 percent without changing the resolution and without shortening the scroll reserve
- an economy mode that rasters at a lower resolution cut footprint by 31 percent and raster time by 44 percent, and it costs quality, so it is a setting and not a default
- javascript with the jit against without it on local loads: 3 million property passes 266 ms against 3019 ms, 30 thousand regexp replacements 148 ms against 331 ms, creating 1000 elements and forcing layout the same
- the scroll snapshot (`yozora_core_read_scroll_state`) replaced up to 1025 lock acquisitions per update with one. 5000 updates of 512 queries: 9 times faster for the root, 4 times for nested areas, on the same data
- reusing tab cards: 200 layout passes of the tray 1794 ms before and 20 ms after, with no card rebuilt. this measures one layout path, not frame rate

## what keeps it cheap

- an unchanged page skips layout and recording, raster work never enters webcore
- repeated viewport sizes keep the recordings and the raster cache
- tiles that nothing can see are not made, tiles outside the budget are the margin only
- jpeg is decoded at the drawn size
- an animation of opacity or transform runs in core animation
- cards, tiles and rows are reused, entrances are limited to eight items
- bytecode of big scripts is cached, the key is text and host. when the app leaves the foreground the log gets one line with the scripts loaded from the cache, the stale ones replaced, the files stored and the bytes written
- code that pages seldom run (WebCore `Modules`, the inspector, accessibility, xml, crypto and the like, 141 bundles) is built for size with `-Os`, the rest of the engine stays at `-O3`; the binary of armv7 is 670 KB smaller than the one of 2.54.1 with this, see [build](build.md)
- the start page photo is read once per stamp and kept
- the home page keeps its headings and at most eight buttons per section and changes their targets

## the cost of the blocker

14 microseconds per request with 3500 rules on the host, see [adblock](adblock.md).

## things to try

`YOZORA_DEVICE_MEMORY_MB` makes the core act as if the phone had that much memory, which is how a tier is compared on one device. `YOZORA_RENDER_BUSY=1` prints the share of each second the core thread worked, `YOZORA_RENDER_PROFILE` samples threads, see [debug](debug.md).
