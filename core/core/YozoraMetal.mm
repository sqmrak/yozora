#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>

#include "YozoraMetal.h"
#include "yozora_log.h"
#include "yozora_budget.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkImageGenerator.h"
#include "include/core/SkPixmap.h"
#include "include/core/SkSurface.h"
#include "include/gpu/ganesh/GrBackendSurface.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/mtl/GrMtlBackendContext.h"
#include "include/gpu/ganesh/mtl/GrMtlBackendSurface.h"
#include "include/gpu/ganesh/mtl/GrMtlDirectContext.h"
#include "include/private/chromium/GrPromiseImageTexture.h"
#include "include/private/chromium/SkImageChromium.h"
#include "include/private/chromium/GrDeferredDisplayListRecorder.h"
#include <atomic>
#include <cstdlib>
#include <functional>
#include <chrono>
#include <vector>

namespace {
// runs a function when the scope ends, on every path out of it
struct ScopeExit {
    std::function<void()> function;
    ~ScopeExit() { function(); }
};

dispatch_queue_t gpuQueue()
{
    static dispatch_queue_t queue = dispatch_queue_create("com.sqmrak.yozora.raster", DISPATCH_QUEUE_SERIAL);
    return queue;
}

std::atomic<bool> allowed { false };
std::atomic<unsigned long long> paintedTiles { 0 };
std::atomic<unsigned long long> fallenTiles { 0 };
std::atomic<int> readyState { 3 };
std::atomic<unsigned long long> heldBytes { 0 };
id<MTLDevice> device;
id<MTLCommandQueue> queue;
sk_sp<GrDirectContext> context;
GrSurfaceCharacterization format;
std::vector<sk_cfp<IOSurfaceRef>> surfaces;
size_t allocated;
bool unavailable;
std::chrono::steady_clock::time_point resumeAt;

API_AVAILABLE(ios(11.0)) bool idle(IOSurfaceRef surface)
{
    // the image generator and CALayer each retain the surface, the render server holds a use count
    return CFGetRetainCount(surface) == 1 && !IOSurfaceIsInUse(surface);
}

API_AVAILABLE(ios(11.0)) void trim()
{
    std::erase_if(surfaces, [](const auto& surface) {
        if (!idle(surface.get()))
            return false;
        allocated -= IOSurfaceGetAllocSize(surface.get());
        heldBytes = allocated;
        return true;
    });
}

API_AVAILABLE(ios(11.0)) IOSurfaceRef acquire(int width, int height, size_t budget)
{
    for (auto& surface : surfaces) {
        if (IOSurfaceGetWidth(surface.get()) == static_cast<size_t>(width)
            && IOSurfaceGetHeight(surface.get()) == static_cast<size_t>(height) && idle(surface.get()))
            return surface.get();
    }
    size_t row = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, static_cast<size_t>(width) * 4);
    if (!row || row > budget / height)
        return nullptr;
    size_t bytes = IOSurfaceAlignProperty(kIOSurfaceAllocSize, row * height);
    if (bytes > budget)
        return nullptr;
    if (allocated > budget - bytes)
        trim();
    if (allocated > budget - bytes)
        return nullptr;
    NSDictionary* properties = @{
        (__bridge NSString*)kIOSurfaceWidth: @(width), (__bridge NSString*)kIOSurfaceHeight: @(height),
        (__bridge NSString*)kIOSurfaceBytesPerElement: @4, (__bridge NSString*)kIOSurfaceBytesPerRow: @(row),
        (__bridge NSString*)kIOSurfacePixelFormat: @((uint32_t)'BGRA')
    };
    sk_cfp<IOSurfaceRef> surface(IOSurfaceCreate((__bridge CFDictionaryRef)properties));
    if (!surface || IOSurfaceGetAllocSize(surface.get()) > budget - allocated)
        return nullptr;
    allocated += IOSurfaceGetAllocSize(surface.get());
    heldBytes = allocated;
    surfaces.push_back(std::move(surface));
    return surfaces.back().get();
}

// snapshots and CPU partial paints read the shared storage only when Skia requests pixels
class API_AVAILABLE(ios(11.0)) SurfaceImage final : public SkImageGenerator {
public:
    SurfaceImage(const SkImageInfo& info, IOSurfaceRef surface)
        : SkImageGenerator(info), m_surface(SkCFSafeRetain(surface)) { }
private:
    bool onGetPixels(const SkImageInfo& info, void* dst, size_t stride, const Options&) override
    {
        if (IOSurfaceLock(m_surface.get(), kIOSurfaceLockReadOnly, nullptr))
            return false;
        SkPixmap pixels(getInfo(), IOSurfaceGetBaseAddress(m_surface.get()), IOSurfaceGetBytesPerRow(m_surface.get()));
        bool copied = pixels.addr() && pixels.readPixels(info, dst, stride);
        return !IOSurfaceUnlock(m_surface.get(), kIOSurfaceLockReadOnly, nullptr) && copied;
    }
    sk_cfp<IOSurfaceRef> m_surface;
};

API_AVAILABLE(ios(11.0)) GrBackendTexture textureFor(IOSurfaceRef storage, int width, int height)
{
    auto descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
        width:width height:height mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor iosurface:storage plane:0];
    if (!texture)
        return {};
    GrMtlTextureInfo info;
    info.fTexture.retain((__bridge GrMTLHandle)texture);
    return GrBackendTextures::MakeMtl(width, height, skgpu::Mipmapped::kNo, info);
}

API_AVAILABLE(ios(11.0)) sk_sp<SkSurface> wrap(IOSurfaceRef storage, int width, int height)
{
    auto backend = textureFor(storage, width, height);
    return SkSurfaces::WrapBackendTexture(context.get(), backend, kTopLeft_GrSurfaceOrigin, 1,
        kBGRA_8888_SkColorType, nullptr, nullptr);
}

// the storage is shared memory and the command buffer has completed, so one pass over the alpha bytes
// replaces a second gpu pass with its own wait
API_AVAILABLE(ios(11.0)) bool scanAlpha(IOSurfaceRef storage, int width, int height, bool* empty, bool* opaque)
{
    if (IOSurfaceLock(storage, kIOSurfaceLockReadOnly, nullptr))
        return false;
    auto* base = static_cast<const uint8_t*>(IOSurfaceGetBaseAddress(storage));
    size_t stride = IOSurfaceGetBytesPerRow(storage);
    bool visible = false;
    bool translucent = false;
    for (int y = 0; base && y < height && !(visible && translucent); ++y) {
        const uint8_t* row = base + y * stride;
        for (int x = 0; x < width; ++x) {
            uint8_t alpha = row[x * 4 + 3];
            visible |= alpha != 0;
            translucent |= alpha != 255;
        }
    }
    bool unlocked = !IOSurfaceUnlock(storage, kIOSurfaceLockReadOnly, nullptr);
    *empty = !visible;
    *opaque = !translucent;
    return base && unlocked;
}

API_AVAILABLE(ios(11.0)) bool prepare(size_t budget, size_t scratch)
{
    if (!allowed || unavailable || std::chrono::steady_clock::now() < resumeAt)
        return false;
    if (context)
        return true;
    const char* step = "device";
    device = MTLCreateSystemDefaultDevice();
    if (device) {
        step = "command queue";
        queue = [device newCommandQueue];
    }
    if (queue) {
        step = "Ganesh context";
        GrMtlBackendContext backend;
        backend.fDevice.retain((__bridge GrMTLHandle)device);
        backend.fQueue.retain((__bridge GrMTLHandle)queue);
        context = GrDirectContexts::MakeMetal(backend);
    }
    if (context) {
        context->setResourceCacheLimit(scratch);
        step = "IOSurface";
        auto storage = acquire(1, 1, budget);
        if (storage) {
            step = "texture of the IOSurface";
            auto surface = wrap(storage, 1, 1);
            if (surface) {
                step = "surface characterization";
                if (surface->characterize(&format)) {
                    readyState = 1;
                    yozora_log(YOZORA_LOG_INFO, "raster", "Metal tiles ready on %s", [[device name] UTF8String]);
                    return true;
                }
            }
        }
    }
    context.reset();
    queue = nil;
    device = nil;
    unavailable = true;
    readyState = 2;
    yozora_log(YOZORA_LOG_INFO, "raster", "Metal tiles unavailable: the step '%s' failed (surface budget %zu)", step, budget);
    return false;
}
}

void yozora_metal_set_allowed(int value)
{
    // YOZORA_METAL=0 keeps every tile on the cpu whatever the setting says
    const char* override = getenv("YOZORA_METAL");
    if (override && override[0] == '0')
        value = 0;
    allowed.store(value != 0);
    if (!value)
        dispatch_sync(gpuQueue(), ^{ });
}

void yozora_metal_trim()
{
    dispatch_sync(gpuQueue(), ^{
        resumeAt = std::chrono::steady_clock::now() + std::chrono::seconds(20);
        if (@available(iOS 11, *)) {
            trim();
            if (allowed && context)
                context->freeGpuResources();
        }
    });
}

static sk_sp<SkImage> paintOnGpu(int width, int height, size_t budget, SkImage* previous, void* previousSurface,
    void (*draw)(SkCanvas&, SkImage*, void*), void* job, void** contents, bool* empty, bool* opaque)
{
    if (@available(iOS 11, *)) {
        size_t surfaceBudget, scratchBudget;
        yozora_metal_budget(budget, &surfaceBudget, &scratchBudget);
        GrSurfaceCharacterization characterization;
        auto* target = &characterization;
        sk_sp<SkImage> prior = sk_ref_sp(previous);
        auto* priorImage = &prior;
        dispatch_sync(gpuQueue(), ^{
            @autoreleasepool {
                if (!prepare(surfaceBudget, scratchBudget))
                    return;
                *target = format.createResized(width, height);
                if (previousSurface) {
                    auto backend = textureFor(static_cast<IOSurfaceRef>(previousSurface), width, height);
                    auto promise = GrPromiseImageTexture::Make(backend);
                    priorImage->reset();
                    if (promise) {
                        *priorImage = SkImages::PromiseTextureFrom(context->threadSafeProxy(), backend.getBackendFormat(),
                            {width, height}, skgpu::Mipmapped::kNo, kTopLeft_GrSurfaceOrigin, kBGRA_8888_SkColorType,
                            kPremul_SkAlphaType, nullptr,
                            [](void* value) { return sk_ref_sp(static_cast<GrPromiseImageTexture*>(value)); },
                            [](void* value) { static_cast<GrPromiseImageTexture*>(value)->unref(); }, promise.release());
                    }
                }
            }
        });
        if (!characterization.isValid() || (previous && !prior))
            return nullptr;
        GrDeferredDisplayListRecorder recorder(characterization);
        auto canvas = recorder.getCanvas();
        if (!canvas)
            return nullptr;
        draw(*canvas, prior.get(), job);
        auto ddl = recorder.detach();
        if (!ddl)
            return nullptr;
        sk_sp<SkImage> image;
        auto* output = &image;
        auto* recorded = &ddl;
        dispatch_sync(gpuQueue(), ^{
            @autoreleasepool {
                // the list and the promise image hold textures of the Ganesh cache, which is not thread safe: the last reference goes on this
                // queue and not on the thread that painted, where it raced with the next tile and trapped in GrResourceCache
                ScopeExit release { [priorImage, recorded] { priorImage->reset(); recorded->reset(); } };
                if (!allowed || std::chrono::steady_clock::now() < resumeAt)
                    return;
                auto storage = acquire(width, height, surfaceBudget);
                auto surface = storage ? wrap(storage, width, height) : nullptr;
                if (!surface || !skgpu::ganesh::DrawDDL(surface.get(), *recorded))
                    return;
                context->flush();
                if (!context->submit(GrSyncCpu::kYes) || context->abandoned() || !scanAlpha(storage, width, height, empty, opaque))
                    return;
                auto info = SkImageInfo::Make(width, height, kBGRA_8888_SkColorType, kPremul_SkAlphaType);
                *output = SkImages::DeferredFromGenerator(std::make_unique<SurfaceImage>(info, storage));
                if (*output)
                    *contents = storage;
            }
        });
        return image;
    }
    return nullptr;
}

sk_sp<SkImage> yozora_metal_tile(int width, int height, size_t budget, SkImage* previous, void* previousSurface,
    void (*draw)(SkCanvas&, SkImage*, void*), void* job, void** contents, bool* empty, bool* opaque)
{
    if (!allowed || width <= 0 || height <= 0)
        return nullptr;
    auto image = paintOnGpu(width, height, budget, previous, previousSurface, draw, job, contents, empty, opaque);
    ++(image ? paintedTiles : fallenTiles);
    return image;
}

void yozora_metal_info_read(yozora_metal_info* info)
{
    if (!info)
        return;
    info->state = allowed ? readyState.load() : 0;
    info->tiles = paintedTiles.load();
    info->fallbacks = fallenTiles.load();
    info->surface_bytes = heldBytes.load();
}
