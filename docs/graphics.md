# graphics

## the pipeline

1. webcore lays the page out and records each graphics layer into a skia recording (`GraphicsLayerYozora.cpp`)
2. the core publishes the newest immutable scene
3. the raster thread (`YozoraRaster.cpp`) paints tiles from it, reuses tiles that did not change and clips a partial repaint to separate damage rectangles
4. the interface consumes the scene (`YZSceneView.m`) as a tree of native core animation layers

on arm64 from ios 11, helpers record ganesh deferred display lists. one serial queue plays them into bgra metal textures backed by iosurface. a compute pass reduces tile alpha to two flags for empty and opaque tiles. the interface receives the surface after completion and assigns it to the tile layer. damage can borrow the previous tile as a texture. snapshots read finished surfaces on demand.

armv7, earlier arm64 systems and the host paint into cpu surfaces. the app closes the metal queue on entering the background. a tile that exceeds the texture budget or fails on metal is painted on the cpu.

## raster

- one to four painting threads according to the number of cores, `YOZORA_RASTER_THREADS` (1 to 4) overrides
- the tiles of a layer go to both threads, the pass waits only after a layer that can cover what lies under it, so occlusion and the order of the tiles are what one thread gives
- tiles are up to 256 by 128 points, edge tiles use their real size
- a queue holds one pending scene, a mutation replaces it while the frame in flight finishes, so nothing starves
- navigation, resize and zoom cancel work that no longer fits
- jpeg is decoded at the drawn size, a png or webp frame above 2^25 pixels is refused

## recording

a layer records half a screen beyond the one screen the raster reaches, so the core thread records again after about half a screen of scrolling and not every 128 points. pixels outside the recording need another webcore pass.

## budgets

the raster cache and the layer pixels of each scene have separate limits:

- 16 MB below 400 MB of memory
- 24 MB from 400 up to 512 MB
- otherwise 6 percent of the memory, from 48 up to 512 MB: 122 MB at 2 GB, 245 MB at 4 GB

the constrained tier (400 to 512 MB) also takes smaller caches elsewhere, see [performance](performance.md). the cache and four scenes can each reach it, so the worst case stays near a third of the memory, and a memory warning drops all of it. the arithmetic is `core/yozora_budget.c`.

the process-wide metal pool counts the allocated size of each iosurface, including row alignment. three quarters of the raster budget go to surfaces, one quarter to the ganesh resource cache. a memory warning drops idle surfaces and releases ganesh scratch resources in the foreground.

the limit only decides how far beyond the screen tiles are made. every tile on screen is made whatever the budget: no page fails for its size or its number of layers, and a layer whose transform leaves no area for a tile grid goes without pixels while the rest of the page is shown.

- a tile with no pixel drawn and a layer at zero opacity without an animation cost nothing against the limit
- a tile entirely under opaque pixels of layers above is not made. this holds for layers drawn at full strength, scaled and moved only: what scrolls with the page hides only what scrolls with it, and opaque layers that fill the screen and stay on it hide the whole page
- a scene over the limit drops the margin tiles, never the frame

## the layer tree

`YZSceneView` applies transforms, opacity, clipping, masks, fixed and sticky positions. each scroll update reads one coherent snapshot of the root and up to 32 inner offsets under one core lock (`yozora_core_read_scroll_state`, 520 bytes on the stack), layers resolve their offsets from that copy.

animations that run in core animation while a script holds the page:

- opacity
- transforms: a translation as two keyframes, a rotation, scale or skew sampled into up to 32 keyframes per segment, webcore blends the transform lists and applies the easing

steps and spring easing, reversed directions, a rate other than 1 and added or accumulated animations stay on the main thread. blending and reflections paint in their ancestor backing. root scrolling requests raster work on its own, so a long script does not hold the interface.

## snapshots

the app does not flatten a scene. a headless snapshot has an equal pixel budget of its own, three snapshots keep the two subsequent calls of the frame api valid.

## webgl

on a phone a canvas with a gl context is shown in a native `CAEAGLLayer` inside the layer of the canvas, its frames go from the texture to the screen on the graphics chip and never reach the raster thread. on the host the frame is read back into a picture and drawn in the layer. see [webgl](webgl.md).

## limits

a page that composites a very large number of layers can reach a limit of the layer tree.
