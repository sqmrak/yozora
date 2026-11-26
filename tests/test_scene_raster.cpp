#include "YozoraRaster.h"
#include <skia/core/SkCanvas.h>
#include <skia/core/SkPaint.h>
#include <skia/core/SkPictureRecorder.h>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <thread>

static yozora_scene* waitScene(Yozora::Raster& raster)
{
    auto end = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (std::chrono::steady_clock::now() < end) {
        if (auto* scene = raster.takeScene())
            return scene;
        std::this_thread::yield();
    }
    assert(false && "raster did not publish a scene");
    return nullptr;
}

static Yozora::RecordedLayer layer(uint64_t id, uint64_t parent, float width, float height, SkColor color)
{
    Yozora::RecordedLayer layer;
    layer.state.id = id;
    layer.state.parent = parent;
    layer.state.width = width;
    layer.state.height = height;
    layer.state.opacity = 1;
    layer.state.transform[0] = layer.state.transform[5] = layer.state.transform[10] = layer.state.transform[15] = 1;
    layer.state.children_transform[0] = layer.state.children_transform[5] = layer.state.children_transform[10] = layer.state.children_transform[15] = 1;
    layer.coverage = SkRect::MakeWH(width, height);
    layer.version = 1;
    SkPictureRecorder recorder;
    SkCanvas* canvas = recorder.beginRecording(layer.coverage);
    SkPaint paint;
    paint.setColor(color);
    canvas->drawRect(layer.coverage, paint);
    layer.picture = recorder.finishRecordingAsPicture();
    return layer;
}

static void testPartialDamage()
{
    auto raster = std::make_unique<Yozora::Raster>(24 * 1024 * 1024);
    auto source = std::make_shared<Yozora::Scene>();
    source->width = 320;
    source->height = 400;
    source->generation = 1;
    source->layers.push_back(layer(1, 0, 320, 400, SK_ColorGREEN));
    raster->submit(source);
    auto* before = waitScene(*raster);
    auto changed = std::make_shared<Yozora::Scene>(*source);
    changed->generation = 2;
    auto& recording = changed->layers[0];
    recording.version = 2;
    SkPictureRecorder recorder;
    auto* canvas = recorder.beginRecording(recording.coverage);
    canvas->drawPicture(recording.picture);
    SkPaint paint;
    paint.setColor(SK_ColorRED);
    canvas->drawRect(SkRect::MakeXYWH(10, 10, 10, 10), paint);
    canvas->drawRect(SkRect::MakeXYWH(300, 140, 10, 10), paint);
    recording.picture = recorder.finishRecordingAsPicture();
    Yozora::RecordedLayer::Change change;
    change.version = 2;
    yozora_damage_add(&change.damage, { 10, 10, 10, 10 });
    yozora_damage_add(&change.damage, { 300, 140, 10, 10 });
    recording.changes.push_back(change);
    raster->submit(changed);
    auto* after = waitScene(*raster);
    assert(!*yozora_scene_error(after));
    Yozora::Raster fresh(24 * 1024 * 1024);
    fresh.submit(changed);
    auto* reference = waitScene(fresh);
    const auto& actual = yozora_scene_layers(after)[0];
    const auto& expected = yozora_scene_layers(reference)[0];
    const auto& previous = yozora_scene_layers(before)[0];
    assert(actual.tile_count == expected.tile_count && actual.tile_count == previous.tile_count);
    unsigned reused = 0;
    for (unsigned i = 0; i < actual.tile_count; ++i) {
        assert(actual.tiles[i].row_bytes == expected.tiles[i].row_bytes);
        assert(!std::memcmp(actual.tiles[i].pixels, expected.tiles[i].pixels,
            actual.tiles[i].row_bytes * actual.tiles[i].height));
        reused += actual.tiles[i].image == previous.tiles[i].image;
    }
    yozora_core_stats stats { };
    raster->statistics(stats);
    assert(stats.tiles_partial == 2 && reused == actual.tile_count - 2);
    // a provider owns one image independently of the scene and the page
    auto* image = actual.tiles[0].image;
    auto* pixels = actual.tiles[0].pixels;
    yozora_image_retain(image);
    yozora_scene_release(before);
    yozora_scene_release(after);
    yozora_scene_release(reference);
    raster.reset();
    assert(pixels[1] == 255);
    yozora_image_release(image);
}

static void testTransparentTileDamage()
{
    Yozora::Raster raster(8 * 1024 * 1024);
    auto source = std::make_shared<Yozora::Scene>();
    source->width = source->height = 64;
    auto recording = layer(1, 0, 64, 64, SK_ColorTRANSPARENT);
    SkPictureRecorder first;
    auto* canvas = first.beginRecording(recording.coverage);
    SkPaint paint;
    paint.setColor(SK_ColorRED);
    canvas->drawRect(SkRect::MakeXYWH(0, 0, 16, 16), paint);
    recording.picture = first.finishRecordingAsPicture();
    source->layers.push_back(recording);
    raster.submit(source);
    auto* before = waitScene(raster);
    auto& old_tile = yozora_scene_layers(before)[0].tiles[0];
    assert(old_tile.pixels[3] == 255);
    assert(old_tile.pixels[32 * old_tile.row_bytes + 32 * 4 + 3] == 0);
    auto changed = std::make_shared<Yozora::Scene>(*source);
    auto& next = changed->layers[0];
    ++next.version;
    SkPictureRecorder second;
    canvas = second.beginRecording(next.coverage);
    paint.setColor(SK_ColorBLUE);
    canvas->drawRect(SkRect::MakeXYWH(16, 0, 16, 16), paint);
    next.picture = second.finishRecordingAsPicture();
    Yozora::RecordedLayer::Change damage;
    damage.version = next.version;
    yozora_damage_add(&damage.damage, { 0, 0, 32, 16 });
    next.changes.push_back(damage);
    raster.submit(changed);
    auto* after = waitScene(raster);
    auto& tile = yozora_scene_layers(after)[0].tiles[0];
    assert(tile.pixels[3] == 0);
    assert(tile.pixels[16 * 4] == 255 && tile.pixels[16 * 4 + 3] == 255);
    assert(tile.pixels[32 * tile.row_bytes + 32 * 4 + 3] == 0);
    // the previous scene still owns its red pixels while the new scene erases them
    assert(old_tile.pixels[3] == 255 && old_tile.pixels[2] == 255);
    yozora_core_stats stats { };
    raster.statistics(stats);
    assert(stats.tiles_partial == 1);
    yozora_scene_release(before);
    yozora_scene_release(after);
}

static void assertSamePixels(const yozora_scene* actual, const yozora_scene* expected)
{
    assert(!*yozora_scene_error(actual) && !*yozora_scene_error(expected));
    assert(yozora_scene_layer_count(actual) == yozora_scene_layer_count(expected));
    for (unsigned i = 0; i < yozora_scene_layer_count(actual); ++i) {
        const auto& a = yozora_scene_layers(actual)[i];
        const auto& b = yozora_scene_layers(expected)[i];
        assert(a.id == b.id && a.tile_count == b.tile_count);
        for (unsigned j = 0; j < a.tile_count; ++j) {
            const auto& x = a.tiles[j];
            const auto& y = b.tiles[j];
            assert(x.x == y.x && x.y == y.y && x.width == y.width && x.height == y.height);
            assert(x.scale == y.scale && x.row_bytes == y.row_bytes);
            assert(!std::memcmp(x.pixels, y.pixels, x.row_bytes * x.height));
        }
    }
}

static void testTileVersionLookup()
{
    Yozora::Raster raster(24 * 1024 * 1024);
    for (float scale : { 1.f, 2.f }) {
        auto source = std::make_shared<Yozora::Scene>();
        source->width = 320;
        source->height = 256;
        source->scale = scale;
        for (unsigned i = 1; i <= 12; ++i)
            source->layers.push_back(layer(i, 0, 300, 256, 0xff000000 | i * 12347));
        raster.submit(source);
        yozora_scene_release(waitScene(raster));
        // skipped scenes still need every intervening damage rectangle, expired history needs a full repaint
        for (uint64_t version : { 2, 4, 9, 10 }) {
            auto changed = std::make_shared<Yozora::Scene>(*source);
            for (auto& recording : changed->layers) {
                SkPictureRecorder recorder;
                auto* canvas = recorder.beginRecording(recording.coverage);
                canvas->drawPicture(recording.picture);
                uint64_t first = version == 9 ? 8 : recording.version + 1;
                for (uint64_t v = first; v <= version; ++v) {
                    Yozora::RecordedLayer::Change change;
                    change.version = v;
                    SkPaint paint;
                    paint.setColor(0xff000000 | (recording.state.id * 13007 + v * 33071));
                    if (v == 8 || v == 10) {
                        canvas->drawRect(recording.coverage, paint);
                        change.damage.full = 1;
                    } else {
                        yozora_rect rect { v % 2 ? 270 : 10, v % 3 ? 140 : 10, 8, 8 };
                        canvas->drawRect(SkRect::MakeXYWH(rect.x, rect.y, rect.width, rect.height), paint);
                        yozora_damage_add(&change.damage, rect);
                    }
                    recording.changes.push_back(change);
                }
                if (version == 9)
                    recording.changes.erase(recording.changes.begin(), recording.changes.end() - 2);
                recording.version = version;
                recording.picture = recorder.finishRecordingAsPicture();
            }
            raster.submit(changed);
            auto* actual = waitScene(raster);
            Yozora::Raster fresh(24 * 1024 * 1024);
            fresh.submit(changed);
            auto* expected = waitScene(fresh);
            assertSamePixels(actual, expected);
            yozora_scene_release(actual);
            yozora_scene_release(expected);
            source = std::move(changed);
        }
    }
}

static void benchmarkTileVersionLookup()
{
    constexpr unsigned frames = 200;
    for (unsigned count : { 32, 128, 400 }) {
        Yozora::Raster raster(24 * 1024 * 1024);
        auto source = std::make_shared<Yozora::Scene>();
        source->width = source->height = 64;
        for (unsigned i = 1; i <= count; ++i)
            source->layers.push_back(layer(i, 0, 64, 256, SK_ColorGREEN));
        raster.submit(source);
        auto* before = waitScene(raster);
        auto began = std::chrono::steady_clock::now();
        for (unsigned frame = 0; frame < frames; ++frame) {
            auto changed = std::make_shared<Yozora::Scene>(*source);
            for (auto& recording : changed->layers) {
                ++recording.version;
                Yozora::RecordedLayer::Change change;
                change.version = recording.version;
                // damage below the raster viewport changes the recording version without changing visible pixels
                yozora_damage_add(&change.damage, { 0, 200, 1, 1 });
                recording.changes = { change };
            }
            raster.submit(changed);
            auto* after = waitScene(raster);
            assert(!*yozora_scene_error(after) && yozora_scene_layer_count(after) == count);
            for (unsigned i = 0; i < count; ++i)
                assert(yozora_scene_layers(after)[i].tiles[0].image == yozora_scene_layers(before)[i].tiles[0].image);
            yozora_scene_release(after);
            source = std::move(changed);
        }
        double milliseconds = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - began).count();
        yozora_core_stats stats { };
        raster.statistics(stats);
        assert(stats.tiles_full == count && !stats.tiles_partial);
        yozora_scene_release(before);
        std::printf("tile lookup: layers=%u frames=%u elapsed_ms=%.3f\n", count, frames, milliseconds);
    }
}

// pages keep closed panels and fades at zero opacity, and a scene that fails over their pixels shows nothing
static void testFadedLayers()
{
    Yozora::Raster raster(2 * 1024 * 1024);
    auto source = std::make_shared<Yozora::Scene>();
    source->width = 320;
    source->height = 400;
    source->layers.push_back(layer(1, 0, 320, 400, SK_ColorGREEN));
    for (unsigned i = 2; i <= 12; ++i) {
        auto faded = layer(i, i == 12 ? 11 : 0, 320, 400, SK_ColorRED);
        faded.state.opacity = i == 12 ? 1 : 0;
        source->layers.push_back(faded);
    }
    // an animation may raise the opacity, so its layer keeps pixels
    auto rising = layer(13, 0, 320, 400, SK_ColorBLUE);
    rising.state.opacity = 0;
    Yozora::RecordedLayer::Animation animation;
    animation.state.id = 1;
    animation.state.property = 1;
    animation.state.duration = 1;
    animation.state.iterations = 1;
    animation.frames.resize(2);
    animation.frames[0].bezier[2] = animation.frames[0].bezier[3] = 1;
    animation.frames[1].values[0] = 1;
    animation.frames[1].time = 1;
    rising.animations.push_back(animation);
    source->layers.push_back(rising);
    raster.submit(source);
    auto* scene = waitScene(raster);
    assert(!*yozora_scene_error(scene) && yozora_scene_layer_count(scene) == 13);
    assert(yozora_scene_layers(scene)[0].tile_count);
    for (unsigned i = 1; i < 12; ++i)
        assert(!yozora_scene_layers(scene)[i].tile_count);
    assert(yozora_scene_layers(scene)[12].tile_count);
    yozora_scene_release(scene);
}

// the margin around the viewport goes before the frame does, and the frame never does
static void testMarginGivenUp()
{
    Yozora::Raster raster(1520 * 1024);
    auto source = std::make_shared<Yozora::Scene>();
    source->width = 320;
    source->height = 400;
    // translucent, so that neither layer hides the other
    source->layers.push_back(layer(1, 0, 320, 4000, SkColorSetARGB(0x80, 0, 255, 0)));
    source->layers.push_back(layer(2, 0, 320, 4000, SkColorSetARGB(0x80, 0, 0, 255)));
    raster.submit(source);
    auto* scene = waitScene(raster);
    assert(!*yozora_scene_error(scene));
    // four rows of two tiles cover the 400 point viewport, the fifth row is margin
    assert(yozora_scene_layers(scene)[0].tile_count == 8 && yozora_scene_layers(scene)[1].tile_count == 8);
    yozora_scene_release(scene);
    // a budget below what the screen needs does not fail the frame, every tile on screen is made and only the margin is left out
    Yozora::Raster small(512 * 1024);
    small.submit(source);
    scene = waitScene(small);
    assert(!*yozora_scene_error(scene));
    assert(yozora_scene_layers(scene)[0].tile_count == 8 && yozora_scene_layers(scene)[1].tile_count == 8);
    yozora_scene_release(scene);
}

// containers the size of the screen with nothing drawn in them hold no pixels, and the cache remembers that they are empty
static void testEmptyTiles()
{
    Yozora::Raster raster(2 * 1024 * 1024);
    auto source = std::make_shared<Yozora::Scene>();
    source->width = 320;
    source->height = 400;
    for (unsigned i = 1; i <= 10; ++i) {
        auto recorded = layer(i, 0, 320, 400, SK_ColorRED);
        SkPictureRecorder recorder;
        auto* canvas = recorder.beginRecording(recorded.coverage);
        SkPaint paint;
        paint.setColor(SK_ColorRED);
        canvas->drawRect(SkRect::MakeXYWH(4, 4, 10, 10), paint);
        recorded.picture = recorder.finishRecordingAsPicture();
        source->layers.push_back(recorded);
    }
    raster.submit(source);
    auto* scene = waitScene(raster);
    assert(!*yozora_scene_error(scene));
    for (unsigned i = 0; i < 10; ++i)
        assert(yozora_scene_layers(scene)[i].tile_count == 1);
    yozora_scene_release(scene);
    yozora_core_stats first { };
    raster.statistics(first);
    auto again = std::make_shared<Yozora::Scene>(*source);
    again->generation = 2;
    raster.submit(again);
    scene = waitScene(raster);
    assert(!*yozora_scene_error(scene));
    yozora_scene_release(scene);
    yozora_core_stats second { };
    raster.statistics(second);
    assert(second.tiles_full == first.tiles_full);
}

static unsigned tilesOf(Yozora::Raster& raster, std::shared_ptr<Yozora::Scene> source, std::initializer_list<unsigned> expected)
{
    raster.submit(source);
    auto* scene = waitScene(raster);
    assert(!*yozora_scene_error(scene));
    unsigned index = 0, total = 0;
    for (unsigned count : expected) {
        assert(yozora_scene_layers(scene)[index].tile_count == count);
        total += count;
        ++index;
    }
    yozora_scene_release(scene);
    return total;
}

static std::shared_ptr<Yozora::Scene> stack(unsigned count, SkColor color = SK_ColorRED)
{
    auto source = std::make_shared<Yozora::Scene>();
    source->width = 320;
    source->height = 400;
    for (unsigned i = 1; i <= count; ++i)
        source->layers.push_back(layer(i, 0, 320, 400, color));
    return source;
}

// pixels under opaque pixels of a layer above are never made, and nothing that could show through counts as opaque
static void testOcclusion()
{
    {
        Yozora::Raster raster(24 * 1024 * 1024);
        // each full opaque layer hides the ones under it, the top one is drawn
        tilesOf(raster, stack(3), { 0, 0, 8 });
    }
    {
        Yozora::Raster raster(24 * 1024 * 1024);
        tilesOf(raster, stack(2, SkColorSetARGB(0x80, 255, 0, 0)), { 8, 8 });
    }
    {
        Yozora::Raster raster(24 * 1024 * 1024);
        auto source = stack(2);
        source->layers[1].state.opacity = 0.5f;
        tilesOf(raster, source, { 8, 8 });
    }
    {
        // a mask, a rising opacity and a translucent parent all keep what is below
        Yozora::Raster raster(24 * 1024 * 1024);
        auto source = stack(3);
        source->layers[2].state.parent = 2;
        source->layers[1].state.opacity = 0.5f;
        tilesOf(raster, source, { 8, 8, 8 });
    }
    {
        // an opaque background hides the layers below although it has no tiles
        Yozora::Raster raster(24 * 1024 * 1024);
        auto source = stack(2);
        Yozora::RecordedLayer cover;
        cover.state = source->layers[1].state;
        cover.state.id = 3;
        cover.state.background = 0xff112233;
        source->layers.push_back(cover);
        tilesOf(raster, source, { 0, 0, 0 });
    }
    {
        // a part of the layer is not enough
        Yozora::Raster raster(24 * 1024 * 1024);
        auto source = stack(1);
        source->layers.push_back(layer(2, 0, 100, 100, SK_ColorBLUE));
        tilesOf(raster, source, { 8, 1 });
    }
    {
        // a cover that stays on the screen hides the page whatever its scroll position, one that does not cover the screen hides nothing
        Yozora::Raster raster(24 * 1024 * 1024);
        auto source = stack(1);
        auto fixed = layer(2, 0, 320, 400, SK_ColorBLUE);
        fixed.state.fixed = 1;
        source->layers.push_back(fixed);
        tilesOf(raster, source, { 0, 8 });
        source = stack(1);
        auto header = layer(2, 0, 320, 50, SK_ColorBLUE);
        header.state.fixed = 1;
        source->layers.push_back(header);
        tilesOf(raster, source, { 8, 2 });
    }
    {
        // pixels that move with the page hide only what moves with it
        Yozora::Raster raster(24 * 1024 * 1024);
        auto source = std::make_shared<Yozora::Scene>();
        source->width = 320;
        source->height = 400;
        auto fixed = layer(1, 0, 320, 400, SK_ColorRED);
        fixed.state.fixed = 1;
        source->layers.push_back(fixed);
        source->layers.push_back(layer(2, 0, 320, 400, SK_ColorBLUE));
        tilesOf(raster, source, { 8, 8 });
    }
}

static void testScrollRevision()
{
    Yozora::Raster raster(24 * 1024 * 1024);
    auto source = std::make_shared<Yozora::Scene>();
    source->width = 320;
    source->height = 400;
    source->generation = 1;
    source->layers.push_back(layer(1, 0, 320, 2400, SK_ColorGREEN));
    source->layers[0].state.scroll_id = 1;
    raster.scroll(600, 2);
    raster.scroll(300, 1);
    raster.submit(source);
    auto* result = waitScene(raster);
    assert(yozora_scene_scroll_y(result) == 600);
    yozora_scene_release(result);
    auto updated = std::make_shared<Yozora::Scene>(*source);
    updated->generation = 2;
    updated->scroll_revision = 2;
    updated->scroll_y = 500;
    raster.submit(updated);
    result = waitScene(raster);
    assert(yozora_scene_scroll_y(result) == 500);
    assert(yozora_scene_generation(result) == 2);
    yozora_scene_release(result);
}

static void tileRows(yozora_scene* scene, float& first, float& last)
{
    auto& backing = yozora_scene_layers(scene)[0];
    assert(backing.tile_count);
    first = last = backing.tiles[0].y;
    for (unsigned i = 1; i < backing.tile_count; ++i) {
        first = std::min(first, backing.tiles[i].y);
        last = std::max(last, backing.tiles[i].y);
    }
}

// the viewport is shown before its margin, and the margin is wider on the side the page moves to
static void testDirectionalMargin()
{
    Yozora::Raster raster(8 * 1024 * 1024);
    auto source = std::make_shared<Yozora::Scene>();
    source->width = 320;
    source->height = 400;
    source->generation = 1;
    source->layers.push_back(layer(1, 0, 320, 6000, SK_ColorGREEN));
    source->layers[0].state.scroll_id = 1;
    raster.scroll(1200);
    raster.submit(source);
    auto* scene = waitScene(raster);
    float first, last;
    tileRows(scene, first, last);
    // rows 1152 to 1536 are the ones that touch 1200 to 1600
    assert(first >= 1152 && last <= 1536);
    yozora_scene_release(scene);
    // a margin of 100 above and 300 below when the page moved down: rows 1024 to 1792
    while (raster.pending())
        std::this_thread::yield();
    scene = raster.takeScene();
    assert(scene);
    tileRows(scene, first, last);
    assert(first == 1024 && last == 1792);
    yozora_scene_release(scene);
    // moving up turns the wide side around: 300 above and 100 below 600 to 1000, rows 256 to 1024
    raster.scroll(600);
    while (raster.pending())
        std::this_thread::yield();
    scene = raster.takeScene();
    assert(scene);
    tileRows(scene, first, last);
    assert(first == 256 && last == 1024);
    yozora_scene_release(scene);
}

static void testMaskAndGroupOpacity()
{
    Yozora::Raster raster(24 * 1024 * 1024);
    auto source = std::make_shared<Yozora::Scene>();
    source->width = 100;
    source->height = 100;
    source->layers.push_back(layer(1, 0, 100, 100, SK_ColorRED));
    source->layers[0].state.mask = 2;
    source->layers[0].state.opacity = 0.5;
    source->layers[0].state.children_transform[12] = 40;
    source->layers.push_back(layer(2, 1, 50, 100, SK_ColorWHITE));
    source->layers.push_back(layer(3, 1, 100, 100, SK_ColorBLUE));
    yozora_frame frame { };
    raster.takeFrame(frame);
    raster.submit(source);
    auto* scene = waitScene(raster);
    assert(!*yozora_scene_error(scene));
    assert(raster.takeFrame(frame) && frame.count);
    auto pixel = [&](unsigned x) { return frame.tiles[0].pixels + 10 * frame.tiles[0].row_bytes + x * 4; };
    assert(pixel(10)[2] == 255 && pixel(10)[0] >= 126 && pixel(10)[0] <= 128);
    assert(pixel(45)[0] == 255 && pixel(45)[2] >= 126 && pixel(45)[2] <= 128);
    assert(pixel(60)[0] == 255 && pixel(60)[1] == 255 && pixel(60)[2] == 255);
    yozora_scene_release(scene);
}

static void testAnimationWithoutWebCore()
{
    Yozora::Raster raster(24 * 1024 * 1024);
    auto source = std::make_shared<Yozora::Scene>();
    source->width = 100;
    source->height = 100;
    source->layers.push_back(layer(1, 0, 100, 100, SK_ColorRED));
    Yozora::RecordedLayer::Animation animation;
    animation.state.id = 1;
    animation.state.property = 1;
    animation.state.duration = 0.2;
    animation.state.iterations = 1;
    animation.state.fill = 1;
    animation.frames.resize(2);
    animation.frames[0].values[0] = 1;
    animation.frames[0].bezier[2] = animation.frames[0].bezier[3] = 1;
    animation.frames[1].time = 1;
    source->layers[0].animations.push_back(animation);
    yozora_frame frame { };
    raster.takeFrame(frame);
    raster.submit(source);
    unsigned frames = 0;
    auto end = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    bool finished = false;
    while (std::chrono::steady_clock::now() < end) {
        auto* scene = waitScene(raster);
        assert(!*yozora_scene_error(scene));
        assert(raster.takeFrame(frame) && frame.count);
        ++frames;
        finished = frame.tiles[0].pixels[0] == 255;
        yozora_scene_release(scene);
        if (finished)
            break;
    }
    assert(finished && frames >= 2);
    yozora_core_stats stats { };
    raster.statistics(stats);
    assert(stats.tiles_full == 1 && !stats.tiles_partial);
}

static void testSmallLayers()
{
    Yozora::Raster raster(64 * 1024);
    auto source = std::make_shared<Yozora::Scene>();
    source->width = 100;
    source->height = 100;
    // side by side: layers that overlap would hide each other
    for (unsigned i = 1; i <= 50; ++i) {
        auto small = layer(i, 0, 20, 10, SK_ColorGREEN);
        small.state.x = static_cast<float>((i - 1) % 5 * 20);
        small.state.y = static_cast<float>((i - 1) / 5 * 10);
        source->layers.push_back(small);
    }
    raster.submit(source);
    auto* scene = waitScene(raster);
    assert(!*yozora_scene_error(scene));
    assert(yozora_scene_layer_count(scene) == 50);
    for (unsigned i = 0; i < 50; ++i) {
        auto& view = yozora_scene_layers(scene)[i];
        assert(view.tile_count == 1 && view.tiles[0].width == 20 && view.tiles[0].height == 10);
    }
    yozora_scene_release(scene);
}

static void testFrameLifetime()
{
    Yozora::Raster raster(24 * 1024 * 1024);
    auto source = std::make_shared<Yozora::Scene>();
    source->width = 100;
    source->height = 100;
    source->generation = 1;
    source->layers.push_back(layer(1, 0, 100, 100, SK_ColorRED));
    yozora_frame frame { };
    raster.takeFrame(frame);
    raster.submit(source);
    auto* scene = waitScene(raster);
    assert(raster.takeFrame(frame));
    yozora_frame first = frame;
    yozora_scene_release(scene);
    for (unsigned i = 0; i < 2; ++i) {
        raster.reset();
        auto changed = std::make_shared<Yozora::Scene>(*source);
        changed->generation = i + 2;
        changed->layers[0] = layer(1, 0, 100, 100, i ? SK_ColorGREEN : SK_ColorBLUE);
        raster.submit(changed);
        scene = waitScene(raster);
        assert(raster.takeFrame(frame));
        yozora_scene_release(scene);
    }
    // the public snapshot contract keeps pixels through two subsequent calls
    assert(first.count && first.tiles[0].pixels[2] == 255 && first.tiles[0].pixels[0] == 0);
}

struct FakeCanvas {
    yozora_canvas canvas;
    std::atomic<int> references { 1 };
};

static FakeCanvas* makeCanvas(unsigned width, unsigned height)
{
    auto* fake = new FakeCanvas;
    fake->canvas = { fake, width, height,
        [](yozora_canvas* canvas) { ++reinterpret_cast<FakeCanvas*>(canvas)->references; },
        [](yozora_canvas* canvas) { --reinterpret_cast<FakeCanvas*>(canvas)->references; } };
    return fake;
}

// a native canvas layer has no picture and no tile, and its surface stays alive for as long as a scene that
// shows it, whatever happens to the recording it came from
static void testCanvasSurface()
{
    auto raster = std::make_unique<Yozora::Raster>(24 * 1024 * 1024);
    auto* fake = makeCanvas(640, 480);
    yozora_scene* scene = nullptr;
    int recorded = 0;
    {
        auto source = std::make_shared<Yozora::Scene>();
        source->width = 320;
        source->height = 400;
        source->generation = 1;
        source->layers.push_back(layer(1, 0, 320, 400, SK_ColorWHITE));
        Yozora::RecordedLayer canvas;
        canvas.state.id = 2;
        canvas.state.parent = 1;
        canvas.state.width = 320;
        canvas.state.height = 240;
        canvas.state.opacity = 1;
        canvas.state.transform[0] = canvas.state.transform[5] = canvas.state.transform[10] = canvas.state.transform[15] = 1;
        canvas.state.children_transform[0] = canvas.state.children_transform[5] = canvas.state.children_transform[10] = canvas.state.children_transform[15] = 1;
        fake->canvas.retain(&fake->canvas);
        canvas.canvas = std::shared_ptr<yozora_canvas>(&fake->canvas, [](yozora_canvas* held) { held->release(held); });
        canvas.state.canvas = &fake->canvas;
        canvas.state.canvas_x = 10;
        canvas.state.canvas_y = 20;
        canvas.state.canvas_width = 320;
        canvas.state.canvas_height = 240;
        source->layers.push_back(canvas);
        // the surface and the recording hold it, the raster pass keeps the recording
        recorded = fake->references;
        assert(recorded == 2);
        raster->submit(source);
        scene = waitScene(*raster);
    }
    // the recording is gone, the scene holds the surface
    assert(!*yozora_scene_error(scene));
    assert(yozora_scene_layer_count(scene) == 2);
    auto* published = &yozora_scene_layers(scene)[1];
    assert(published->canvas == &fake->canvas);
    assert(published->canvas_x == 10 && published->canvas_y == 20 && published->canvas_width == 320 && published->canvas_height == 240);
    assert(published->tile_count == 0);
    assert(!yozora_scene_layers(scene)[0].canvas);
    // the raster may hold a further scene of its own, so only the least is certain while this one is held
    assert(fake->references >= recorded + 1);
    yozora_scene_release(scene);
    // the raster and the recording go, and nothing of the surface is left but the owner's reference
    raster.reset();
    assert(fake->references == 1);
    delete fake;
}

static void testMutationProgress()
{
    Yozora::Raster raster(24 * 1024 * 1024);
    auto source = std::make_shared<Yozora::Scene>();
    source->width = 512;
    source->height = 512;
    source->scale = 2;
    source->layers.push_back(layer(1, 0, 512, 512, SK_ColorGREEN));
    SkPictureRecorder recorder;
    auto* canvas = recorder.beginRecording(source->layers[0].coverage);
    SkPaint paint;
    for (unsigned i = 0; i < 20000; ++i) {
        paint.setColor(0xff000000 | (i * 12347 & 0xffffff));
        canvas->drawRect(SkRect::MakeXYWH(i * 13 % 512, i * 29 % 512, 15, 15), paint);
    }
    source->layers[0].picture = recorder.finishRecordingAsPicture();
    auto end = std::chrono::steady_clock::now() + std::chrono::seconds(1);
    unsigned delivered = 0;
    uint64_t generation = 0;
    while (std::chrono::steady_clock::now() < end) {
        auto changed = std::make_shared<Yozora::Scene>(*source);
        changed->generation = ++generation;
        changed->layers[0].version = generation;
        raster.submit(changed);
        if (auto* scene = raster.takeScene()) {
            assert(!*yozora_scene_error(scene));
            ++delivered;
            yozora_scene_release(scene);
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    assert(delivered && "continuous invalidation must not cancel every in-flight frame");
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    for (;;) {
        auto* scene = waitScene(raster);
        bool latest = yozora_scene_generation(scene) == generation;
        yozora_scene_release(scene);
        if (latest)
            break;
        assert(std::chrono::steady_clock::now() < deadline);
    }
}

static void testLargeViewport()
{
    Yozora::Raster raster(24 * 1024 * 1024);
    auto source = std::make_shared<Yozora::Scene>();
    source->width = 1024;
    source->height = 768;
    source->scale = 2;
    source->layers.push_back(layer(1, 0, 1024, 6000, SK_ColorGREEN));
    source->layers[0].state.scroll_id = 1;
    yozora_frame frame { };
    raster.takeFrame(frame);
    raster.scroll(1200);
    raster.submit(source);
    auto* scene = waitScene(raster);
    assert(!*yozora_scene_error(scene));
    assert(raster.takeFrame(frame) && frame.count);
    assert(frame.tiles[0].scale == 2);
    assert(frame.tiles[0].document_y <= 1200);
    auto& last = frame.tiles[frame.count - 1];
    assert(last.document_y + last.height / last.scale >= 1200 + 768);
    size_t bytes = 0;
    auto& backing = yozora_scene_layers(scene)[0];
    for (unsigned i = 0; i < backing.tile_count; ++i) {
        assert(backing.tiles[i].scale == 2);
        bytes += backing.tiles[i].row_bytes * backing.tiles[i].height;
    }
    assert(bytes <= 24 * 1024 * 1024);
    yozora_scene_release(scene);
}

// pages like a video feed keep thousands of small compositing layers, only pixels are budgeted
static void testManyLayers()
{
    Yozora::Raster raster(24 * 1024 * 1024);
    auto source = std::make_shared<Yozora::Scene>();
    source->width = 320;
    source->height = 400;
    source->generation = 1;
    source->layers.push_back(layer(1, 0, 320, 400, SK_ColorWHITE));
    for (uint64_t i = 0; i < 2000; ++i) {
        source->layers.push_back(layer(i + 2, 1, 16, 16, SK_ColorBLUE));
        source->layers.back().state.x = static_cast<float>(i % 20 * 16);
        source->layers.back().state.y = static_cast<float>(i / 20 % 25 * 16);
    }
    raster.submit(source);
    auto* scene = waitScene(raster);
    assert(!*yozora_scene_error(scene));
    assert(yozora_scene_layer_count(scene) == 2001);
    yozora_scene_release(scene);
}

// tiles painted by one thread and by three come out the same, in the same order with the same pixels, the
// occlusion of the opaque top layer holds, and a helper pool can be dropped while a pass runs
static void testPaintingThreads()
{
    auto source = std::make_shared<Yozora::Scene>();
    source->width = 640;
    source->height = 800;
    source->scale = 2;
    source->generation = 1;
    source->layers.push_back(layer(1, 0, 640, 3000, SkColorSetARGB(0xff, 0x20, 0x80, 0x40)));
    source->layers.push_back(layer(2, 0, 600, 2500, SkColorSetARGB(0x80, 0, 0, 255)));
    source->layers.push_back(layer(3, 0, 500, 2000, SkColorSetARGB(0x60, 255, 0, 0)));
    // a layer with a picture that is not one flat color, so a tile put in the wrong place shows
    {
        auto striped = layer(4, 0, 640, 1800, SK_ColorWHITE);
        SkPictureRecorder recorder;
        auto* canvas = recorder.beginRecording(striped.coverage);
        SkPaint paint;
        for (int row = 0; row < 1800 / 20; ++row) {
            paint.setColor(SkColorSetARGB(0xff, row * 7 % 256, row * 13 % 256, row * 29 % 256));
            canvas->drawRect(SkRect::MakeXYWH(row * 3 % 200, row * 20, 400, 14), paint);
        }
        striped.picture = recorder.finishRecordingAsPicture();
        source->layers.push_back(std::move(striped));
    }
    // opaque and at the top: the tiles of the layers under it that lie in its area are never made
    source->layers.push_back(layer(5, 0, 640, 500, SK_ColorWHITE));
    for (auto& entry : source->layers)
        entry.state.scroll_id = 1;
    // the scene after the viewport pass and the margin pass are both done, not whichever of the two was taken first
    auto settled = [](Yozora::Raster& raster) {
        auto* scene = waitScene(raster);
        auto end = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        while (raster.pending() && std::chrono::steady_clock::now() < end)
            std::this_thread::yield();
        if (auto* newer = raster.takeScene()) {
            yozora_scene_release(scene);
            scene = newer;
        }
        return scene;
    };
    auto compare = [&](Yozora::Raster& a, Yozora::Raster& b) {
        a.submit(source);
        b.submit(source);
        auto* first = settled(a);
        auto* second = settled(b);
        assert(!*yozora_scene_error(first) && !*yozora_scene_error(second));
        assert(yozora_scene_layer_count(first) == yozora_scene_layer_count(second));
        unsigned tiles = 0;
        for (unsigned i = 0; i < yozora_scene_layer_count(first); ++i) {
            const auto& x = yozora_scene_layers(first)[i];
            const auto& y = yozora_scene_layers(second)[i];
            assert(x.tile_count == y.tile_count);
            for (unsigned j = 0; j < x.tile_count; ++j) {
                assert(x.tiles[j].x == y.tiles[j].x && x.tiles[j].y == y.tiles[j].y);
                assert(x.tiles[j].width == y.tiles[j].width && x.tiles[j].height == y.tiles[j].height);
                assert(!std::memcmp(x.tiles[j].pixels, y.tiles[j].pixels, x.tiles[j].row_bytes * x.tiles[j].height));
                ++tiles;
            }
        }
        // the occluded layers have fewer tiles than a layer of their height would
        assert(tiles > 20);
        assert(yozora_scene_layers(first)[0].tile_count < 3000 / 128 * 3);
        yozora_scene_release(first);
        yozora_scene_release(second);
    };
    {
        Yozora::Raster single(24 * 1024 * 1024, 1);
        Yozora::Raster pooled(24 * 1024 * 1024, 3);
        compare(single, pooled);
    }
    {
        // the pool of the process, whatever it is made of here
        Yozora::Raster single(24 * 1024 * 1024, 1);
        Yozora::Raster shared(24 * 1024 * 1024);
        compare(single, shared);
    }
    // a raster dropped at once, with its tiles still in the pool, and another one right after it
    for (int round = 0; round < 20; ++round) {
        auto raster = std::make_unique<Yozora::Raster>(24 * 1024 * 1024, 4);
        raster->submit(source);
        if (round % 2)
            std::this_thread::sleep_for(std::chrono::milliseconds(round));
        raster.reset();
    }
    // two rasters of one pool at the same time, scrolled over and over
    {
        Yozora::Raster one(24 * 1024 * 1024), two(24 * 1024 * 1024);
        one.submit(source);
        two.submit(source);
        for (int step = 0; step < 60; ++step) {
            one.scroll(step * 37 % 2000);
            two.scroll(2000 - step * 29 % 2000);
            std::this_thread::sleep_for(std::chrono::milliseconds(3));
        }
        auto* a = waitScene(one);
        auto* b = waitScene(two);
        assert(!*yozora_scene_error(a) && !*yozora_scene_error(b));
        yozora_scene_release(a);
        yozora_scene_release(b);
    }
}

// a first memory warning gives back the tiles the last pass did not use and keeps the ones it did, so the
// page on screen is not painted again
static void testTrimUnused()
{
    Yozora::Raster raster(24 * 1024 * 1024, 1);
    auto source = std::make_shared<Yozora::Scene>();
    source->width = 320;
    source->height = 400;
    source->generation = 1;
    source->layers.push_back(layer(1, 0, 320, 6000, SK_ColorGREEN));
    source->layers[0].state.scroll_id = 1;
    auto idle = [&]() {
        auto end = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        while (raster.pending() && std::chrono::steady_clock::now() < end)
            std::this_thread::yield();
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    };
    auto painted = [&]() {
        yozora_core_stats stats { };
        raster.statistics(stats);
        return stats.tiles_full;
    };
    raster.submit(source);
    idle();
    // the page is read far down, and the passes there touch other tiles than the ones at the top
    raster.scroll(3000);
    idle();
    long long before = painted();
    assert(before > 0);
    raster.trimUnused();
    idle();
    // the screen at 3000 is still held: a new generation of the same scene paints nothing again there
    auto again = std::make_shared<Yozora::Scene>(*source);
    again->generation = 2;
    raster.submit(again);
    idle();
    assert(painted() == before);
    // the tiles at the top were not used by the last pass and went: going back paints them again
    raster.scroll(0);
    idle();
    assert(painted() > before);
    // everything goes with reset
    long long settledCount = painted();
    raster.reset();
    idle();
    auto third = std::make_shared<Yozora::Scene>(*source);
    third->generation = 3;
    raster.submit(third);
    idle();
    assert(painted() > settledCount);
}

// a page that jumps to a place nothing was made for shows coarse tiles (three quarters of the scale) at once and crisp
// ones replace them when the page has been still
static void testCoarseWhileMoving()
{
    Yozora::Raster raster(24 * 1024 * 1024, 1);
    auto source = std::make_shared<Yozora::Scene>();
    source->width = 320;
    source->height = 400;
    source->scale = 2;
    source->generation = 1;
    source->layers.push_back(layer(1, 0, 320, 8000, SK_ColorGREEN));
    source->layers[0].state.scroll_id = 1;
    raster.submit(source);
    yozora_scene* first = waitScene(raster);
    yozora_scene_release(first);
    std::this_thread::sleep_for(std::chrono::milliseconds(400));
    while (auto* old = raster.takeScene())
        yozora_scene_release(old);
    // the jump: nothing at 5000 exists yet
    raster.scroll(5000);
    yozora_scene* jumped = waitScene(raster);
    const auto& tiles = yozora_scene_layers(jumped)[0];
    bool coarse = false;
    for (unsigned i = 0; i < tiles.tile_count; ++i)
        coarse = coarse || tiles.tiles[i].scale == 1.5f;
    assert(tiles.tile_count > 0 && coarse);
    // a coarse tile is as big on the screen as a crisp one: width over scale is the size in points
    for (unsigned i = 0; i < tiles.tile_count; ++i)
        assert(tiles.tiles[i].width / tiles.tiles[i].scale <= 256.5f && tiles.tiles[i].height / tiles.tiles[i].scale <= 128.5f);
    yozora_scene_release(jumped);
    // still: the crisp tiles replace them
    auto end = std::chrono::steady_clock::now() + std::chrono::seconds(8);
    bool crisp = false;
    while (!crisp && std::chrono::steady_clock::now() < end) {
        if (auto* scene = raster.takeScene()) {
            const auto& layerTiles = yozora_scene_layers(scene)[0];
            bool any = layerTiles.tile_count > 0;
            for (unsigned i = 0; i < layerTiles.tile_count; ++i)
                any = any && layerTiles.tiles[i].scale == 2.0f;
            crisp = any;
            yozora_scene_release(scene);
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    assert(crisp);
    // a scale of 1 has nothing cheaper to make: no coarse tile at all
    Yozora::Raster plain(24 * 1024 * 1024, 1);
    auto flat = std::make_shared<Yozora::Scene>(*source);
    flat->scale = 1;
    plain.submit(flat);
    yozora_scene_release(waitScene(plain));
    plain.scroll(5000);
    yozora_scene* plainJump = waitScene(plain);
    const auto& plainTiles = yozora_scene_layers(plainJump)[0];
    for (unsigned i = 0; i < plainTiles.tile_count; ++i)
        assert(plainTiles.tiles[i].scale == 1.0f);
    yozora_scene_release(plainJump);
}

int main(int argc, char** argv)
{
    assert(yozora_scene_tile_size() == sizeof(yozora_scene_tile));
    if (argc == 2 && !std::strcmp(argv[1], "--benchmark")) {
        benchmarkTileVersionLookup();
        return 0;
    }
    assert(argc == 1);
    testPartialDamage();
    testTransparentTileDamage();
    testTileVersionLookup();
    testFadedLayers();
    testMarginGivenUp();
    testEmptyTiles();
    testOcclusion();
    testScrollRevision();
    testMaskAndGroupOpacity();
    testAnimationWithoutWebCore();
    testSmallLayers();
    testFrameLifetime();
    testCanvasSurface();
    testMutationProgress();
    testLargeViewport();
    testDirectionalMargin();
    testManyLayers();
    testPaintingThreads();
    testTrimUnused();
    testCoarseWhileMoving();
    yozora_scene* held = nullptr;
    const uint8_t* held_pixels = nullptr;
    {
        Yozora::Raster raster(24 * 1024 * 1024);
        auto scene = std::make_shared<Yozora::Scene>();
        scene->width = 320;
        scene->height = 400;
        scene->scale = 2;
        scene->generation = 1;
        scene->layers.push_back(layer(1, 0, 320, 2400, SK_ColorGREEN));
        scene->layers[0].state.scroll_id = 1;
        scene->layers.push_back(layer(2, 1, 320, 30, SK_ColorRED));
        scene->layers[1].state.fixed = 1;
        raster.submit(scene);
        held = waitScene(raster);
        assert(!*yozora_scene_error(held));
        assert(yozora_scene_layer_count(held) == 2);
        auto* layers = yozora_scene_layers(held);
        assert(layers[0].tile_count > 0 && layers[1].tile_count > 0);
        held_pixels = layers[0].tiles[0].pixels;
        assert(held_pixels[0] == 0 && held_pixels[1] == 255 && held_pixels[2] == 0 && held_pixels[3] == 255);
        // a new scroll must publish without another scene or any WebCore work
        raster.scroll(600);
        auto* moved = waitScene(raster);
        assert(yozora_scene_scroll_y(moved) == 600);
        auto* moved_layers = yozora_scene_layers(moved);
        assert(moved_layers[0].y == -600);
        assert(moved_layers[1].y == 600);
        yozora_scene_release(moved);
        yozora_frame frame { };
        raster.takeFrame(frame);
        auto* flattened = waitScene(raster);
        yozora_scene_release(flattened);
        assert(raster.takeFrame(frame) && frame.count);
        bool red = false;
        for (unsigned i = 0; i < frame.count; ++i) {
            auto& tile = frame.tiles[i];
            int row = (610 - tile.document_y) * 2;
            if (row >= 0 && row < static_cast<int>(tile.height)) {
                const uint8_t* pixels = tile.pixels + row * tile.row_bytes + 20 * 4;
                red = pixels[2] == 255 && pixels[1] == 0;
            }
        }
        assert(red && "fixed header must remain at the viewport top in a flattened scene");
        raster.reset();
        auto changed = std::make_shared<Yozora::Scene>(*scene);
        changed->generation = 2;
        changed->width = 200;
        changed->scale = 1;
        raster.submit(changed);
        auto* resized = waitScene(raster);
        assert(yozora_scene_layers(resized)[0].tiles[0].scale == 1);
        yozora_scene_release(resized);
    }
    // pixels handed to a provider outlive a resize, reset and destruction of the page
    assert(held_pixels[1] == 255);
    yozora_scene_release(held);
    {
        Yozora::Raster raster(1024);
        auto scene = std::make_shared<Yozora::Scene>();
        scene->width = 320;
        scene->height = 400;
        scene->layers.push_back(layer(1, 0, 320, 1000, SK_ColorBLUE));
        raster.submit(scene);
        // a budget of one kilobyte still shows the page, the pixels on screen are never refused
        auto* shown = waitScene(raster);
        assert(!*yozora_scene_error(shown));
        assert(yozora_scene_layers(shown)[0].tile_count > 0);
        yozora_scene_release(shown);
    }
    {
        Yozora::Raster raster(1024 * 1024);
        auto scene = std::make_shared<Yozora::Scene>();
        scene->width = scene->height = 100;
        scene->layers.push_back(layer(1, 0, 100, 100, SK_ColorBLUE));
        scene->layers[0].state.transform[0] = INFINITY;
        raster.submit(scene);
        auto* failed = waitScene(raster);
        assert(*yozora_scene_error(failed));
        yozora_scene_release(failed);
    }
    {
        // a layer mapped to an area no tile grid holds goes without pixels, the layer beside it is still drawn
        Yozora::Raster raster(1024 * 1024);
        auto scene = std::make_shared<Yozora::Scene>();
        scene->width = scene->height = 100;
        scene->layers.push_back(layer(1, 0, 100, 100, SK_ColorBLUE));
        scene->layers.push_back(layer(2, 0, 100, 100, SK_ColorGREEN));
        scene->layers[0].state.transform[0] = 1000000;
        raster.submit(scene);
        auto* shown = waitScene(raster);
        assert(!*yozora_scene_error(shown));
        assert(yozora_scene_layers(shown)[0].tile_count == 0 && yozora_scene_layers(shown)[1].tile_count > 0);
        yozora_scene_release(shown);
    }
    std::puts("scene raster: damage equality, tile version history, cache reuse, empty tiles, faded layers, occlusion, budget that never fails the frame, painting threads, directional margin, scroll revisions, masks, animations, image lifetime and memory bounds passed");
}
