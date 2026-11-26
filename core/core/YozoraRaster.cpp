#include "config.h"
#include "YozoraRaster.h"
#include "yozora_budget.h"
#if defined(__APPLE__) && defined(__arm64__)
#include "YozoraMetal.h"
#endif

#include <skia/core/SkCanvas.h>
#include <skia/core/SkImage.h>
#include <skia/core/SkPicture.h>
#include <skia/core/SkM44.h>
#include <skia/core/SkPixmap.h>
#include <skia/core/SkRegion.h>
#include <skia/core/SkSurface.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cerrno>
#include <ctime>
#include <sys/time.h>
#include <cmath>
#include <deque>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <set>
#include <iterator>
#include <pthread.h>
#include <string>
#include <tuple>
#include <mutex>
#include "../yozora_log.h"

struct yozora_scene {
    std::atomic<unsigned> references { 1 };
    std::vector<yozora_scene_layer> layers;
    std::vector<std::vector<yozora_scene_tile>> tile_views;
    std::vector<sk_sp<SkImage>> images;
    std::vector<std::vector<yozora_scene_animation>> animation_views;
    std::vector<std::vector<std::vector<yozora_scene_keyframe>>> animation_frames;
    std::vector<sk_sp<SkSurface>> frame;
    // the native canvas layers of this scene, one reference each
    std::vector<yozora_canvas*> canvases;
    int first_row { 0 };
    int scroll_y { 0 };
    uint64_t generation { 0 };
    int page_zoom { 100 };
    float scale { 1 };
    std::string error;
    long long rasterized { 0 }, partial { 0 };
    // tiles of this scene made at one pixel per point because the page was moving, the pass is made again,
    // crisp, once it stops
    unsigned coarse { 0 };
    ~yozora_scene()
    {
        for (auto* canvas : canvases)
            canvas->release(canvas);
    }
};

extern "C" size_t yozora_scene_tile_size(void) { return sizeof(yozora_scene_tile); }

extern "C" void yozora_scene_retain(yozora_scene* scene)
{
    if (scene)
        scene->references.fetch_add(1, std::memory_order_relaxed);
}

extern "C" void yozora_scene_release(yozora_scene* scene)
{
    if (scene && scene->references.fetch_sub(1, std::memory_order_acq_rel) == 1)
        delete scene;
}

extern "C" unsigned yozora_scene_layer_count(const yozora_scene* scene) { return scene ? scene->layers.size() : 0; }
extern "C" const yozora_scene_layer* yozora_scene_layers(const yozora_scene* scene) { return scene ? scene->layers.data() : nullptr; }
extern "C" int yozora_scene_scroll_y(const yozora_scene* scene) { return scene ? scene->scroll_y : 0; }
extern "C" uint64_t yozora_scene_generation(const yozora_scene* scene) { return scene ? scene->generation : 0; }
extern "C" int yozora_scene_page_zoom(const yozora_scene* scene) { return scene ? scene->page_zoom : 100; }
extern "C" const char* yozora_scene_error(const yozora_scene* scene) { return scene ? scene->error.c_str() : ""; }

extern "C" void yozora_image_retain(yozora_image* image)
{
    if (image)
        reinterpret_cast<SkImage*>(image)->ref();
}

extern "C" void yozora_image_release(yozora_image* image)
{
    if (image)
        reinterpret_cast<SkImage*>(image)->unref();
}

// the scale of the tiles made while the page moves: three quarters of the screen scale, which costs a little more
// than half of a crisp tile on a scale 2 screen and is not blurry like one pixel per point. never below 1
static float coarse_scale_for(float scale)
{
    return std::max(1.0f, std::floor(scale * 3.0f + 0.5f) / 4.0f);
}

namespace Yozora {
namespace {
constexpr int tileWidth = 256;
constexpr int tileHeight = 128;
// what a tile costs the budget at least: a page with hundreds of small layers makes hundreds of tiles of a
// few hundred bytes, each an image and a native layer, so the count is paid in the same budget as the pixels
// and not capped on its own
constexpr size_t minimumTileCharge = 512;

using Clock = std::chrono::steady_clock;
// keep a tile's versions together so damage lookup skips unrelated layers and coordinates
using Key = std::tuple<uint64_t, int, int, unsigned, uint64_t>;
// a tile with no pixel has no image: pages keep screen sized containers with nothing drawn and each would
// hold half a megabyte at scale 2 for a transparent frame. the entry only remembers the tile is empty so it
// is not drawn again
constexpr size_t emptyTileCost = 256;
struct CachedTile {
    sk_sp<SkImage> image;
    uint64_t used { 0 };
    SkRect coverage;
    size_t bytes { emptyTileCost };
    // every pixel has full alpha, so what lies under the tile cannot show
    bool opaque { false };
    void* surface { nullptr };
};

bool tileView(yozora_scene_tile& view, const CachedTile& tile, int x, int y, float scale)
{
    SkPixmap pixels;
    if (!tile.image || (!tile.surface && !tile.image->peekPixels(&pixels)))
        return false;
    view = { static_cast<const uint8_t*>(pixels.addr()), pixels.rowBytes(),
        static_cast<unsigned>(tile.image->width()), static_cast<unsigned>(tile.image->height()),
        static_cast<float>(x * tileWidth), static_cast<float>(y * tileHeight), scale,
        reinterpret_cast<yozora_image*>(tile.image.get()), tile.surface };
    return true;
}

struct TileScan {
    bool empty { true };
    bool opaque { true };
};

TileScan scan(const SkPixmap& pixels)
{
    TileScan result;
    for (int y = 0; y < pixels.height() && (result.empty || result.opaque); ++y) {
        auto* row = static_cast<const uint32_t*>(pixels.addr(0, y));
        for (int x = 0; x < pixels.width(); ++x) {
            if (row[x])
                result.empty = false;
            if ((row[x] >> 24) != 0xff)
                result.opaque = false;
            if (!result.empty && !result.opaque)
                return result;
        }
    }
    return result;
}

SkM44 matrix(const double* values)
{
    float converted[16];
    for (unsigned i = 0; i < 16; ++i)
        converted[i] = static_cast<float>(values[i]);
    return SkM44::ColMajor(converted);
}

// one line in the app log for a layer whose bounds start away from zero: what the raster did with it and why. the
// same layer repeats its line only when the verdict or its numbers (rounded to 16 points) change, and a run writes
// at most 300 of them. it says which of the layers of a page the compositor drops and where
void traceBounds(const yozora_scene_layer& layer, const char* verdict, const SkRect& clip, const SkRect& area, const SkRect& coverage)
{
    static std::mutex lock;
    static std::map<uint64_t, std::string> last;
    static unsigned lines = 0;
    auto step = [](float value) { return static_cast<int>(std::lround(value / 16)) * 16; };
    char text[400];
    std::snprintf(text, sizeof text, "id=%llu %s origin %d,%d size %dx%d clip=%d,%d %dx%d area=%d,%d %dx%d covers=%d,%d %dx%d",
        static_cast<unsigned long long>(layer.id), verdict, step(layer.bounds_x), step(layer.bounds_y), step(layer.width), step(layer.height),
        step(clip.x()), step(clip.y()), step(clip.width()), step(clip.height()), step(area.x()), step(area.y()), step(area.width()), step(area.height()),
        step(coverage.x()), step(coverage.y()), step(coverage.width()), step(coverage.height()));
    std::lock_guard<std::mutex> guard(lock);
    auto& previous = last[layer.id];
    if (previous == text || lines >= 300)
        return;
    previous = text;
    ++lines;
    yozora_log(YOZORA_LOG_INFO, "raster", "%s", text);
}

SkM44 layerMatrix(const yozora_scene_layer& layer)
{
    float x = layer.anchor_x * layer.width;
    float y = layer.anchor_y * layer.height;
    SkM44 result = SkM44::Translate(layer.x + x, layer.y + y, layer.anchor_z);
    result.preConcat(matrix(layer.transform));
    result.preTranslate(-x - layer.bounds_x, -y - layer.bounds_y, -layer.anchor_z);
    return result;
}

bool validLayer(const yozora_scene_layer& layer)
{
    const float geometry[] { layer.x, layer.y, layer.width, layer.height, layer.anchor_x, layer.anchor_y,
        layer.anchor_z, layer.bounds_x, layer.bounds_y, layer.opacity, layer.scroll_x, layer.scroll_y };
    auto finite = [](auto value) { return std::isfinite(value); };
    return layer.width >= 0 && layer.height >= 0
        && std::all_of(std::begin(geometry), std::end(geometry), finite)
        && std::all_of(layer.transform, layer.transform + 16, finite)
        && std::all_of(layer.children_transform, layer.children_transform + 16, finite)
        && std::all_of(layer.sticky.viewport, layer.sticky.viewport + 4, finite)
        && std::all_of(layer.sticky.container, layer.sticky.container + 4, finite)
        && std::all_of(layer.sticky.box, layer.sticky.box + 4, finite)
        && std::all_of(layer.sticky.offsets, layer.sticky.offsets + 4, finite);
}


// a tile to paint: everything it needs is copied in, so a job never touches pass state and a dropped pass
// leaves nothing dangling. the result is written by whichever thread runs it
struct TileJob {
    sk_sp<SkPicture> picture;
    // the tile of an earlier version of the layer and what changed since, so only the damage is painted again
    sk_sp<SkImage> previous;
    void* previous_surface { nullptr };
    yozora_damage changes { };
    float scale { 1 };
    int x { 0 }, y { 0 };
    unsigned width { 0 }, height { 0 };
    sk_sp<SkImage> image;
    bool empty { true };
    bool opaque { false };
    void* surface { nullptr };
    size_t budget { 0 };
    bool failed { false };
    // read and written under the lock of the pool
    bool done { false };
};

// a stand for hosts that paint a tile much faster than a phone: YOZORA_RASTER_TILE_DELAY_US makes each tile
// cost what it costs on a phone so the gaps of a fling can be measured on the host. zero outside the tests
static long tileDelayMicroseconds()
{
    static long value = [] {
        const char* text = std::getenv("YOZORA_RASTER_TILE_DELAY_US");
        long parsed = text ? std::atol(text) : 0;
        return parsed < 0 ? 0 : (parsed > 200000 ? 200000 : parsed);
    }();
    return value;
}

void drawTile(SkCanvas& canvas, SkImage* previous, void* argument)
{
    auto& job = *static_cast<TileJob*>(argument);
    canvas.clear(SK_ColorTRANSPARENT);
    if (previous) {
        canvas.drawImage(previous, 0, 0);
        SkRegion changed;
        for (unsigned j = 0; j < job.changes.count; ++j) {
            auto rect = job.changes.rects[j];
            int left = std::floor(std::clamp((static_cast<double>(rect.x) - job.x * tileWidth) * job.scale, 0.0, static_cast<double>(job.width)));
            int top = std::floor(std::clamp((static_cast<double>(rect.y) - job.y * tileHeight) * job.scale, 0.0, static_cast<double>(job.height)));
            int right = std::ceil(std::clamp((static_cast<double>(rect.x) + rect.width - job.x * tileWidth) * job.scale, 0.0, static_cast<double>(job.width)));
            int bottom = std::ceil(std::clamp((static_cast<double>(rect.y) + rect.height - job.y * tileHeight) * job.scale, 0.0, static_cast<double>(job.height)));
            changed.op(SkIRect::MakeLTRB(left, top, right, bottom), SkRegion::kUnion_Op);
        }
        canvas.clipRegion(changed);
        canvas.clear(SK_ColorTRANSPARENT);
    }
    canvas.scale(job.scale, job.scale);
    canvas.translate(-job.x * tileWidth, -job.y * tileHeight);
    canvas.drawPicture(job.picture);
}

void paintTile(TileJob& job)
{
    if (long delay = tileDelayMicroseconds())
        usleep(static_cast<useconds_t>(delay));
#if defined(__APPLE__) && defined(__arm64__)
    job.image = yozora_metal_tile(job.width, job.height, job.budget, job.previous.get(), job.previous_surface, drawTile, &job, &job.surface, &job.empty, &job.opaque);
    if (job.image) {
        if (job.empty) {
            job.image.reset();
            job.surface = nullptr;
        }
        return;
    }
#endif
    auto surface = SkSurfaces::Raster(SkImageInfo::Make(job.width, job.height, kBGRA_8888_SkColorType, kPremul_SkAlphaType));
    if (!surface) {
        job.failed = true;
        return;
    }
    auto previous = job.previous;
    if (job.previous_surface)
        previous = previous->makeRasterImage(nullptr);
    drawTile(*surface->getCanvas(), previous.get(), &job);
    job.image = surface->makeImageSnapshot();
    if (!job.image) {
        job.failed = true;
        return;
    }
    SkPixmap drawn;
    TileScan scanned;
    if (job.image && job.image->peekPixels(&drawn))
        scanned = scan(drawn);
    else
        scanned = { false, false };
    job.empty = scanned.empty;
    job.opaque = scanned.opaque;
    if (job.empty)
        job.image = nullptr;
}

// helper threads that paint tiles for the passes of every raster of the process. the pass thread paints too
// while it waits, so a pool of one helper means two threads painting. a pool without a helper (one core, or
// one thread asked for) paints on the pass thread
class TilePool {
public:
    explicit TilePool(unsigned helpers)
    {
        pthread_mutex_init(&m_lock, nullptr);
        pthread_cond_init(&m_work, nullptr);
        pthread_cond_init(&m_finished, nullptr);
        for (unsigned i = 0; i < helpers; ++i) {
            pthread_t thread;
            int error = pthread_create(&thread, nullptr, &TilePool::run, this);
            if (error) {
                std::fprintf(stderr, "yozora: a raster helper thread did not start: %d\n", error);
                break;
            }
            m_threads.push_back(thread);
        }
    }

    ~TilePool()
    {
        pthread_mutex_lock(&m_lock);
        m_stopping = true;
        pthread_cond_broadcast(&m_work);
        pthread_mutex_unlock(&m_lock);
        for (auto thread : m_threads)
            pthread_join(thread, nullptr);
        pthread_cond_destroy(&m_finished);
        pthread_cond_destroy(&m_work);
        pthread_mutex_destroy(&m_lock);
    }

    unsigned helpers() const { return static_cast<unsigned>(m_threads.size()); }

    void submit(const std::shared_ptr<TileJob>& job)
    {
        pthread_mutex_lock(&m_lock);
        m_queue.push_back(job);
        pthread_cond_signal(&m_work);
        pthread_mutex_unlock(&m_lock);
    }

    // returns when every job is done. while one is not, the calling thread takes the next job of the queue and paints it
    void finish(const std::vector<std::shared_ptr<TileJob>>& jobs)
    {
        for (auto& job : jobs) {
            pthread_mutex_lock(&m_lock);
            while (!job->done) {
                if (!m_queue.empty()) {
                    auto next = m_queue.front();
                    m_queue.pop_front();
                    pthread_mutex_unlock(&m_lock);
                    execute(next);
                    pthread_mutex_lock(&m_lock);
                    continue;
                }
                // the helper holds this one, it signals when it is done
                pthread_cond_wait(&m_finished, &m_lock);
            }
            pthread_mutex_unlock(&m_lock);
        }
    }

private:
    void execute(const std::shared_ptr<TileJob>& job)
    {
        paintTile(*job);
        pthread_mutex_lock(&m_lock);
        job->done = true;
        pthread_cond_broadcast(&m_finished);
        pthread_mutex_unlock(&m_lock);
    }

    static void* run(void* argument)
    {
        auto& pool = *static_cast<TilePool*>(argument);
        for (;;) {
            pthread_mutex_lock(&pool.m_lock);
            while (pool.m_queue.empty() && !pool.m_stopping)
                pthread_cond_wait(&pool.m_work, &pool.m_lock);
            if (pool.m_stopping) {
                pthread_mutex_unlock(&pool.m_lock);
                return nullptr;
            }
            auto job = pool.m_queue.front();
            pool.m_queue.pop_front();
            pthread_mutex_unlock(&pool.m_lock);
            pool.execute(job);
        }
    }

    pthread_mutex_t m_lock;
    pthread_cond_t m_work;
    pthread_cond_t m_finished;
    std::deque<std::shared_ptr<TileJob>> m_queue;
    std::vector<pthread_t> m_threads;
    bool m_stopping { false };
};

// the threads that paint tiles in all: YOZORA_RASTER_THREADS (1 to 4), otherwise by the cores (yozora_raster_threads_for: one, two, three or four).
// YOZORA_DEVICE_CORES stands in for the core count as it does for the rest of the core
unsigned defaultRasterThreads()
{
    if (const char* text = std::getenv("YOZORA_RASTER_THREADS")) {
        int value = std::atoi(text);
        if (value >= 1 && value <= 4)
            return static_cast<unsigned>(value);
    }
    long cores = sysconf(_SC_NPROCESSORS_ONLN);
    if (const char* text = std::getenv("YOZORA_DEVICE_CORES")) {
        int value = std::atoi(text);
        if (value >= 1 && value <= 64)
            cores = value;
    }
    return yozora_raster_threads_for(cores > 0 ? static_cast<unsigned>(cores) : 1);
}

// one pool for the process so many tabs do not multiply helpers. never destroyed, its threads sleep until the
// process ends
TilePool& sharedTilePool()
{
    static TilePool* pool = new TilePool(defaultRasterThreads() - 1);
    return *pool;
}

}

struct Raster::State {
    State(size_t limit, std::shared_ptr<TilePool> tilePool) : pool(std::move(tilePool)), byte_limit(limit) { }
    // null paints on this thread
    std::shared_ptr<TilePool> pool;
    pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    pthread_cond_t wake = PTHREAD_COND_INITIALIZER;
    pthread_t thread;
    bool stopping { false };
    bool requested { false };
    bool working { false };
    bool clear_cache { false };
    // the page moved a moment ago: missing tiles on screen are made coarse, cheaper by the square of the
    // scale, and a pass that makes them is followed by a crisp one once the page has been still a moment
    Clock::time_point last_scroll_move { };
    bool refine_pending { false };
    Clock::time_point refine_at { };
    // drop the tiles that the last pass did not use, keep the rest
    bool trim_unused { false };
    // the value of sequence when the last pass began: a tile used by that pass has a larger one
    uint64_t pass_started { 0 };
    bool flatten { false };
    int scroll_y { 0 };
    uint64_t scroll_revision { 0 };
    // counts moves of the scroll target, a pass that only fills the margin gives way when it changes
    std::atomic<uint64_t> scroll_tick { 0 };
    // the side the page moved to last: the margin is wider there and its rows are made first
    int last_target { 0 };
    int direction { 1 };
    // the document rows the last finished pass held tiles for, a scroll that stays inside needs no pass for the viewport alone
    uint64_t settled_generation { 0 };
    int settled_top { 0 }, settled_bottom { 0 };
    size_t byte_limit;
    std::atomic<uint64_t> revision { 0 };
    std::shared_ptr<const Scene> scene;
    std::shared_ptr<yozora_scene> output;
    std::shared_ptr<yozora_scene> ui_frame, ui_frame_before, ui_frame_older;
    uint64_t scene_taken { 0 }, frame_taken { 0 }, published { 0 };
    long long paint_ms { 0 }, paints { 0 }, tiles { 0 };
    long long partial { 0 };
    std::map<Key, CachedTile> cache;
    size_t cache_bytes { 0 };
    uint64_t sequence { 0 };
    Clock::time_point last_animation_frame { };

    float rasterReach(const Scene& source) const
    {
        float desired = source.height * (byte_limit <= 16 * 1024 * 1024 ? 0.5f : 1.0f);
        double bytes_per_row = source.width * static_cast<double>(source.scale) * source.scale * 4;
        // reserve a quarter for other backings, viewport pixels take priority over the optional margin
        double rows = byte_limit * 0.75 / bytes_per_row - source.height - tileHeight * 2;
        return std::min(desired, static_cast<float>(std::max(0.0, rows / 2)));
    }

    void trim(size_t incoming)
    {
        while (!cache.empty() && cache_bytes + incoming > byte_limit) {
            auto oldest = std::min_element(cache.begin(), cache.end(), [](auto& a, auto& b) { return a.second.used < b.second.used; });
            cache_bytes -= oldest->second.bytes;
            cache.erase(oldest);
        }
    }

    struct Margin {
        float top { 0 }, bottom { 0 };
    };

    // the same pixels as a symmetric margin, spent mostly on the side the page moves to. the scene records
    // one screen beyond the viewport so the margin never grows past that
    Margin margin(const Scene& source) const
    {
        float reach = rasterReach(source);
        float ahead = std::min(reach * 1.5f, static_cast<float>(source.height));
        float behind = std::max(0.0f, reach * 2 - ahead);
        return direction < 0 ? Margin { ahead, behind } : Margin { behind, ahead };
    }

    // false when the last finished pass of this scene already holds the tiles of the new viewport
    bool needsViewportPass(const Scene& source, int target) const
    {
        return settled_generation != source.generation || target < settled_top
            || target + static_cast<int>(source.height) > settled_bottom;
    }

    // a page over the pixel budget gives up tiles beyond the screen, never the frame. a viewport pass makes
    // only the tiles on screen and shows cached margin tiles, so a fast scroll sees pixels before the margin
    // is made
    std::shared_ptr<yozora_scene> render(const Scene& source, int target, bool flat, uint64_t ticket, bool viewport_only, uint64_t tick, bool coarse)
    {
        return renderPass(source, target, flat, ticket, margin(source), viewport_only, tick, coarse);
    }

    // a matrix that only scales and moves keeps a rectangle a rectangle, so a covered rectangle is the pixels it says
    static bool layer_exact(const SkMatrix& matrix)
    {
        return matrix.isScaleTranslate() && matrix.getScaleX() > 0 && matrix.getScaleY() > 0;
    }

    std::shared_ptr<yozora_scene> renderPass(const Scene& source, int target, bool flat, uint64_t ticket, Margin reach, bool viewport_only, uint64_t tick, bool coarse)
    {
        auto result = std::shared_ptr<yozora_scene>(new yozora_scene, yozora_scene_release);
        result->scroll_y = target;
        result->generation = source.generation;
        result->page_zoom = source.page_zoom;
        result->scale = source.scale;
        if (!source.error.empty()) {
            result->error = source.error;
            return result;
        }
        if (!source.width || !source.height || source.width > 2048 || source.height > 2048
            || !std::isfinite(source.scale) || source.scale < 1 || source.scale > 4) {
            result->error = "Invalid page raster dimensions";
            return result;
        }
        result->layers.reserve(source.layers.size());
        result->tile_views.resize(source.layers.size());
        result->animation_views.resize(source.layers.size());
        result->animation_frames.resize(source.layers.size());
        std::map<uint64_t, SkM44> transforms;
        std::map<uint64_t, SkM44> child_transforms;
        std::map<uint64_t, uint64_t> masks;
        std::map<uint64_t, SkRect> clips;
        // the layers are first placed, then drawn from the top down so that a tile under an opaque one is never made
        struct Plan {
            size_t index;
            SkM44 transform;
            SkRect clip;
            int left, top, right, bottom;
            // 1 for a layer that stays at its place on the screen, 0 for what scrolls with the page
            int domain;
            // paints its pixels at full strength: no ancestor or own opacity, mask or animation
            bool solid;
        };
        std::vector<Plan> plans;
        std::map<uint64_t, bool> solid;
        std::map<uint64_t, int> domains;
        std::set<uint64_t> mask_layers;
        for (auto& masked : source.layers) {
            if (masked.state.mask)
                mask_layers.insert(masked.state.mask);
        }
        std::set<uint64_t> faded;
        auto viewport = SkRect::MakeXYWH(0, -reach.top, source.width, source.height + reach.top + reach.bottom);
        auto screen = SkRect::MakeWH(source.width, source.height);
        // while the page moves coarse tiles reach half a screen past it on the side it moves to. crisp margin
        // tiles are not made during a fling (a pass that finds the page moved again leaves after two tiles),
        // so rows about to come into view were made only on screen and the place stayed empty meanwhile
        auto coarse_zone = screen;
        if (coarse) {
            if (direction > 0)
                coarse_zone.fBottom += source.height * 0.5f;
            else
                coarse_zone.fTop -= source.height * 0.5f;
        }
        size_t pixel_bytes = 0;
        for (size_t i = 0; i < source.layers.size(); ++i) {
            if (revision.load() != ticket)
                return nullptr;
            const auto& recorded = source.layers[i];
            auto layer = recorded.state;
            if (!validLayer(layer)) {
                result->error = "Invalid compositing layer geometry";
                return result;
            }
            bool translated = false;
            for (auto& recorded_animation : recorded.animations) {
                auto animation = recorded_animation.state;
                if (!animation.paused)
                    animation.elapsed += std::chrono::duration<double>(Clock::now() - recorded_animation.captured).count();
                result->animation_frames[i].push_back(recorded_animation.frames);
                animation.count = recorded_animation.frames.size();
                animation.frames = result->animation_frames[i].back().data();
                result->animation_views[i].push_back(animation);
                translated = translated || animation.property == 2;
                double values[16];
                if (flat && yozora_scene_animation_values(&animation, animation.elapsed, values)) {
                    if (animation.property == 1)
                        layer.opacity = values[0];
                    else
                        std::copy(values, values + 16, layer.transform);
                }
            }
            layer.animations = result->animation_views[i].data();
            layer.animation_count = result->animation_views[i].size();
            if (layer.scroll_id == 1) {
                layer.y -= target - source.scroll_y;
                layer.scroll_y = target;
            }
            if (layer.fixed)
                layer.y += target - source.scroll_y;
            if (layer.sticky.scroll_id == 1) {
                float x, y;
                float dy = target - source.scroll_y;
                yozora_sticky_delta(&layer.sticky, 0, dy, &x, &y);
                layer.x += x;
                layer.y += y;
                layer.sticky.viewport[1] += dy;
                layer.sticky.scroll_y = target;
            }
            result->layers.push_back(layer);
            if (layer.canvas) {
                layer.canvas->retain(layer.canvas);
                result->canvases.push_back(layer.canvas);
            }
            auto& parent_transforms = masks[layer.parent] == layer.id ? transforms : child_transforms;
            auto parent = parent_transforms.find(layer.parent);
            SkM44 transform = parent == parent_transforms.end() ? SkM44() : parent->second;
            transform.preConcat(layerMatrix(layer));
            transforms[layer.id] = transform;
            auto inherited = clips.find(layer.parent);
            SkRect clip = inherited == clips.end() ? viewport : inherited->second;
            if (layer.clips && !layer.viewport_clip) {
                // the layer frame is its bounds, which start at the bounds origin: that is how far a
                // scrolling block moved its content and the transform already carries it. mapping from zero
                // moved the frame up by the scroll, so a block scrolled by a third got pixels for the top two
                // thirds of its window and the rest stayed white (the verify bar of a captcha)
                auto bounds = transform.asM33().mapRect(SkRect::MakeXYWH(layer.bounds_x, layer.bounds_y, layer.width, layer.height));
                if (!clip.intersect(bounds))
                    clip = SkRect::MakeEmpty();
            }
            clips[layer.id] = clip;
            child_transforms[layer.id] = transform;
            child_transforms[layer.id].preConcat(matrix(layer.children_transform));
            masks[layer.id] = layer.mask;
            auto parent_solid = solid.find(layer.parent);
            bool layer_solid = (parent_solid == solid.end() || parent_solid->second) && layer.opacity >= 1 && !layer.mask && !mask_layers.count(layer.id)
                && recorded.animations.empty() && !layer.preserves_3d && !layer.hidden;
            solid[layer.id] = layer_solid;
            auto parent_domain = domains.find(layer.parent);
            int domain = layer.fixed || layer.sticky.scroll_id ? 1 : (parent_domain == domains.end() ? 0 : parent_domain->second);
            domains[layer.id] = domain;
            SkMatrix inverse;
            // a layer at zero opacity with no animation to raise it paints nothing, nor does everything under
            // it. pages keep many such layers (closed panels, dialogs, fades) and each would hold a full
            // viewport of pixels
            if (layer.opacity <= 0 && recorded.animations.empty())
                faded.insert(layer.id);
            if (faded.count(layer.parent))
                faded.insert(layer.id);
            bool scrolledInside = layer.bounds_x || layer.bounds_y;
            if (layer.hidden || faded.count(layer.id) || clip.isEmpty() || !transform.asM33().invert(&inverse)) {
                if (scrolledInside)
                    traceBounds(layer, layer.hidden ? "dropped, hidden" : faded.count(layer.id) ? "dropped, faded" : clip.isEmpty() ? "dropped, clip empty" : "dropped, not invertible",
                        clip, SkRect::MakeEmpty(), recorded.picture ? recorded.coverage : SkRect::MakeEmpty());
                continue;
            }
            if (!recorded.picture) {
                if (scrolledInside)
                    traceBounds(layer, "no picture", clip, SkRect::MakeEmpty(), SkRect::MakeEmpty());
                plans.push_back({ i, transform, clip, 0, 0, 0, 0, domain, layer_solid });
                continue;
            }
            auto area = inverse.mapRect(clip);
            if (translated)
                area = recorded.coverage;
            auto shown = area;
            if (!area.intersect(recorded.coverage)) {
                if (scrolledInside)
                    traceBounds(layer, "no pixels, the window is outside the picture", clip, shown, recorded.coverage);
                plans.push_back({ i, transform, clip, 0, 0, 0, 0, domain, layer_solid });
                continue;
            }
            if (scrolledInside)
                traceBounds(layer, "drawn", clip, area, recorded.coverage);
            // a transform close to a singularity maps the layer to an area no tile grid can hold, the layer
            // goes without pixels and the rest of the page is still shown
            if (!area.isFinite() || area.width() > 32768 || area.height() > 32768
                || std::fabs(area.left()) > 100000000 || std::fabs(area.top()) > 100000000) {
                plans.push_back({ i, transform, clip, 0, 0, 0, 0, domain, layer_solid });
                continue;
            }
            int left = static_cast<int>(std::floor(area.left() / tileWidth));
            int top = static_cast<int>(std::floor(area.top() / tileHeight));
            int right = static_cast<int>(std::ceil(area.right() / tileWidth));
            int bottom = static_cast<int>(std::ceil(area.bottom() / tileHeight));
            plans.push_back({ i, transform, clip, left, top, right, bottom, domain, layer_solid });
        }
        SkRegion covered[2];
        auto viewport_pixels = SkIRect::MakeWH(static_cast<int>(source.width), static_cast<int>(source.height));
        bool fixed_cover = false;
        // opaque pixels the layers below must not paint again, rounded inwards so that a partly covered pixel never counts
        auto cover = [&](const Plan& plan, SkRect rect) {
            if (!rect.intersect(plan.clip))
                return;
            auto inside = rect.roundIn();
            if (inside.isEmpty())
                return;
            covered[plan.domain].op(inside, SkRegion::kUnion_Op);
            if (plan.domain == 1 && covered[1].contains(viewport_pixels))
                fixed_cover = true;
        };
        // the tiles of a layer are independent, so they go to the painting threads together and the pass
        // waits only where the next layer needs to know what they cover: after a layer that can cover, and at
        // the end. an empty tile gives its budget share back
        struct PendingTile {
            std::shared_ptr<TileJob> job;
            const Plan* plan;
            size_t layer;
            // the place of the tile among the tiles of its layer, kept so the order does not depend on which tile finished first
            size_t slot;
            Key key;
            SkRect coverage;
            SkRect on_screen;
            size_t charge;
            bool covers;
        };
        std::vector<PendingTile> pending;
        auto collect = [&]() -> bool {
            if (pending.empty())
                return true;
            if (pool) {
                std::vector<std::shared_ptr<TileJob>> jobs;
                jobs.reserve(pending.size());
                for (auto& entry : pending)
                    jobs.push_back(entry.job);
                pool->finish(jobs);
            }
            bool ok = true;
            for (auto& entry : pending) {
                auto& job = *entry.job;
                if (job.failed) {
                    result->error = "Cannot allocate page raster tile";
                    ok = false;
                    break;
                }
                size_t cost = job.empty ? emptyTileCost : entry.charge;
                trim(cost);
                auto cached = cache.emplace(entry.key, CachedTile { job.empty ? nullptr : job.image, ++sequence, entry.coverage, cost, job.opaque, job.surface });
                cache_bytes += cost;
                if (job.empty) {
                    pixel_bytes -= entry.charge;
                    continue;
                }
                if (!tileView(result->tile_views[entry.layer][entry.slot], cached.first->second, job.x, job.y, job.scale)) {
                    result->error = "Cannot read page raster tile";
                    ok = false;
                    break;
                }
                result->images.push_back(job.image);
                if (entry.covers && job.opaque)
                    cover(*entry.plan, entry.on_screen);
            }
            pending.clear();
            return ok;
        };
        for (size_t n = plans.size(); n-- > 0;) {
            const auto& plan = plans[n];
            const size_t i = plan.index;
            const auto& recorded = source.layers[i];
            const auto& layer = result->layers[i];
            const auto matrix_on_screen = plan.transform.asM33();
            const bool placed = !matrix_on_screen.hasPerspective();
            const bool exact = layer_exact(matrix_on_screen);
            const int left = plan.left, top = plan.top, right = plan.right, bottom = plan.bottom;
            // rows near the screen first, then the side the page moves to, then the side it came from
            std::vector<int> rows;
            for (int y = top; y < bottom; ++y)
                rows.push_back(y);
            if (placed && rows.size() > 1) {
                auto priority = [&](int row) {
                    auto band = matrix_on_screen.mapRect(SkRect::MakeXYWH(0, row * tileHeight, tileWidth, tileHeight));
                    if (band.fBottom > 0 && band.fTop < source.height)
                        return 0.0f;
                    bool above = band.fBottom <= 0;
                    float distance = above ? -band.fBottom : band.fTop - source.height;
                    return 1.0f + distance * ((above ? -1 : 1) == direction ? 1.0f : 2.0f);
                };
                std::stable_sort(rows.begin(), rows.end(), [&](int a, int b) { return priority(a) < priority(b); });
            }
            for (int y : rows) {
                for (int x = left; x < right; ++x) {
                    if (revision.load() != ticket)
                        return nullptr;
                    float logical_width = std::min<float>(tileWidth, layer.width - x * tileWidth);
                    float logical_height = std::min<float>(tileHeight, layer.height - y * tileHeight);
                    if (!(logical_width > 0 && logical_height > 0))
                        continue;
                    auto tile_on_screen = SkRect::MakeEmpty();
                    if (placed) {
                        tile_on_screen = matrix_on_screen.mapRect(SkRect::MakeXYWH(x * tileWidth, y * tileHeight, logical_width, logical_height));
                        // what the page cannot see through a fixed opaque cover needs no pixels, wherever it
                        // lies. otherwise a tile has to sit entirely under opaque pixels that move with it
                        auto seen = tile_on_screen;
                        if (seen.intersect(plan.clip) && (plan.domain == 0 && fixed_cover ? true : covered[plan.domain].contains(seen.roundOut()))) {
                            continue;
                        }
                    }
                    unsigned width = std::ceil(logical_width * source.scale);
                    unsigned height = std::ceil(logical_height * source.scale);
                    size_t bytes = static_cast<size_t>(width) * height * 4;
                    // the budget only decides which tiles are made beyond the screen, a tile on screen is
                    // always made so no page fails for its size
                    size_t charge = std::max(bytes, minimumTileCharge);
                    bool over = charge > byte_limit - std::min(pixel_bytes, byte_limit);
                    unsigned scale_key = static_cast<unsigned>(source.scale * 1024);
                    Key key { layer.id, x, y, scale_key, recorded.version };
                    auto found = cache.find(key);
                    // the page is moving and this screen tile has no crisp picture yet: a cheaper
                    // tile is made in its place, cheaper by the square of the scale and there in time,
                    // waiting for the crisp one left the place white. a crisp pass follows when the page
                    // stops
                    if (found == cache.end() && coarse && placed && SkRect::Intersects(tile_on_screen, coarse_zone)) {
                        const bool visible = SkRect::Intersects(tile_on_screen, screen);
                        const float low_scale = coarse_scale_for(source.scale);
                        unsigned low_width = std::ceil(logical_width * low_scale), low_height = std::ceil(logical_height * low_scale);
                        size_t low_charge = std::max(static_cast<size_t>(low_width) * low_height * 4, minimumTileCharge);
                        // a tile that is not on screen yet is only made inside the budget, as every tile beyond the screen
                        if (!visible && low_charge > byte_limit - std::min(pixel_bytes, byte_limit))
                            continue;
                        Key low_key { layer.id, x, y, static_cast<unsigned>(low_scale * 1024), recorded.version };
                        auto low = cache.find(low_key);
                        if (low != cache.end()) {
                            low->second.used = ++sequence;
                            if (low->second.image) {
                                yozora_scene_tile view;
                                if (!tileView(view, low->second, x, y, low_scale)) {
                                    result->error = "Cannot read low resolution tile";
                                    return result;
                                }
                                result->tile_views[i].push_back(view);
                                result->images.push_back(low->second.image);
                                pixel_bytes += low_charge;
                                // only tiles on screen ask for the crisp pass that follows, the ones ahead wait until they come into view
                                if (visible)
                                    ++result->coarse;
                                if (plan.solid && exact && low->second.opaque)
                                    cover(plan, tile_on_screen);
                            }
                            continue;
                        }
                        auto low_job = std::make_shared<TileJob>();
                        low_job->picture = recorded.picture;
                        low_job->scale = low_scale;
                        low_job->x = x;
                        low_job->y = y;
                        low_job->budget = byte_limit;
                        low_job->width = low_width;
                        low_job->height = low_height;
                        if (pool && pool->helpers())
                            pool->submit(low_job);
                        else {
                            paintTile(*low_job);
                            low_job->done = true;
                        }
                        result->tile_views[i].push_back({ });
                        pending.push_back({ low_job, &plan, i, result->tile_views[i].size() - 1, low_key, recorded.coverage, tile_on_screen, low_charge, plan.solid && exact });
                        pixel_bytes += low_charge;
                        ++result->rasterized;
                        if (visible)
                            ++result->coarse;
                        continue;
                    }
                    sk_sp<SkImage> previous_image;
                    void* previous_surface = nullptr;
                    yozora_damage changes { };
                    if (found == cache.end() && !recorded.changes.empty()) {
                        uint64_t first_version = recorded.changes.front().version;
                        Key first { layer.id, x, y, scale_key, first_version ? first_version - 1 : 0 };
                        for (auto old = cache.lower_bound(first); old != cache.end(); ++old) {
                            auto [id, tx, ty, scale, version] = old->first;
                            if (id != layer.id || tx != x || ty != y || scale != scale_key || version >= recorded.version)
                                break;
                            yozora_damage damage { };
                            for (auto& change : recorded.changes) {
                                if (change.version <= version)
                                    continue;
                                if (change.damage.full)
                                    damage.full = 1;
                                for (unsigned j = 0; j < change.damage.count; ++j)
                                    yozora_damage_add(&damage, change.damage.rects[j]);
                            }
                            auto required = SkRect::MakeXYWH(x * tileWidth, y * tileHeight, tileWidth, tileHeight);
                            if (!required.intersect(recorded.coverage) || !old->second.coverage.contains(required))
                                continue;
                            bool damaged = yozora_damage_intersects(&damage, { x * tileWidth, y * tileHeight, tileWidth, tileHeight });
                            if (!damaged) {
                                auto tile = cache.extract(old);
                                tile.key() = key;
                                found = cache.insert(std::move(tile)).position;
                                break;
                            }
                            if (!damage.full) {
                                previous_image = old->second.image;
                                previous_surface = old->second.surface;
                                changes = damage;
                            }
                        }
                    }
                    sk_sp<SkImage> image;
                    bool tile_opaque = false;
                    if (found != cache.end()) {
                        found->second.used = ++sequence;
                        image = found->second.image;
                        tile_opaque = found->second.opaque;
                        if (!image)
                            continue;
                    } else {
                        if (viewport_only && placed && !SkRect::Intersects(tile_on_screen, screen))
                            continue;
                        if (over && placed && !SkRect::Intersects(tile_on_screen, screen))
                            continue;
                        auto job = std::make_shared<TileJob>();
                        job->picture = recorded.picture;
                        job->previous = previous_image;
                        job->previous_surface = previous_surface;
                        job->changes = changes;
                        job->scale = source.scale;
                        job->x = x;
                        job->y = y;
                        job->budget = byte_limit;
                        job->width = width;
                        job->height = height;
                        if (pool && pool->helpers())
                            pool->submit(job);
                        else {
                            paintTile(*job);
                            job->done = true;
                        }
                        // the tile takes its place now and is filled in when it is done, a tile that comes out empty leaves the empty place to be removed
                        result->tile_views[i].push_back({ });
                        pending.push_back({ job, &plan, i, result->tile_views[i].size() - 1, key, recorded.coverage, tile_on_screen, charge, plan.solid && exact });
                        pixel_bytes += charge;
                        ++result->rasterized;
                        if (previous_image)
                            ++result->partial;
                        // the tiles made stay cached, the next pass starts from them. two tiles per pass keep a margin that never finishes moving
                        if (!viewport_only && result->rasterized >= 2 && scroll_tick.load() != tick) {
                            collect();
                            return nullptr;
                        }
                        continue;
                    }
                    pixel_bytes += charge;
                    yozora_scene_tile view;
                    if (!tileView(view, found->second, x, y, source.scale)) {
                        result->error = "Cannot read page raster tile";
                        return result;
                    }
                    result->tile_views[i].push_back(view);
                    result->images.push_back(std::move(image));
                    if (plan.solid && exact && tile_opaque)
                        cover(plan, tile_on_screen);
                }
            }
            // the layers below ask what this one covers
            if (plan.solid && exact && !collect())
                return result;
            // a background of full alpha covers the whole layer whatever its tiles hold
            if (plan.solid && exact && (layer.background >> 24) == 0xff)
                cover(plan, matrix_on_screen.mapRect(SkRect::MakeXYWH(layer.bounds_x, layer.bounds_y, layer.width, layer.height)));
        }
        if (!collect())
            return result;
        for (auto& views : result->tile_views)
            std::erase_if(views, [](const yozora_scene_tile& tile) { return !tile.image; });
        for (size_t i = 0; i < result->layers.size(); ++i) {
            result->layers[i].tiles = result->tile_views[i].data();
            result->layers[i].tile_count = result->tile_views[i].size();
        }
        if (flat)
            flattenScene(*result, source);
        return result;
    }

    void drawLayer(SkCanvas& canvas, yozora_scene& scene, size_t index)
    {
        const auto& layer = scene.layers[index];
        if (layer.opacity <= 0 || !scene.error.empty())
            return;
        canvas.save();
        canvas.concat(layerMatrix(layer));
        if (layer.clips && !layer.viewport_clip)
            canvas.clipRect(SkRect::MakeXYWH(layer.bounds_x, layer.bounds_y, layer.width, layer.height));
        bool transparency = layer.opacity < 1 || layer.mask;
        if (transparency)
            canvas.saveLayerAlphaf(nullptr, layer.opacity);
        if (layer.background) {
            SkPaint paint;
            paint.setColor(layer.background);
            canvas.drawRect(SkRect::MakeXYWH(layer.bounds_x, layer.bounds_y, layer.width, layer.height), paint);
        }
        for (unsigned i = 0; !layer.hidden && i < layer.tile_count; ++i) {
            auto& tile = layer.tiles[i];
            auto image = sk_ref_sp(reinterpret_cast<SkImage*>(tile.image));
            if (tile.surface)
                image = image->makeRasterImage(nullptr, SkImage::kAllow_CachingHint);
            if (!image) {
                scene.error = "Cannot read page snapshot tile";
                break;
            }
            canvas.drawImageRect(image, SkRect::MakeXYWH(tile.x, tile.y, tile.width / tile.scale, tile.height / tile.scale), SkSamplingOptions());
        }
        canvas.save();
        canvas.concat(matrix(layer.children_transform));
        for (size_t child = index + 1; child < scene.layers.size(); ++child) {
            if (scene.layers[child].parent == layer.id && scene.layers[child].id != layer.mask)
                drawLayer(canvas, scene, child);
        }
        canvas.restore();
        if (layer.mask) {
            auto found = std::find_if(scene.layers.begin(), scene.layers.end(), [&](auto& child) { return child.id == layer.mask; });
            if (found != scene.layers.end()) {
                SkPaint paint;
                paint.setBlendMode(SkBlendMode::kDstIn);
                canvas.saveLayer(nullptr, &paint);
                drawLayer(canvas, scene, found - scene.layers.begin());
                canvas.restore();
            }
        }
        if (transparency)
            canvas.restore();
        canvas.restore();
    }

    void flattenScene(yozora_scene& output, const Scene& source)
    {
        int reach = std::floor(rasterReach(source));
        int first = std::max(0, output.scroll_y - reach) / tileHeight;
        int last = (output.scroll_y + static_cast<int>(source.height) + reach + tileHeight - 1) / tileHeight;
        last = std::min(first + YOZORA_MAX_TILES, last);
        output.first_row = first * tileHeight;
        for (int row = first; row < last; ++row) {
            auto surface = SkSurfaces::Raster(SkImageInfo::Make(std::lround(source.width * source.scale), std::lround(tileHeight * source.scale), kBGRA_8888_SkColorType, kPremul_SkAlphaType));
            if (!surface) {
                output.error = "Cannot allocate page snapshot";
                return;
            }
            auto& canvas = *surface->getCanvas();
            canvas.clear(SK_ColorWHITE);
            canvas.scale(source.scale, source.scale);
            canvas.translate(0, output.scroll_y - row * tileHeight);
            for (size_t i = 0; i < output.layers.size(); ++i) {
                if (!output.layers[i].parent)
                    drawLayer(canvas, output, i);
            }
            if (!output.error.empty()) {
                output.frame.clear();
                return;
            }
            output.frame.push_back(std::move(surface));
        }
    }

    double animationWakeDelay() const
    {
        if (!flatten || !scene)
            return -1;
        double next = -1;
        for (auto& layer : scene->layers) {
            for (auto& animation : layer.animations) {
                auto& state = animation.state;
                if (state.paused)
                    continue;
                double elapsed = state.elapsed + std::chrono::duration<double>(Clock::now() - animation.captured).count();
                if (state.iterations >= 0 && elapsed >= state.iterations * state.duration) {
                    double previous = state.elapsed + std::chrono::duration<double>(last_animation_frame - animation.captured).count();
                    if (previous < state.iterations * state.duration)
                        next = 0;
                    continue;
                }
                double delay = elapsed < 0 ? -elapsed : 1.0 / 60;
                next = next < 0 ? delay : std::min(next, delay);
            }
        }
        return next;
    }

    // called with the lock held
    void publish(std::shared_ptr<yozora_scene> result, uint64_t ticket, long long elapsed)
    {
        paint_ms += elapsed;
        if (!result || revision.load() != ticket)
            return;
        tiles += result->rasterized;
        partial += result->partial;
        output = std::move(result);
        ++published;
        if (output->rasterized)
            ++paints;
    }

    static void* run(void* context)
    {
        auto& state = *static_cast<State*>(context);
        for (;;) {
            pthread_mutex_lock(&state.lock);
            if (state.refine_pending && Clock::now() >= state.refine_at) {
                state.refine_pending = false;
                state.requested = true;
            }
            while (!state.stopping && !state.clear_cache && (!state.requested || !state.scene)) {
                double delay = state.animationWakeDelay();
                if (state.refine_pending) {
                    double until_refine = std::max(0.0, std::chrono::duration<double>(state.refine_at - Clock::now()).count());
                    delay = delay < 0 ? until_refine : std::min(delay, until_refine);
                }
                if (delay < 0)
                    pthread_cond_wait(&state.wake, &state.lock);
                else {
                    struct timeval now;
                    if (gettimeofday(&now, nullptr)) {
                        std::fprintf(stderr, "yozora: cannot read the compositor clock: %d\n", errno);
                        std::abort();
                    }
                    struct timespec until { now.tv_sec, static_cast<long>(now.tv_usec) * 1000 };
                    delay = std::min(delay, 60.0);
                    auto nanoseconds = static_cast<int64_t>(delay * 1000000000);
                    until.tv_sec += nanoseconds / 1000000000;
                    until.tv_nsec += nanoseconds % 1000000000;
                    if (until.tv_nsec >= 1000000000) {
                        ++until.tv_sec;
                        until.tv_nsec -= 1000000000;
                    }
                    if (pthread_cond_timedwait(&state.wake, &state.lock, &until) == ETIMEDOUT)
                        state.requested = true;
                }
            }
            if (state.stopping) {
                pthread_mutex_unlock(&state.lock);
                return nullptr;
            }
            if (state.clear_cache) {
                state.clear_cache = false;
                state.trim_unused = false;
                pthread_mutex_unlock(&state.lock);
                state.cache.clear();
                state.cache_bytes = 0;
                continue;
            }
            if (state.trim_unused) {
                state.trim_unused = false;
                uint64_t keep_from = state.pass_started;
                pthread_mutex_unlock(&state.lock);
                // what is on screen and its margin was touched by the last pass and stays, so the page is not blank while it is painted again
                for (auto entry = state.cache.begin(); entry != state.cache.end();) {
                    if (entry->second.used <= keep_from) {
                        state.cache_bytes -= entry->second.bytes;
                        entry = state.cache.erase(entry);
                    } else
                        ++entry;
                }
                continue;
            }
            auto scene = state.scene;
            int scroll = state.scroll_y;
            bool flat = state.flatten;
            auto ticket = state.revision.load();
            auto tick = state.scroll_tick.load();
            if (scroll != state.last_target) {
                state.direction = scroll > state.last_target ? 1 : -1;
                state.last_target = scroll;
            }
            bool viewport_pass = !flat && state.needsViewportPass(*scene, scroll);
            // the page moved within the last moments: tiles of the screen that are missing are made coarse
            bool moving = state.last_scroll_move != Clock::time_point() && Clock::now() - state.last_scroll_move < std::chrono::milliseconds(150);
            bool coarse = !flat && moving && scene->scale > 1.01f;
            state.requested = false;
            // this pass is the refinement that was waited for
            if (state.refine_pending && Clock::now() >= state.refine_at)
                state.refine_pending = false;
            state.working = true;
            state.pass_started = state.sequence;
            pthread_mutex_unlock(&state.lock);
            auto began = Clock::now();
            size_t first_tiles = 0;
            unsigned first_coarse = 0;
            if (viewport_pass) {
                // the viewport reaches the screen before the margin is made
                auto first = state.render(*scene, scroll, flat, ticket, true, tick, coarse);
                first_tiles = first ? first->images.size() : 0;
                first_coarse = first ? first->coarse : 0;
                pthread_mutex_lock(&state.lock);
                state.publish(std::move(first), ticket, std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - began).count());
                pthread_mutex_unlock(&state.lock);
                began = Clock::now();
            }
            auto output = state.render(*scene, scroll, flat, ticket, false, tick, coarse);
            unsigned coarse_tiles = first_coarse + (output ? output->coarse : 0);
            auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - began).count();
            pthread_mutex_lock(&state.lock);
            state.working = false;
            state.last_animation_frame = began;
            bool whole = output && output->error.empty() && state.revision.load() == ticket;
            if (whole) {
                auto reach = state.margin(*scene);
                state.settled_generation = scene->generation;
                state.settled_top = scroll - static_cast<int>(std::ceil(reach.top));
                state.settled_bottom = scroll + static_cast<int>(scene->height) + static_cast<int>(std::ceil(reach.bottom));
            } else
                state.settled_generation = 0;
            // coarse tiles are on screen: the crisp ones are made when the page has been still for a moment, the screen first
            if (coarse_tiles) {
                state.refine_pending = true;
                state.refine_at = Clock::now() + std::chrono::milliseconds(170);
                state.settled_generation = 0;
            }
            // a margin pass that found nothing to add is the frame the viewport pass already published
            if (viewport_pass && output && !output->rasterized && output->images.size() == first_tiles)
                state.paint_ms += elapsed;
            else
                state.publish(std::move(output), ticket, elapsed);
            pthread_mutex_unlock(&state.lock);
        }
    }
};

// raster_threads 0 takes the process pool, 1 paints on the pass thread alone, more make an own pool that wide
static std::shared_ptr<TilePool> chooseTilePool(unsigned raster_threads)
{
    if (!raster_threads) {
        auto& shared = sharedTilePool();
        return std::shared_ptr<TilePool>(&shared, [](TilePool*) { });
    }
    if (raster_threads == 1)
        return nullptr;
    return std::make_shared<TilePool>(std::min(raster_threads, 4u) - 1);
}

Raster::Raster(size_t byte_limit, unsigned raster_threads) : m_state(std::make_unique<State>(byte_limit, chooseTilePool(raster_threads)))
{
    int error = pthread_create(&m_state->thread, nullptr, State::run, m_state.get());
    if (error) {
        std::fprintf(stderr, "yozora: raster thread did not start: %d\n", error);
        std::abort();
    }
}

Raster::~Raster()
{
    auto& state = *m_state;
    pthread_mutex_lock(&state.lock);
    state.stopping = true;
    ++state.revision;
    pthread_cond_signal(&state.wake);
    pthread_mutex_unlock(&state.lock);
    pthread_join(state.thread, nullptr);
    pthread_cond_destroy(&state.wake);
    pthread_mutex_destroy(&state.lock);
}

void Raster::submit(std::shared_ptr<const Scene> scene)
{
    auto& state = *m_state;
    pthread_mutex_lock(&state.lock);
    bool incompatible = !state.scene || state.scene->width != scene->width || state.scene->height != scene->height
        || state.scene->scale != scene->scale || state.scene->page_zoom != scene->page_zoom;
    state.scene = std::move(scene);
    // a scene recorded before the latest finger move must not rewind the raster viewport
    if (state.scene->scroll_revision >= state.scroll_revision) {
        if (state.scroll_y != state.scene->scroll_y)
            { ++state.scroll_tick; state.last_scroll_move = Clock::now(); }
        state.scroll_y = state.scene->scroll_y;
        state.scroll_revision = state.scene->scroll_revision;
    }
    state.requested = true;
    // finish an in-flight frame while mutations replace only the pending scene, otherwise a busy page can starve raster
    if (incompatible)
        ++state.revision;
    pthread_cond_signal(&state.wake);
    pthread_mutex_unlock(&state.lock);
}

void Raster::scroll(int y, uint64_t revision)
{
    auto& state = *m_state;
    pthread_mutex_lock(&state.lock);
    if (!revision)
        revision = state.scroll_revision + 1;
    if (revision > state.scroll_revision) {
        state.scroll_revision = revision;
        if (state.scroll_y != y)
            { ++state.scroll_tick; state.last_scroll_move = Clock::now(); }
        state.scroll_y = y;
        state.requested = true;
        pthread_cond_signal(&state.wake);
    }
    pthread_mutex_unlock(&state.lock);
}

void Raster::reset()
{
    auto& state = *m_state;
    pthread_mutex_lock(&state.lock);
    ++state.revision;
    state.scene.reset();
    state.scroll_revision = 0;
    state.output.reset();
    state.requested = false;
    state.clear_cache = true;
    pthread_cond_signal(&state.wake);
    pthread_mutex_unlock(&state.lock);
}

void Raster::trimUnused()
{
    auto& state = *m_state;
    pthread_mutex_lock(&state.lock);
    state.trim_unused = true;
    pthread_cond_signal(&state.wake);
    pthread_mutex_unlock(&state.lock);
}

bool Raster::pending() const
{
    auto& state = *m_state;
    pthread_mutex_lock(&state.lock);
    bool pending = state.requested || state.working;
    pthread_mutex_unlock(&state.lock);
    return pending;
}

std::string Raster::error() const
{
    auto& state = *m_state;
    pthread_mutex_lock(&state.lock);
    auto error = state.output ? state.output->error : std::string();
    pthread_mutex_unlock(&state.lock);
    return error;
}

yozora_scene* Raster::takeScene()
{
    auto& state = *m_state;
    pthread_mutex_lock(&state.lock);
    yozora_scene* output = nullptr;
    if (state.scene_taken != state.published && state.output) {
        state.scene_taken = state.published;
        output = state.output.get();
        yozora_scene_retain(output);
    }
    pthread_mutex_unlock(&state.lock);
    return output;
}

bool Raster::takeFrame(yozora_frame& frame)
{
    auto& state = *m_state;
    frame = { };
    pthread_mutex_lock(&state.lock);
    if (!state.flatten) {
        state.flatten = true;
        state.requested = true;
        ++state.revision;
        pthread_cond_signal(&state.wake);
    }
    state.ui_frame_older = state.ui_frame_before;
    state.ui_frame_before = state.ui_frame;
    bool changed = state.frame_taken != state.published && state.output && !state.output->frame.empty();
    if (changed) {
        state.frame_taken = state.published;
        state.ui_frame = state.output;
        for (auto& surface : state.ui_frame->frame) {
            SkPixmap pixels;
            if (!surface->peekPixels(&pixels))
                continue;
            auto& tile = frame.tiles[frame.count];
            tile = { static_cast<const uint8_t*>(pixels.addr()), pixels.rowBytes(), static_cast<unsigned>(pixels.width()), static_cast<unsigned>(pixels.height()),
                state.ui_frame->first_row + static_cast<int>(frame.count) * tileHeight, state.ui_frame->scale };
            ++frame.count;
        }
    }
    pthread_mutex_unlock(&state.lock);
    return changed;
}

void Raster::statistics(yozora_core_stats& stats) const
{
    auto& state = *m_state;
    pthread_mutex_lock(&state.lock);
    stats.paint_ms = state.paint_ms;
    stats.paints = state.paints;
    stats.tiles_full = state.tiles - state.partial;
    stats.tiles_partial = state.partial;
    pthread_mutex_unlock(&state.lock);
}

}
