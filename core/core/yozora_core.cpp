#include "config.h"
#include "YozoraCoreInternal.h"
#include "YozoraScene.h"
#include "YozoraCookies.h"
#include "YozoraCoreThread.h"
#include "../yozora_log.h"
#include "../yozora_address.h"
#include "YozoraSites.h"
#include "YozoraStorage.h"
#include "YozoraBytecodeCache.h"
#include "YozoraPrivateSession.h"
#include "YozoraHttpCache.h"
#include "YozoraIDB.h"
#include "YozoraCacheStorage.h"
#include "YozoraLoaderStrategy.h"
#include "CurlContext.h"
#include "CurlSSLHandle.h"
#include "CommonVM.h"
#include "Document.h"
#include "CharacterRange.h"
#include "CompositionHighlight.h"
#include "Editor.h"
#include "Element.h"
#include "FocusController.h"
#include "FrameSelection.h"
#include "HTMLFormControlElement.h"
#include "NodeInlines.h"
#include "HTMLInputElement.h"
#include "HTMLTextAreaElement.h"
#include "HandleUserInputEventResult.h"
#include "PlatformKeyboardEvent.h"
#include "PlatformMouseEvent.h"
#include "PlatformTouchEvent.h"
#include "PlatformTouchPoint.h"
#include "RemoteFrameGeometryTransformer.h"
#include "WindowsKeyboardCodes.h"
#include "yozora_budget.h"
#include "yozora_keys.h"
#include "yozora_zoom.h"
#include "DocumentView.h"
#include "EventHandler.h"
#include "FontManagerYozora.h"
#include "FrameLoadRequest.h"
#include "FrameLoader.h"
#include "YozoraDownloads.h"
#include "NavigationAction.h"
#include "ResourceRequest.h"
#include "HitTestResult.h"
#include "LocalFrameInlines.h"
#include "LocalFrameView.h"
#include "MemoryCache.h"
#include "MemoryRelease.h"
#include "PageConfiguration.h"
#include "PlatformScreen.h"
#include "RenderBox.h"
#include "RenderBoxInlines.h"
#include "RenderLayer.h"
#include "RenderLayerScrollableArea.h"
#include "ScrollableArea.h"
#include "HitTestRequest.h"
#include "RenderObjectInlines.h"
#include "HitTestResult.h"
#include "TextGranularity.h"
#include "VisiblePosition.h"
#include "VisibleSelection.h"
#include "ProcessWarming.h"
#include "ResourceRequest.h"
#include "Settings.h"
#include <JavaScriptCore/InitializeThreading.h>
#include <JavaScriptCore/ExecutableAllocator.h>
#include <JavaScriptCore/Options.h>
#include <JavaScriptCore/JSLock.h>
#include <JavaScriptCore/VM.h>
#include <JavaScriptCore/Watchdog.h>
#include <wtf/MainThread.h>
#include <wtf/RunLoop.h>
#include <wtf/Scope.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/MonotonicTime.h>
#include <wtf/Seconds.h>
#include <wtf/WallTime.h>
#include <skia/core/SkGraphics.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/mman.h>
#include <sys/stat.h>
#if defined(__APPLE__)
#include <sys/sysctl.h>
#endif
#include <unistd.h>

using namespace WebCore;
using namespace WTF::StringLiterals;

// milliseconds since the first message, to see where a page load spends its time
static long long log_time_ms()
{
    static MonotonicTime start = MonotonicTime::now();
    return static_cast<long long>((MonotonicTime::now() - start).milliseconds());
}

void yozora_core_message(yozora_core& core, const char* utf8)
{
    // an ASCIILiteral with Cyrillic bytes would be read as Latin-1, so fixed messages stay plain UTF-8
    std::snprintf(core.status, sizeof(core.status), "%s", utf8);
    std::fprintf(stderr, "yozora: [%6lld ms] %s\n", log_time_ms(), core.status);
}

void yozora_core_message(yozora_core& core, const WTF::String& message)
{
    auto text = message.left(160).utf8();
    std::snprintf(core.status, sizeof(core.status), "%s", text.data());
    std::fprintf(stderr, "yozora: [%6lld ms] %s\n", log_time_ms(), core.status);
}

// style resolution of the first empty document reads the screen, so it must exist before the page
static void update_screen(unsigned width, unsigned height)
{
    ScreenData data;
    data.screenRect = { 0, 0, static_cast<float>(width), static_cast<float>(height) };
    data.screenAvailableRect = data.screenRect;
    data.screenDepth = 24;
    data.screenDepthPerComponent = 8;
    ScreenProperties properties;
    properties.primaryDisplayID = 1;
    properties.screenDataMap.add(1, data);
    PlatformScreen::updateSingletonProperties(WTF::move(properties));
}

extern "C" void yozora_device_info(yozora_device* device)
{
    if (!device)
        return;
    unsigned cores = 1;
    unsigned long long memory = 256ull * 1024 * 1024;
#if defined(__APPLE__)
    int count = 0;
    size_t size = sizeof(count);
    if (!sysctlbyname("hw.ncpu", &count, &size, nullptr, 0) && count > 0)
        cores = static_cast<unsigned>(count);
    uint64_t bytes = 0;
    size = sizeof(bytes);
    // 32-bit ios 5 and 6 answer hw.memsize with eight bytes like the later systems
    if (!sysctlbyname("hw.memsize", &bytes, &size, nullptr, 0) && bytes)
        memory = bytes;
#else
    long count = sysconf(_SC_NPROCESSORS_ONLN);
    if (count > 0)
        cores = static_cast<unsigned>(count);
    long pages = sysconf(_SC_PHYS_PAGES), page = sysconf(_SC_PAGESIZE);
    if (pages > 0 && page > 0)
        memory = static_cast<unsigned long long>(pages) * static_cast<unsigned long long>(page);
#endif
    if (const char* value = std::getenv("YOZORA_DEVICE_CORES"))
        cores = std::max(1, std::atoi(value));
    if (const char* value = std::getenv("YOZORA_DEVICE_MEMORY_MB"))
        memory = static_cast<unsigned long long>(std::max(64, std::atoi(value))) * 1024 * 1024;
    device->cores = cores;
    device->memory_mb = static_cast<unsigned>(memory / (1024 * 1024));
}

// the phones go from 128 MB and one core (iPhone 3GS) to 6 GB and more: caches, the growth of the script heap, the optimizing compiler and the reach of
// tiles follow the memory (the table is core/yozora_budget.c)
static yozora_memory_limits memory_limits()
{
    yozora_device device;
    yozora_device_info(&device);
    yozora_memory_limits limits;
    yozora_memory_limits_for(device.memory_mb, &limits);
    return limits;
}

static unsigned device_cores()
{
    yozora_device device;
    yozora_device_info(&device);
    return device.cores;
}

// where the bytecode cache lives, set by the interface thread before the first core and opened by the core thread once WTF runs
static std::string& bytecode_cache_directory()
{
    static std::string directory;
    return directory;
}

static uint64_t& bytecode_cache_limit()
{
    static uint64_t limit = 0;
    return limit;
}

// fonts, strategies and the root file exist once per process and every tab core reuses them. the shared vm
// and the moment the core thread last finished a pass, which the interface thread reads to spot a page that
// does not answer
static std::atomic<JSC::VM*> script_vm { nullptr };
static std::atomic<long long> last_pass_ms { 0 };

static long long steady_ms()
{
    return static_cast<long long>(MonotonicTime::now().secondsSinceEpoch().milliseconds());
}

static std::atomic<int> jit_requested { 1 };

extern "C" void yozora_set_jit_requested(int enabled)
{
    jit_requested = enabled ? 1 : 0;
}

extern "C" void yozora_jit_info_read(yozora_jit_info* info)
{
    if (!info)
        return;
    *info = { };
    info->requested = jit_requested.load();
    info->forced_off = std::getenv("YOZORA_NO_JIT") ? 1 : 0;
#if ENABLE(JIT)
    info->compiled = 1;
    info->active = JSC::Options::useJIT() ? 1 : 0;
#if ENABLE(DFG_JIT)
    info->dfg = info->active && JSC::Options::useDFGJIT() ? 1 : 0;
#endif
    info->regexp = info->active && JSC::Options::useRegExpJIT() ? 1 : 0;
    info->concurrent = info->active && JSC::Options::useConcurrentJIT() ? 1 : 0;
#if ENABLE(FTL_JIT)
    info->ftl = info->active && info->dfg && JSC::Options::useFTLJIT() ? 1 : 0;
#endif
    if (info->active) {
        info->pool_used = JSC::ExecutableAllocator::committedByteCount();
        // the size ExecutableAllocator.cpp reserves for this cpu when the option is not set (jump islands are on for thumb2 and arm64)
        constexpr unsigned long long megabyte = 1024ULL * 1024;
#if CPU(ARM64)
        info->pool_size = 512 * megabyte;
#elif CPU(ARM_THUMB2)
        info->pool_size = 32 * megabyte;
#else
        info->pool_size = 0;
#endif
        if (JSC::Options::jitMemoryReservationSize())
            info->pool_size = JSC::Options::jitMemoryReservationSize();
    }
#endif
}

static void initialize_javascript_on_core()
{
    // without a jit the vm runs in mini mode: every collection is full and the heap may grow only 20% over
    // live size, so a page with 20 to 30 MB of live script data collects every 5 MB of allocation (43
    // collections where 1.5 needs 21 in tests/js/gc-churn.html)
    auto limits = memory_limits();
    JSC::initialize([limits] {
        JSC::Options::miniVMHeapGrowthFactor() = limits.heap_growth_percent / 100.0;
#if ENABLE(JIT)
        // the jit is off by default on 32-bit. a phone that refuses the executable mapping makes
        // JavaScriptCore switch it off while the allocator starts, so nothing is probed here: ios allows one
        // MAP_JIT mapping per process even after munmap and a probe used it up, leaving the real code pool
        // without memory and every script in the interpreter
        bool jit = !std::getenv("YOZORA_NO_JIT") && jit_requested.load();
        JSC::Options::useJIT() = jit;
#if ENABLE(DFG_JIT)
        // upstream leaves DFG off on 32-bit even when the port builds it
        if (!std::getenv("JSC_useDFGJIT"))
            JSC::Options::useDFGJIT() = jit;
#endif
        // the regexp jit passes the script tests on the armv7 baseline build and runs regexps 5 times faster
        JSC::Options::useRegExpJIT() = jit;
#if ENABLE(FTL_JIT)
        // the optimizing compiler needs memory and time that a small phone has not got, JSC_useFTLJIT in the environment still decides when it is set
        if (!std::getenv("JSC_useFTLJIT"))
            JSC::Options::useFTLJIT() = jit && limits.ftl;
#endif
#if CPU(ARM_THUMB2)
        // two armv7 crashes of 1.3.0 on an iPad 4 (ios 10.3.3) ended in generated code: one read at 0x64 inside optimized code, one jumped to the
        // first byte of a page that was not executable, both from a call out of the interpreter into a function. the dfg compiler thread and the
        // collector are the two writers of that memory besides the script thread, so on this cpu a function is compiled on the thread that runs it.
        // JSC_useConcurrentJIT in the environment still decides when it is set
        if (!std::getenv("JSC_useConcurrentJIT"))
            JSC::Options::useConcurrentJIT() = false;
#endif
#endif
    });
#if ENABLE(JIT)
    if (!JSC::Options::useJIT())
        std::fprintf(stderr, "yozora: the jit is off (YOZORA_NO_JIT or no executable memory), scripts run in the interpreter\n");
#endif
}

void yozora_initialize_javascript(void)
{
    // WTF must register the core thread first, before UIKit reserves executable memory
    YozoraCoreThread::call([] { initialize_javascript_on_core(); });
}

static bool initialize_process(const char* fonts, const char* roots, char* error, size_t capacity)
{
    static bool ready = false;
    if (ready)
        return true;
    struct stat info;
    if (!fonts || !roots || stat(roots, &info) || !S_ISREG(info.st_mode) || info.st_size < 1 || info.st_size > 1024 * 1024) {
        std::snprintf(error, capacity, "Не найден набор корневых сертификатов");
        return false;
    }
    if (!initializeYozoraFonts(fonts, error, capacity))
        return false;
    auto limits = memory_limits();
    initialize_javascript_on_core();
    WTF::initializeMainThread();
    // the termination exception that ends a script is created together with the watchdog, which has no time limit here
    {
        Ref vm = commonVM();
        JSC::JSLockHolder lock(vm.get());
        vm->ensureWatchdog();
        script_vm = vm.ptr();
    }
    YozoraCoreThread::attachRunLoop();
    // phones with 512 MB share the smaller cache budget, their live DOM and script heaps need the remaining memory
    size_t bytecode_pending = limits.bytecode_pending_mb;
    if (!bytecode_cache_directory().empty() && !YozoraBytecodeCache::open(String::fromUTF8(bytecode_cache_directory()), bytecode_cache_limit(), bytecode_pending * 1024 * 1024))
        std::fprintf(stderr, "yozora: bytecode cache is off\n");
    installYozoraPlatformStrategies();
    ProcessWarming::prewarmGlobally();
    // decoded images share the process budget with scenes and the script heap
    size_t cache_mb = limits.resource_cache_mb;
    MemoryCache::singleton().setCapacities(0, cache_mb * 1024 * 1024 / 2, cache_mb * 1024 * 1024);
    SkGraphics::SetFontCacheLimit(static_cast<size_t>(limits.font_cache_kb) * 1024);
    CurlContext::singleton().sslHandle().setCACertPath(String::fromUTF8(roots));
    yozora_translate_set_roots(roots);
    yozora_media_install();
    ready = true;
    return true;
}

// what the settings chose, copied under the lock because the interface thread sets it and the core thread applies it
static pthread_mutex_t options_lock = PTHREAD_MUTEX_INITIALIZER;
static yozora_options page_options { 1, 100, 0, 0, 1, 0, 1, 0 };

static yozora_options current_options()
{
    pthread_mutex_lock(&options_lock);
    auto copy = page_options;
    pthread_mutex_unlock(&options_lock);
    return copy;
}

// core thread only
void core_apply_options(yozora_core& core)
{
    auto options = current_options();
    auto& settings = core.page->settings();
    settings.setScriptEnabled(options.javascript != 0);
#if ENABLE(WEBGL)
    // open pages keep the contexts they have, the pages that ask next get none
    settings.setWebGLEnabled(options.webgl != 0);
#endif
    settings.setForcedPrefersReducedMotionAccessibilityValue(options.reduce_motion ? ForcedAccessibilityValue::On : ForcedAccessibilityValue::System);
    // the low power mode of WebCore runs animation frames at 30 a second instead of 60
    core.page->setLowPowerModeEnabledOverrideForTesting(options.reduce_motion ? std::optional<bool>(true) : std::nullopt);
    core.page->setUseColorAppearance(options.dark_appearance != 0, false);
    // Restricted is the lockdown mode of Apple systems, it denies every font that is not on a built-in list of hashes
    settings.setDownloadableBinaryFontTrustedTypes(options.web_fonts ? DownloadableBinaryFontTrustedTypes::Any : DownloadableBinaryFontTrustedTypes::None);
    if (RefPtr frame = core.page->localMainFrame())
        frame->setPageAndTextZoomFactors(core.page_zoom_percent / 100.0f, std::clamp(options.text_zoom_percent, 50, 200) / 100.0f);
    core.dirty = true;
}

// the cores of the process, touched only on the core thread
static Vector<yozora_core*>& live_cores()
{
    static NeverDestroyed<Vector<yozora_core*>> list;
    return list.get();
}

// core thread only: a core that was destroyed while a request for it waited is not run
bool yozora_core_is_live(yozora_core* core)
{
    return live_cores().contains(core);
}

static bool core_thread_tick();

static yozora_core* core_create(const char* fonts, const char* roots, char* error, size_t capacity)
{
    if (!initialize_process(fonts, roots, error, capacity))
        return nullptr;
    update_screen(320, 480);
    auto* core = new yozora_core;
    // the pixel budget follows the device memory, a memory warning drops the cache and the scenes on top of that
    yozora_device device;
    yozora_device_info(&device);
    size_t raster_mb = yozora_raster_budget_mb(device.memory_mb);
    core->raster = std::make_unique<Yozora::Raster>(raster_mb * 1024 * 1024);
    if (yozora_navigation_create(&core->navigation) != YOZORA_OK) {
        delete core;
        std::snprintf(error, capacity, "Не хватает памяти для истории переходов");
        return nullptr;
    }
    core->page = Page::create(yozora_page_configuration(*core));
    yozora_geolocation_install(*core);
    yozora_notification_install(*core);
    auto& settings = core->page->settings();
    // WebCore defaults these to off, the embedder owns them: without the first, no image request is ever made
    settings.setLoadsImagesAutomatically(true);
    settings.setScriptEnabled(true);
    settings.setScriptMarkupEnabled(true);
    settings.setJavaScriptCanOpenWindowsAutomatically(false);
    settings.setAcceleratedCompositingEnabled(true);
    settings.setAcceleratedCompositingForFixedPositionEnabled(true);
    settings.setForceCompositingMode(true);
    settings.setAsyncOverflowScrollingEnabled(true);
    // the storage provider keeps these in memory for the life of the tab, pages that read them no longer fail on null
    settings.setLocalStorageEnabled(true);
    settings.setSessionStorageEnabled(true);
    settings.setNeedsSiteSpecificQuirks(true);
    settings.setTextAreasAreResizable(false);
    // scripts of current sites probe these objects before anything else
    settings.setBeaconAPIEnabled(true);
    settings.setUserActivationAPIEnabled(true);
    settings.setVisualViewportAPIEnabled(true);
    // a date field opens the picker of the interface through the date chooser of the chrome client
    settings.setInputTypeDateEnabled(true);
    settings.setInputTypeDateTimeLocalEnabled(true);
    settings.setInputTypeMonthEnabled(true);
    settings.setInputTypeTimeEnabled(true);
    settings.setInputTypeWeekEnabled(true);
    settings.setInputTypeColorEnabled(true);
    settings.setCompressionStreamEnabled(true);
#if ENABLE(WEBGL)
    // the context is made over the OpenGL ES of the system (core/webgl), WebCore keeps the preference off by
    // default. the option is applied by core_apply_options, a page that starts before it runs must not get a
    // context the setting refused
    settings.setWebGLEnabled(current_options().webgl != 0);
#endif
#if ENABLE(WEB_AUDIO)
    // AudioDestinationYozora feeds the sound device of the port, WebCore keeps the preference off by default
    settings.setWebAudioEnabled(true);
#endif
#if ENABLE(OFFSCREEN_CANVAS)
    // the canvas of a page can hand its drawing to an OffscreenCanvas on the page thread, WebCore keeps the preference off by default
    settings.setOffscreenCanvasEnabled(true);
#endif
#if ENABLE(MEDIA_SOURCE)
    // YozoraMediaSource.cpp turns what a page appends into the HLS stream of the system player, WebCore keeps
    // the preference off by default
    settings.setMediaSourceEnabled(true);
#endif
    // the databases of sites come from the provider of the page configuration
    settings.setIndexedDBAPIEnabled(true);
    // the caches of sites come from the provider of the page configuration too (YozoraCacheStorage.cpp), WebCore keeps
    // the preference off by default and without it a page has no caches object
    settings.setCacheAPIEnabled(true);
    // YozoraNotifications.cpp is the client: permission is asked once per site and what a page shows reaches
    // the interface
    settings.setNotificationsEnabled(true);
    // YozoraGeolocation.cpp is the client, without one getCurrentPosition from google maps reaches a null
    // controller and aborts the core thread
    settings.setGeolocationAPIEnabled(true);
    // photos are decoded at the size they are drawn, a 12 megapixel frame needs 48 MB at full size
    settings.setImageSubsamplingEnabled(true);
    settings.setMinimumFontSize(9);
    settings.setDefaultFontSize(16);
    // the parser keeps the thread up to 500 ms before it lets a pass, tap or timer through, on these phones
    // that is half a second without any of them
    settings.setMaxParseDuration(0.1);
    // a second core decodes large and animated pictures while the first runs the page
    bool spare_core = device_cores() > 1;
    settings.setLargeImageAsyncDecodingEnabled(spare_core);
    settings.setAnimatedImageAsyncDecodingEnabled(spare_core);
    // pictures far below the view load when the page comes near them
    settings.setLazyImageLoadingEnabled(true);
    // WebCore timers run it and the loader already fetches a prefetched resource through the same path as any
    // other. preconnect stays off, the loader strategy has no connection to warm and answers it with an error
    settings.setRequestIdleCallbackEnabled(true);
    settings.setLinkPrefetchEnabled(true);
    // a page may ask for the full screen player, the chrome client answers for videos and for the containers that hold one
    settings.setFullScreenEnabled(true);
    // video plays inside the page, sound needs a tap and only a muted video starts alone. the stream is
    // fetched when the user asks, a feed of twenty videos must not open twenty players on a 512 MB phone
    settings.setAllowsInlineMediaPlayback(true);
    settings.setInlineMediaPlaybackRequiresPlaysInlineAttribute(false);
    settings.setRequiresUserGestureForVideoPlayback(true);
    settings.setRequiresUserGestureForAudioPlayback(true);
    settings.setMediaDataLoadsAutomatically(false);
    core_apply_options(*core);
    RefPtr frame = core->page->localMainFrame();
    frame->setView(LocalFrameView::create(*frame, { 1, 1 }));
    // the native page view scrolls the root, desktop scrollbar layers would consume width and repaint each drag
    frame->view()->setCanHaveScrollbars(false);
    frame->init();
    core->page->setIsVisible(true);
    core->page->setIsInWindow(true);
    // without an active and focused page no element takes focus and no caret is drawn
    core->page->focusController().setActive(true);
    core->page->focusController().setFocused(true);
    yozora_core_message(*core, "Введите адрес страницы");
    live_cores().append(core);
    return core;
}

extern "C" yozora_core* yozora_core_create(const char* fonts, const char* roots, char* error, size_t capacity)
{
    if (!error || !capacity)
        return nullptr;
    error[0] = 0;
    yozora_core* core = nullptr;
    // every WebCore object lives on the core thread, the caller only waits for the first one to exist
    YozoraCoreThread::setTick(core_thread_tick);
    YozoraCoreThread::call([&] { core = core_create(fonts, roots, error, capacity); });
    return core;
}

extern "C" void yozora_core_set_roots(const char* roots)
{
    struct stat info;
    if (!roots || stat(roots, &info) || !S_ISREG(info.st_mode) || info.st_size < 1 || info.st_size > 1024 * 1024)
        return;
    std::string path(roots);
    // the loader reads the path on the core thread, so it is changed there
    YozoraCoreThread::call([&] {
        CurlContext::singleton().sslHandle().setCACertPath(String::fromUTF8(path.c_str()));
        yozora_translate_set_roots(path.c_str());
    });
}

yozora_core* core_create_popup(yozora_core& opener, LocalFrame& frame)
{
    pthread_mutex_lock(&opener.lock);
    bool pending = opener.shared.popup != nullptr;
    pthread_mutex_unlock(&opener.lock);
    if (pending || opener.popup_depth >= 3 || live_cores().size() >= 8) {
        yozora_core_message(opener, "Слишком много открытых окон");
        return nullptr;
    }
    char error[256] { };
    auto* child = core_create(nullptr, nullptr, error, sizeof(error));
    if (!child) {
        yozora_core_message(opener, error);
        return nullptr;
    }
    child->popup_depth = opener.popup_depth + 1;
    child->page->setGroupName(opener.page->groupName());
    opener.page->storageNamespaceProvider().cloneSessionStorageNamespaceForPage(*opener.page, *child->page);
    child->page->localMainFrame()->updateOpener(frame);
    pthread_mutex_lock(&opener.lock);
    opener.shared.popup = child;
    pthread_mutex_unlock(&opener.lock);
    return child;
}

extern "C" yozora_core* yozora_core_take_popup(yozora_core* core)
{
    if (!core)
        return nullptr;
    pthread_mutex_lock(&core->lock);
    auto* popup = std::exchange(core->shared.popup, nullptr);
    pthread_mutex_unlock(&core->lock);
    return popup;
}

extern "C" int yozora_core_close_requested(yozora_core* core)
{
    if (!core)
        return 0;
    pthread_mutex_lock(&core->lock);
    bool requested = core->shared.close_requested;
    pthread_mutex_unlock(&core->lock);
    return requested;
}

// core thread only: answers the held navigation, if any. a stale answer finds nothing
static void core_resolve_external(yozora_core& core, PolicyAction action)
{
    if (auto decision = std::exchange(core.external_decision, nullptr))
        decision(action);
}

bool core_offer_external(yozora_core& core, const NavigationAction& action, const ResourceRequest& request, bool main_frame, CompletionHandler<void(PolicyAction)>& decision)
{
    if (!current_options().external_links)
        return false;
    // a script that navigates on its own, a history step or a reload is not a person following a link; a button
    // handler that sets location arrives as NavigationType::Other with the gesture of the tap
    switch (action.type()) {
    case NavigationType::BackForward:
    case NavigationType::Reload:
    case NavigationType::FormResubmitted:
        return false;
    default:
        break;
    }
    if (!action.processingUserGesture())
        return false;
    auto text = request.url().string().utf8();
    std::string page;
    if (auto* frame = core.page ? core.page->localMainFrame() : nullptr) {
        if (auto* document = frame->document())
            page = document->url().string().utf8().data();
    }
    auto kind = yozora_address_external(text.data(), page.c_str());
    // universal links are for the page the person looks at, a frame inside it keeps its own navigation
    if (kind == YOZORA_EXTERNAL_NONE || (kind == YOZORA_EXTERNAL_UNIVERSAL && !main_frame))
        return false;
    core_resolve_external(core, PolicyAction::Ignore);
    bool universal = kind == YOZORA_EXTERNAL_UNIVERSAL;
    pthread_mutex_lock(&core.lock);
    core.shared.external_url = text.data();
    core.shared.external_universal = universal;
    core.shared.external_pending = true;
    pthread_mutex_unlock(&core.lock);
    if (universal)
        core.external_decision = WTF::move(decision);
    else
        decision(PolicyAction::Ignore);
    return true;
}

extern "C" int yozora_core_take_external(yozora_core* core, char* url, size_t capacity, int* universal)
{
    if (!url || !capacity || !universal)
        return 0;
    url[0] = '\0';
    *universal = 0;
    if (!core)
        return 0;
    bool wanted = false, fits = false, held = false;
    pthread_mutex_lock(&core->lock);
    if (core->shared.external_pending) {
        wanted = true;
        core->shared.external_pending = false;
        held = core->shared.external_universal;
        fits = core->shared.external_url.size() < capacity;
        if (fits) {
            std::memcpy(url, core->shared.external_url.c_str(), core->shared.external_url.size() + 1);
            *universal = held ? 1 : 0;
        }
        core->shared.external_url.clear();
    }
    pthread_mutex_unlock(&core->lock);
    // an address that does not fit cannot be offered: the page loads it, which is what happens without apps
    if (wanted && !fits && held)
        yozora_core_answer_external(core, 0);
    return fits ? 1 : 0;
}

extern "C" void yozora_core_answer_external(yozora_core* core, int opened)
{
    if (!core)
        return;
    YozoraCoreThread::post([core, opened] { core_resolve_external(*core, opened ? PolicyAction::Ignore : PolicyAction::Use); });
}

static void core_destroy(yozora_core* core)
{
    if (auto* popup = yozora_core_take_popup(core))
        core_destroy(popup);
    live_cores().removeFirst(core);
    yozora_media_forget(*core);
    core_resolve_external(*core, PolicyAction::Ignore);
    core->page->localMainFrame()->loader().stopAllLoaders();
    setYozoraHistoryLoad(*core->page, false);
    setYozoraDesktopPage(*core->page, false);
    core->graphics_root = nullptr;
    core->raster.reset();
    core->page = nullptr;
    yozora_navigation_destroy(core->navigation);
    delete core;
}

// no script is ended on a timer. only leaving a page that holds the core thread (new address, back, reload,
// stop, closing the tab) ends it: the request would wait behind the script for ever and a blocked call would
// hold the interface until the system ends the app
static void free_stuck_script()
{
    if (yozora_core_stalled_ms() > 2000)
        yozora_stop_scripts();
}

extern "C" void yozora_core_destroy(yozora_core* core)
{
    if (core)
        free_stuck_script();
    if (core)
        YozoraCoreThread::call([core] { core_destroy(core); });
}

extern "C" void yozora_core_destroy_async(yozora_core* core)
{
    if (core)
        free_stuck_script();
    if (core)
        YozoraCoreThread::post([core] { core_destroy(core); });
}

extern "C" int yozora_core_set_suspended(yozora_core* core, int suspended)
{
    if (!core)
        return 0;
    bool accepted = false;
    YozoraCoreThread::call([&] {
        bool suspend = suspended != 0;
        if (core->suspended == suspend) {
            accepted = true;
            return;
        }
        if (suspend) {
            pthread_mutex_lock(&core->lock);
            bool waiting = core->shared.popup || !core->shared.auth_requests.empty() || !core->shared.media.empty()
                || !core->shared.choices.empty() || !core->shared.files.empty() || !core->shared.dates.empty() || !core->shared.colors.empty()
                || core->shared.external_pending || core->shared.loads_requested != core->shared.loads_started;
            pthread_mutex_unlock(&core->lock);
            // a link held for the apps would stay unanswered in a parked page
            if (core->state != YOZORA_LOAD_COMPLETE || waiting || core->external_decision || !core->auth_waiting.empty() || !core->choice_waiting.empty() || !core->file_waiting.empty()
                || !core->date_waiting.empty() || !core->multi_waiting.empty() || !core->color_waiting.empty() || core->page->mediaPlaybackExists())
                return;
            // transaction and version-change callbacks cannot release shared database locks while suspended
            if (YozoraIDB::hasOpenDatabases())
                return;
            core->suspended = true;
            core->page->setDefersLoading(true);
            core->page->setIsVisible(false);
            core->page->setIsInWindow(false);
            core->page->focusController().setFocused(false);
            core->page->focusController().setActive(false);
            core->page->suspendActiveDOMObjectsAndAnimations();
            core->raster->reset();
            core->recorded_scene.reset();
            yozoraPurgeScene(core->graphics_root.get());
        } else {
            core->suspended = false;
            core->page->setIsInWindow(true);
            core->page->setIsVisible(true);
            core->page->focusController().setActive(true);
            core->page->focusController().setFocused(true);
            core->page->resumeActiveDOMObjectsAndAnimations();
            core->page->setDefersLoading(false);
            core->dirty = true;
            core->rendering = true;
        }
        accepted = true;
    });
    return accepted;
}

static int64_t now_ms()
{
    return static_cast<int64_t>(WallTime::now().secondsSinceEpoch().milliseconds());
}

static void refresh_history_flags(yozora_core& core)
{
    yozora_navigation_snapshot snapshot;
    if (yozora_navigation_read(core.navigation, &snapshot) != YOZORA_OK)
        return;
    core.can_go_back = snapshot.can_go_back;
    core.can_go_forward = snapshot.can_go_forward;
}

enum class LoadKind { Navigate, Reload, History };

// the caller already holds a navigation token for this address
static void start_load(yozora_core& core, const char* address, LoadKind kind)
{
    // a back or forward load shows stored copies of the page and of everything it pulls in
    setYozoraHistoryLoad(*core.page, kind == LoadKind::History);
    RefPtr frame = core.page->localMainFrame();
    // the suspension belongs to the document that is about to go away
    URL url({ }, String::fromUTF8(address));
    core.url = url.string().utf8();
    core.begun = true;
    // the user interface reads the state right after asking for a load, it must not see the old page's state
    core.state = YOZORA_LOAD_LOADING;
    core.page_error = YOZORA_PAGE_ERROR_OTHER;
    core.progress = 0.05f;
    ResourceRequest request(WTF::move(url));
    request.setTimeoutInterval(30);
    if (kind == LoadKind::Reload)
        request.setCachePolicy(ResourceRequestCachePolicy::ReloadIgnoringCacheData);
    else if (kind == LoadKind::History)
        request.setCachePolicy(ResourceRequestCachePolicy::ReturnCacheDataElseLoad);
    FrameLoadRequest load(*frame, WTF::move(request));
    load.setIsRequestFromClientOrUserInput();
    frame->loader().load(WTF::move(load));
}

// the caller reads the state right after asking for a load, the core thread has not seen the request yet
static void mark_loading(yozora_core& core)
{
    pthread_mutex_lock(&core.lock);
    core.shared.state = YOZORA_LOAD_LOADING;
    core.shared.page_error = YOZORA_PAGE_ERROR_OTHER;
    core.shared.progress = 0.05f;
    ++core.shared.loads_requested;
    pthread_mutex_unlock(&core.lock);
}

// the core thread has acted on a request, its own state is the truth from here on
static void load_started(yozora_core& core)
{
    pthread_mutex_lock(&core.lock);
    ++core.shared.loads_started;
    pthread_mutex_unlock(&core.lock);
}

static void fail_load(yozora_core& core, const char* message)
{
    yozora_core_message(core, message);
    core.page_error = YOZORA_PAGE_ERROR_OTHER;
    core.state = YOZORA_LOAD_FAILED;
}

static void core_load(yozora_core& core, const char* input)
{
    auto acknowledge = makeScopeExit([&] { load_started(core); });
    URL url({ }, String::fromUTF8(input));
    if (!url.isValid() || !url.protocolIsInHTTPFamily() || !url.user().isEmpty() || !url.password().isEmpty())
        return fail_load(core, "Введите HTTP или HTTPS адрес без логина и пароля");
    // stopping first lets the old load report its cancellation against its own token
    core.page->localMainFrame()->loader().stopAllLoaders();
    auto text = url.string().utf8();
    yozora_status status = yozora_navigation_begin(core.navigation, text.data(), &core.token);
    if (status != YOZORA_OK) {
        char message[160];
        std::snprintf(message, sizeof(message), "Не удалось начать переход: %s", yozora_status_string(status));
        return fail_load(core, message);
    }
    start_load(core, text.data(), LoadKind::Navigate);
}

static bool has_http_prefix(const char* text)
{
    return !strncasecmp(text, "http://", 7) || !strncasecmp(text, "https://", 8);
}

// the page may be busy for seconds, so the call only checks the text and queues the load, other failures show as a failed state
extern "C" int yozora_core_load(yozora_core* core, const char* input, char* error, size_t capacity)
{
    if (!core || !input || !error || !capacity)
        return 0;
    error[0] = 0;
    if (strnlen(input, 4096) >= 4096) {
        std::snprintf(error, capacity, "Адрес слишком длинный");
        return 0;
    }
    if (!has_http_prefix(input)) {
        std::snprintf(error, capacity, "Введите HTTP или HTTPS адрес без логина и пароля");
        return 0;
    }
    free_stuck_script();
    mark_loading(*core);
    std::string text(input);
    YozoraCoreThread::post([core, text] { core_load(*core, text.c_str()); });
    return 1;
}

static void core_traverse(yozora_core& core, int direction)
{
    auto acknowledge = makeScopeExit([&] { load_started(core); });
    core.page->localMainFrame()->loader().stopAllLoaders();
    yozora_status status = yozora_navigation_traverse(core.navigation, direction, &core.token);
    if (status != YOZORA_OK)
        return;
    yozora_navigation_snapshot snapshot;
    if (yozora_navigation_read(core.navigation, &snapshot) != YOZORA_OK)
        return;
    start_load(core, snapshot.pending_url, LoadKind::History);
}

// the answer is what the last published state allowed, the core thread checks it again
static int traverse(yozora_core* core, int direction)
{
    if (!core)
        return 0;
    pthread_mutex_lock(&core->lock);
    bool allowed = direction < 0 ? core->shared.can_go_back : core->shared.can_go_forward;
    pthread_mutex_unlock(&core->lock);
    if (!allowed)
        return 0;
    free_stuck_script();
    mark_loading(*core);
    YozoraCoreThread::post([core, direction] { core_traverse(*core, direction); });
    return 1;
}

extern "C" int yozora_core_back(yozora_core* core) { return traverse(core, -1); }
extern "C" int yozora_core_forward(yozora_core* core) { return traverse(core, 1); }

extern "C" int yozora_core_reload(yozora_core* core)
{
    if (!core)
        return 0;
    free_stuck_script();
    mark_loading(*core);
    YozoraCoreThread::post([core] {
        auto acknowledge = makeScopeExit([&] { load_started(*core); });
        core->page->localMainFrame()->loader().stopAllLoaders();
        if (yozora_navigation_reload(core->navigation, &core->token) != YOZORA_OK)
            return;
        yozora_navigation_snapshot snapshot;
        if (yozora_navigation_read(core->navigation, &snapshot) != YOZORA_OK)
            return;
        start_load(*core, snapshot.pending_url, LoadKind::Reload);
    });
    return 1;
}

extern "C" void yozora_core_stop(yozora_core* core)
{
    if (!core)
        return;
    free_stuck_script();
    YozoraCoreThread::post([core] {
        core_resolve_external(*core, PolicyAction::Ignore);
        core->page->localMainFrame()->loader().stopAllLoaders();
        if (core->state == YOZORA_LOAD_LOADING)
            core->state = core->committed ? YOZORA_LOAD_COMPLETE : YOZORA_LOAD_IDLE;
        core->progress = 0;
    });
}

void core_nav_started(yozora_core& core, const URL& url)
{
    core.state = YOZORA_LOAD_LOADING;
    core.committed = false;
    core.progress = 0.05f;
    if (core.begun) {
        core.begun = false;
        return;
    }
    // the page started this navigation itself, by a link, a form or a script
    auto text = url.string().utf8();
    if (yozora_navigation_begin(core.navigation, text.data(), &core.token) != YOZORA_OK) {
        core.token = 0;
        return;
    }
    core.url = text;
}

void core_nav_redirected(yozora_core& core, LocalFrame& frame, const URL& url)
{
    auto text = url.string().utf8();
    yozora_status status = yozora_navigation_redirect(core.navigation, core.token, text.data());
    if (status == YOZORA_LIMIT) {
        yozora_core_message(core, "Слишком много перенаправлений");
        frame.loader().stopAllLoaders();
        return;
    }
    if (status == YOZORA_OK)
        core.url = text;
}

// the desktop mode lays the page out 980 points wide where the zoom floor allows: a 390 point view reaches 50
// percent, which is 780 points
static int desktop_zoom_percent(const yozora_core& core)
{
    if (!core.desktop || !core.width)
        return YOZORA_ZOOM_DEFAULT;
    return yozora_zoom_clamp(std::min(YOZORA_ZOOM_DEFAULT, static_cast<int>(core.width) * 100 / 980));
}

// <meta name=viewport content="width=850"> on a 320 point view: the page lays out 850 wide and is scaled to
// the view as in mobile Safari. without it a fixed size page such as Speedometer 3.0 showed enlarged and cut.
// the desktop mode has its own width
void core_viewport_changed(yozora_core& core, float width)
{
    if (core.desktop)
        return;
    int percent = yozora_zoom_for_viewport(static_cast<int>(core.width), width);
    if (percent == core.viewport_zoom_percent)
        return;
    core.viewport_zoom_percent = percent;
    yozora_log(YOZORA_LOG_INFO, "view", "the viewport tag asks for %d points, the page is shown at %d percent", static_cast<int>(width), percent);
    yozora_core_set_page_zoom(&core, percent, 0);
}

void core_nav_committed(yozora_core& core, const URL& url)
{
    core.raster->reset();
    core.recorded_scene.reset();
    // a zoom that the tag of the previous document made does not carry over to a document of the same site
    if (core.viewport_zoom_percent != YOZORA_ZOOM_DEFAULT) {
        core.viewport_zoom_percent = YOZORA_ZOOM_DEFAULT;
        core.page_zoom_percent = desktop_zoom_percent(core);
    }
    // the zoom a user set belongs to the site, another site starts at 100 percent
    if (url.host() != core.zoom_host) {
        core.zoom_host = url.host().toString();
        core.page_zoom_percent = desktop_zoom_percent(core);
    }
    yozora_log(YOZORA_LOG_INFO, "nav", "committed %s", url.host().utf8().data());
    // a new document starts with the default text size
    core_apply_options(core);
    auto text = url.string().utf8();
    yozora_status status = yozora_navigation_commit(core.navigation, core.token, text.data(), "", now_ms());
    if (status != YOZORA_OK)
        return;
    core.url = text;
    core.committed = true;
    core.document_shown = true;
    core.title = CString();
    core.secure = url.protocolIs("https"_s);
    refresh_history_flags(core);
}

void core_nav_finished(yozora_core& core)
{
    yozora_log(YOZORA_LOG_INFO, "nav", "finished");
    core.state = YOZORA_LOAD_COMPLETE;
    core.progress = 1;
    core.dirty = true;
    // late requests of a finished page, such as a script's fetch, are ordinary ones
    setYozoraHistoryLoad(*core.page, false);
    if (yozora_navigation_finish(core.navigation, core.token) != YOZORA_OK)
        return;
    memset(&core.visit, 0, sizeof(core.visit));
    snprintf(core.visit.url, sizeof(core.visit.url), "%s", core.url.data());
    snprintf(core.visit.title, sizeof(core.visit.title), "%s", core.title.data() ? core.title.data() : "");
    core.visit.time_ms = now_ms();
    core.visit_ready = true;
}

void core_nav_downloaded(yozora_core& core)
{
    core.download_handoff = true;
    yozora_navigation_cancel(core.navigation, core.token);
    core.state = core.document_shown ? YOZORA_LOAD_COMPLETE : YOZORA_LOAD_IDLE;
    core.progress = 0;
    core.begun = false;
    refresh_history_flags(core);
}

void core_nav_failed(yozora_core& core, bool cancelled)
{
    if (cancelled)
        yozora_navigation_cancel(core.navigation, core.token);
    else {
        yozora_navigation_fail(core.navigation, core.token, YOZORA_IO);
        core.state = YOZORA_LOAD_FAILED;
        // a cancellation belongs to the load that was replaced, the flag is already the new load's
        setYozoraHistoryLoad(*core.page, false);
    }
    core.progress = 0;
    refresh_history_flags(core);
}

void core_set_title(yozora_core& core, const String& title)
{
    // the history core stores titles under 512 bytes, a longer one is cut by characters
    core.title = title.left(120).utf8();
}
static std::atomic<int> economy_raster { 0 };

static void core_resize(yozora_core& core, unsigned width, unsigned height, float scale)
{
    if (core.width == width && core.height == height && core.scale == scale)
        return;
    // a keyboard or bar that only takes height leaves the tiles valid, they are keyed by layer, place, scale
    // and version and none moved. dropping them left a heavy page white until it laid out and painted again.
    // another width or scale makes new surfaces
    if (core.width != width || core.scale != scale)
        core.raster->reset();
    core.recorded_scene.reset();
    core.scale = scale;
    core.width = width;
    core.height = height;
    core.page->setDeviceScaleFactor(scale);
    RefPtr frame = core.page->localMainFrame();
    frame->view()->setCanHaveScrollbars(false);
    frame->view()->setFrameRect({ 0, 0, static_cast<int>(width), static_cast<int>(height) });
    frame->view()->setNeedsLayoutAfterViewConfigurationChange();
    update_screen(width, height);
    core.dirty = true;
}

extern "C" int yozora_core_resize(yozora_core* core, unsigned width, unsigned height, float scale)
{
    if (!core || !width || !height || width > 2048 || height > 2048 || !(scale >= 1) || scale > 4)
        return 0;
    scale = std::min(scale, 2048.0f / std::max(width, height));
    YozoraCoreThread::post([core, width, height, scale] { core_resize(*core, width, height, scale); });
    return 1;
}

// the blocks that scroll on their own, for the interface to route a drag. the areas come out of a hash set in
// no useful order and a page like a Google answer has hundreds, so a count limit dropped a table wrapper at
// random and its swipe went to the page. only blocks on screen can lie under a finger, so the rest are left
// out
static constexpr size_t maximum_published_scrollers = 256;

static void publish_scrollers(yozora_core& core, LocalFrameView& view)
{
    std::vector<decltype(core.shared.scrollers)::value_type> found;
    auto visible = view.visibleContentRect();
    if (auto* areas = view.scrollableAreas()) {
        for (auto& area : *areas) {
            if (!area.isRenderLayer() || found.size() >= maximum_published_scrollers)
                continue;
            auto& layerArea = uncheckedDowncast<RenderLayerScrollableArea>(area);
            auto& layer = layerArea.layer();
            // the page itself scrolls through the core
            if (layer.isRenderViewLayer())
                continue;
            CheckedPtr box = layer.renderBox();
            if (!box)
                continue;
            bool scrolls_x = box->scrollsOverflowX() && box->hasScrollableOverflowX();
            bool scrolls_y = box->scrollsOverflowY() && box->hasScrollableOverflowY();
            IntRect rect = box->absoluteBoundingBoxRect();
            if ((!scrolls_x && !scrolls_y) || rect.isEmpty() || !rect.intersects(visible))
                continue;
            auto offset = layerArea.scrollOffset();
            auto maximum = layerArea.maximumScrollOffset();
            decltype(core.shared.scrollers)::value_type entry;
            entry.id = reinterpret_cast<uint64_t>(&area);
            entry.x = rect.x();
            entry.y = rect.y();
            entry.width = rect.width();
            entry.height = rect.height();
            entry.left = offset.x();
            entry.top = offset.y();
            entry.max_left = std::max(0, maximum.x());
            entry.max_top = std::max(0, maximum.y());
            entry.scrolls_x = scrolls_x;
            entry.scrolls_y = scrolls_y;
            found.push_back(entry);
        }
    }
    auto position = view.scrollPosition();
    pthread_mutex_lock(&core.lock);
    auto& shared = core.shared;
    // movement that was sent and not applied yet still counts against the room of a block
    for (auto& command : shared.inner_scrolls) {
        for (auto& entry : found) {
            if (entry.id == command.id) {
                entry.pending_x += command.dx;
                entry.pending_y += command.dy;
            }
        }
    }
    shared.scrollers = WTF::move(found);
    shared.scrollers_scroll_x = position.x();
    shared.scrollers_scroll_y = position.y();
    pthread_mutex_unlock(&core.lock);
}

// the movement the interface sent to blocks of the page, found again by their address among the areas that exist now
static void apply_inner_scrolls(yozora_core& core, LocalFrameView& view)
{
    std::deque<decltype(core.shared.inner_scrolls)::value_type> work;
    pthread_mutex_lock(&core.lock);
    std::swap(work, core.shared.inner_scrolls);
    pthread_mutex_unlock(&core.lock);
    auto* areas = view.scrollableAreas();
    if (!areas)
        return;
    for (auto& command : work) {
        for (auto& area : *areas) {
            if (reinterpret_cast<uint64_t>(&area) != command.id)
                continue;
            auto target = area.scrollOffset() + IntSize(command.dx, command.dy);
            area.scrollToOffsetWithoutAnimation(FloatPoint(target));
            break;
        }
    }
}

// the selection the interface shows handles and a menu for: text and the places of its two ends, read again only when it changed
static void publish_selection(yozora_core& core)
{
    RefPtr frame = core.page->localMainFrame();
    RefPtr view = frame ? frame->view() : nullptr;
    if (!view)
        return;
    auto selection = frame->selection().selection();
    if (!selection.isRange()) {
        if (!core.published_selection)
            return;
        core.published_selection.reset();
        pthread_mutex_lock(&core.lock);
        core.shared.selection = { };
        pthread_mutex_unlock(&core.lock);
        return;
    }
    yozora_selection result { };
    result.active = 1;
    result.scroll_y = view->scrollPosition().y();
    // the caret of an end is taken inside its text, a block end that has no line gives an empty rectangle
    auto start = selection.visibleStart().absoluteCaretBounds();
    auto end = selection.visibleEnd().absoluteCaretBounds();
    result.start_x = start.x();
    result.start_y = start.y();
    result.start_height = start.height();
    result.end_x = end.maxX();
    result.end_y = end.y();
    result.end_height = end.height();
    bool changed = !core.published_selection || !(*core.published_selection == selection);
    if (changed) {
        core.published_selection = selection;
        auto text = frame->editor().selectedText().utf8();
        std::snprintf(result.text, sizeof(result.text), "%s", text.data() ? text.data() : "");
    } else {
        pthread_mutex_lock(&core.lock);
        std::memcpy(result.text, core.shared.selection.text, sizeof(result.text));
        pthread_mutex_unlock(&core.lock);
    }
    pthread_mutex_lock(&core.lock);
    core.shared.selection = result;
    pthread_mutex_unlock(&core.lock);
}

// layout and display-list recording stay on WebCore, raster work never holds this thread
static bool tick_core(yozora_core& core)
{
    auto error = core.raster->error();
    if (!error.empty() && core.state != YOZORA_LOAD_FAILED)
        fail_load(core, error.c_str());
    if (!core.rendering && !core.dirty && !core.media_dirty)
        return false;
    auto began = MonotonicTime::now();
    if (core.rendering) {
        core.rendering = false;
        core.page->updateRendering();
        core.page->finalizeRenderingUpdate({ });
        core.stats.rendering_ms += static_cast<long long>((MonotonicTime::now() - began).milliseconds());
        ++core.stats.rendering_updates;
    }
    RefPtr view = core.page->localMainFrame()->view();
    if (!view || !core.width || !core.height)
        return false;
    auto layout_began = MonotonicTime::now();
    view->updateLayoutAndStyleIfNeededRecursive();
    core.stats.layout_ms += static_cast<long long>((MonotonicTime::now() - layout_began).milliseconds());
    if (view->needsLayout())
        return false;
    publish_scrollers(core, *view);
    yozora_media_publish(core, *view);
    auto scene = yozoraRecordScene(core.graphics_root.get(), *view, core.width, core.height,
        economy_raster.load() ? 1 : core.scale, ++core.scene_generation);
    scene->page_zoom = core.page_zoom_percent;
    scene->scroll_revision = core.applied_scroll_revision;
    bool changed = !core.recorded_scene || core.recorded_scene->scale != scene->scale
        || core.recorded_scene->width != scene->width || core.recorded_scene->height != scene->height
        || core.recorded_scene->page_zoom != scene->page_zoom
        || core.recorded_scene->scroll_y != scene->scroll_y || core.recorded_scene->layers.size() != scene->layers.size();
    if (!changed) {
        for (size_t i = 0; i < scene->layers.size(); ++i) {
            const auto& before = core.recorded_scene->layers[i];
            const auto& after = scene->layers[i];
            bool animations_changed = before.animations.size() != after.animations.size();
            if (!animations_changed) {
                for (size_t j = 0; j < after.animations.size(); ++j)
                    animations_changed = animations_changed || before.animations[j].state.id != after.animations[j].state.id;
            }
            if (before.version != after.version || !Yozora::sameLayerState(before.state, after.state) || animations_changed) {
                changed = true;
                break;
            }
        }
    }
    core.dirty = false;
    if (changed) {
        core.recorded_scene = scene;
        core.raster->submit(WTF::move(scene));
    }
    return changed;
}

static yozora_input_kind compute_input_kind(yozora_core& core);

// the numbers the interface reads, copied once per pass of the core thread
static void publish_state(yozora_core& core)
{
    RefPtr view = core.page->localMainFrame()->view();
    int scroll = view ? view->scrollPosition().y() : 0;
    int minimum = view ? view->minimumScrollPosition().y() : 0;
    int maximum = view ? view->maximumScrollPosition().y() : 0;
    auto kind = compute_input_kind(core);
    auto stats = core.stats;
    core.raster->statistics(stats);
    if (view)
        stats.layouts = view->layoutUpdateCount();
    pthread_mutex_lock(&core.lock);
    auto& shared = core.shared;
    if (shared.loads_requested == shared.loads_started) {
        shared.state = core.state;
        shared.progress = core.progress;
        shared.page_error = core.page_error;
    }
    shared.secure = core.secure;
    shared.can_go_back = core.can_go_back;
    shared.can_go_forward = core.can_go_forward;
    shared.url = core.url.data() ? core.url.data() : "";
    shared.title = core.title.data() ? core.title.data() : "";
    shared.status = core.status;
    shared.input_kind = kind;
    shared.stats = stats;
    // a scroll the interface asked for and the core has not applied yet stays as it is
    if (!shared.scroll_pending)
        shared.scroll_y = scroll;
    shared.scroll_min = minimum;
    shared.scroll_max = maximum;
    shared.page_zoom = core.page_zoom_percent;
    if (core.visit_ready) {
        core.visit_ready = false;
        // the interface drains this every frame, a backlog means it is not running
        if (shared.visits.size() >= 16)
            shared.visits.pop_front();
        shared.visits.push_back(core.visit);
    }
    pthread_mutex_unlock(&core.lock);
}

static void apply_scroll_request(yozora_core& core)
{
    if (RefPtr view = core.page->localMainFrame() ? core.page->localMainFrame()->view() : nullptr)
        apply_inner_scrolls(core, *view);
    pthread_mutex_lock(&core.lock);
    bool pending = core.shared.scroll_pending;
    int target = core.shared.scroll_y;
    uint64_t revision = core.shared.scroll_revision;
    core.shared.scroll_pending = false;
    pthread_mutex_unlock(&core.lock);
    if (!pending)
        return;
    RefPtr view = core.page->localMainFrame()->view();
    if (!view)
        return;
    auto position = view->scrollPosition();
    position.setY(std::clamp(target, view->minimumScrollPosition().y(), view->maximumScrollPosition().y()));
    view->setScrollPosition(position);
    core.applied_scroll_revision = revision;
    core.rendering = true;
}

static bool core_thread_tick()
{
    auto stamp_pass = makeScopeExit([] { last_pass_ms = steady_ms(); });
    // timers, scripts and network callbacks run in the run loop between ticks, their share is the processor
    // time the thread used since the last tick ended
    static long long last_end_ms = 0;
    long long started_ms = YozoraCoreThread::cpuMilliseconds();
    static MonotonicTime last_tick;
    auto tick_time = MonotonicTime::now();
    long long gap_ms = last_tick ? static_cast<long long>((tick_time - last_tick).milliseconds()) : 0;
    last_tick = tick_time;
    // a script may add a window while this pass runs, the vector can move underneath an iterator
    size_t count = live_cores().size();
    bool counted = false;
    for (size_t index = 0; index < count; ++index) {
        auto* core = live_cores()[index];
        if (core->suspended)
            continue;
        if (!counted) {
            counted = true;
            core->stats.events_ms += started_ms - last_end_ms;
            ++core->stats.ticks;
            if (gap_ms > 100)
                ++core->stats.slow_ticks;
            core->stats.longest_tick_gap_ms = std::max(core->stats.longest_tick_gap_ms, gap_ms);
        }
        apply_scroll_request(*core);
        tick_core(*core);
        publish_selection(*core);
        publish_state(*core);
    }
    // bytecode that scripts gathered is written once the pages have been quiet for a moment, one script for each tick
    static MonotonicTime last_busy;
    auto now = MonotonicTime::now();
    bool busy = false;
    for (auto* core : live_cores())
        busy = busy || (!core->suspended && (core->state == YOZORA_LOAD_LOADING || core->rendering || core->raster->pending() || core->dirty));
    if (busy || !last_busy)
        last_busy = now;
    else if ((now - last_busy) >= 1500_ms && YozoraBytecodeCache::pending())
        YozoraBytecodeCache::flush(1);
    last_end_ms = YozoraCoreThread::cpuMilliseconds();
    return busy;
}

extern "C" int yozora_core_tick(yozora_core* core, yozora_frame* frame)
{
    if (!core || !frame)
        return 0;
    return core->raster->takeFrame(*frame);
}

extern "C" yozora_scene* yozora_core_take_scene(yozora_core* core)
{
    return core ? core->raster->takeScene() : nullptr;
}

// how long the core thread has been away from its passes, 0 while the app is in the background or no page exists yet
extern "C" long long yozora_core_stalled_ms(void)
{
    long long last = last_pass_ms.load();
    if (!last || YozoraCoreThread::isPaused())
        return 0;
    return std::max(0LL, steady_ms() - last);
}

// a script that runs without end keeps the core thread, so this is for the interface thread. the request is
// dropped when no script runs, a pending one would end the next script that starts
extern "C" int yozora_stop_scripts(void)
{
    auto* vm = script_vm.load();
    if (!vm || !vm->isEntered())
        return 0;
    vm->notifyNeedTermination();
    return 1;
}

extern "C" void yozora_set_options(const yozora_options* options)
{
    if (!options)
        return;
    pthread_mutex_lock(&options_lock);
    page_options = *options;
    pthread_mutex_unlock(&options_lock);
    bool blocked = options->block_third_party_cookies != 0;
    YozoraCoreThread::post([blocked] {
        YozoraCookies::setThirdPartyBlocked(blocked);
        for (auto* core : live_cores())
            core_apply_options(*core);
    });
}

extern "C" void yozora_set_economy_raster(int enabled)
{
    if (economy_raster.exchange(enabled ? 1 : 0) == (enabled ? 1 : 0))
        return;
    YozoraCoreThread::post([] {
        for (auto* core : live_cores()) {
            core->raster->reset();
            core->recorded_scene.reset();
            core->dirty = true;
        }
    });
}

extern "C" int yozora_core_painting(yozora_core* core)
{
    return core && core->raster->pending();
}

extern "C" void yozora_core_read_stats(yozora_core* core, yozora_core_stats* stats)
{
    if (!stats)
        return;
    *stats = { };
    if (!core)
        return;
    pthread_mutex_lock(&core->lock);
    *stats = core->shared.stats;
    pthread_mutex_unlock(&core->lock);
}

// the move is decided here against the limits the core thread published, so a page that is busy still follows the finger
extern "C" int yozora_core_scroll(yozora_core* core, int delta_y)
{
    if (!core)
        return 0;
    pthread_mutex_lock(&core->lock);
    auto& shared = core->shared;
    int before = shared.scroll_y;
    int target = std::clamp(before + std::clamp(delta_y, -2048, 2048), shared.scroll_min, std::max(shared.scroll_min, shared.scroll_max));
    int moved = target - before;
    uint64_t revision = shared.scroll_revision;
    if (moved) {
        shared.scroll_y = target;
        shared.scroll_pending = true;
        revision = ++shared.scroll_revision;
    }
    pthread_mutex_unlock(&core->lock);
    if (moved) {
        core->raster->scroll(target, revision);
        YozoraCoreThread::wake();
    }
    return moved;
}

extern "C" void yozora_core_read_scroll_state(yozora_core* core, yozora_scroll_state* state)
{
    if (!state)
        return;
    *state = { };
    if (!core)
        return;
    pthread_mutex_lock(&core->lock);
    state->root_y = core->shared.scroll_y;
    for (auto& area : core->shared.scrollers) {
        if (state->count == YOZORA_MAX_SCROLL_AREAS)
            break;
        auto& offset = state->areas[state->count++];
        offset.id = area.id;
        offset.x = area.left + area.pending_x;
        offset.y = area.top + area.pending_y;
    }
    pthread_mutex_unlock(&core->lock);
}

extern "C" int yozora_core_scroll_offset(yozora_core* core, uint64_t id, int* x, int* y)
{
    if (!x || !y)
        return 0;
    *x = *y = 0;
    if (!core || !id)
        return 0;
    pthread_mutex_lock(&core->lock);
    bool found = id == 1;
    if (id == 1)
        *y = core->shared.scroll_y;
    else {
        for (auto& area : core->shared.scrollers) {
            if (area.id == id) {
                *x = area.left + area.pending_x;
                *y = area.top + area.pending_y;
                found = true;
                break;
            }
        }
    }
    pthread_mutex_unlock(&core->lock);
    return found;
}

extern "C" int yozora_core_scroll_inner(yozora_core* core, int x, int y, int dx, int dy, int* rest_dx, int* rest_dy)
{
    int remaining_x = dx, remaining_y = dy;
    bool consumed = false;
    if (core) {
        pthread_mutex_lock(&core->lock);
        auto& shared = core->shared;
        int point_x = x + shared.scrollers_scroll_x;
        int point_y = y + shared.scrollers_scroll_y;
        // the smallest block under the point first, the page gets what the blocks around it cannot take
        std::vector<size_t> order;
        for (size_t i = 0; i < shared.scrollers.size(); ++i) {
            auto& entry = shared.scrollers[i];
            if (point_x >= entry.x && point_x < entry.x + entry.width && point_y >= entry.y && point_y < entry.y + entry.height)
                order.push_back(i);
        }
        std::sort(order.begin(), order.end(), [&](size_t a, size_t b) {
            auto& first = shared.scrollers[a];
            auto& second = shared.scrollers[b];
            return static_cast<long long>(first.width) * first.height < static_cast<long long>(second.width) * second.height;
        });
        auto room = [](int position, int wanted, int maximum) { return std::clamp(position + wanted, 0, maximum) - position; };
        for (size_t index : order) {
            auto& entry = shared.scrollers[index];
            int move_x = entry.scrolls_x && remaining_x ? room(entry.left + entry.pending_x, remaining_x, entry.max_left) : 0;
            int move_y = entry.scrolls_y && remaining_y ? room(entry.top + entry.pending_y, remaining_y, entry.max_top) : 0;
            if (!move_x && !move_y)
                continue;
            entry.pending_x += move_x;
            entry.pending_y += move_y;
            remaining_x -= move_x;
            remaining_y -= move_y;
            // a long drag between two passes of the core thread is one movement, the queue stays short
            if (!shared.inner_scrolls.empty() && shared.inner_scrolls.back().id == entry.id) {
                shared.inner_scrolls.back().dx += move_x;
                shared.inner_scrolls.back().dy += move_y;
            } else if (shared.inner_scrolls.size() < 64)
                shared.inner_scrolls.push_back({ entry.id, move_x, move_y });
            consumed = true;
            if (!remaining_x && !remaining_y)
                break;
        }
        pthread_mutex_unlock(&core->lock);
        if (consumed)
            YozoraCoreThread::wake();
    }
    if (rest_dx)
        *rest_dx = remaining_x;
    if (rest_dy)
        *rest_dy = remaining_y;
    return consumed ? 1 : 0;
}

extern "C" int yozora_core_page_zoom(yozora_core* core)
{
    if (!core)
        return YOZORA_ZOOM_DEFAULT;
    pthread_mutex_lock(&core->lock);
    int result = core->shared.page_zoom;
    pthread_mutex_unlock(&core->lock);
    return result;
}

// the layout is zoomed, not stretched: the page reflows to the narrower width and keeps the row under the fingers where it was
extern "C" void yozora_core_set_page_zoom(yozora_core* core, int percent, int focal_y)
{
    if (!core)
        return;
    percent = yozora_zoom_clamp_fit(percent);
    focal_y = std::clamp(focal_y, 0, 16384);
    YozoraCoreThread::post([core, percent, focal_y] {
        if (core->page_zoom_percent == percent)
            return;
        RefPtr frame = core->page->localMainFrame();
        RefPtr view = frame ? frame->view() : nullptr;
        if (!view)
            return;
        // the scroll the finger asked for last may not have reached the page yet
        pthread_mutex_lock(&core->lock);
        int scroll = core->shared.scroll_y;
        pthread_mutex_unlock(&core->lock);
        int before = core->page_zoom_percent;
        core->page_zoom_percent = percent;
        core_apply_options(*core);
        view->updateLayoutAndStyleIfNeededRecursive();
        int minimum = view->minimumScrollPosition().y();
        int maximum = view->maximumScrollPosition().y();
        int target = yozora_zoom_anchor_scroll(scroll, focal_y, before, percent, minimum, maximum);
        auto position = view->scrollPosition();
        position.setY(target);
        view->setScrollPosition(position);
        pthread_mutex_lock(&core->lock);
        core->shared.scroll_y = target;
        core->shared.scroll_min = minimum;
        core->shared.scroll_max = maximum;
        core->shared.scroll_pending = false;
        core->shared.page_zoom = percent;
        pthread_mutex_unlock(&core->lock);
        core->dirty = true;
        core->rendering = true;
    });
}

// the layout follows the mode at once for the site that is open, the interface reloads the page for the user agent
extern "C" void yozora_core_set_desktop(yozora_core* core, int enabled)
{
    if (!core)
        return;
    bool on = enabled != 0;
    pthread_mutex_lock(&core->lock);
    core->shared.desktop = on;
    pthread_mutex_unlock(&core->lock);
    YozoraCoreThread::post([core, on] {
        if (core->desktop == on)
            return;
        core->desktop = on;
        setYozoraDesktopPage(*core->page, on);
        // what the other mode loaded stays in the process memory cache under its address: resources the page
        // still shows are kept by their owners, the rest is dropped so the next load of this page asks the
        // network
        MemoryCache::singleton().evictResources();
        yozora_core_set_page_zoom(core, desktop_zoom_percent(*core), 0);
    });
}

extern "C" int yozora_core_desktop(yozora_core* core)
{
    if (!core)
        return 0;
    pthread_mutex_lock(&core->lock);
    int result = core->shared.desktop ? 1 : 0;
    pthread_mutex_unlock(&core->lock);
    return result;
}

static void publish_find(yozora_core& core, bool active)
{
    pthread_mutex_lock(&core.lock);
    core.shared.find.active = active ? 1 : 0;
    core.shared.find.count = active ? core.find_count : 0;
    core.shared.find.index = active ? core.find_index : 0;
    pthread_mutex_unlock(&core.lock);
}

static void find_clear_now(yozora_core& core)
{
    core.page->unmarkAllTextMatches();
    if (RefPtr frame = core.page->localMainFrame())
        frame->selection().clear();
    core.find_text = String();
    core.find_count = 0;
    core.find_index = 0;
    publish_find(core, false);
    core.dirty = true;
    core.rendering = true;
}

extern "C" void yozora_core_find(yozora_core* core, const char* text, int direction)
{
    if (!core)
        return;
    auto query = text ? String::fromUTF8(text) : String();
    int step = direction > 0 ? 1 : (direction < 0 ? -1 : 0);
    YozoraCoreThread::post([core, query = WTF::move(query), step]() mutable {
        RefPtr frame = core->page->localMainFrame();
        if (!frame)
            return;
        if (query.isEmpty()) {
            find_clear_now(*core);
            return;
        }
        bool restart = !step || query != core->find_text;
        if (restart) {
            core->page->unmarkAllTextMatches();
            frame->selection().clear();
            core->find_text = query;
            core->find_count = static_cast<int>(core->page->markAllMatchesForText(query, { FindOption::CaseInsensitive }, true, YOZORA_FIND_MAX));
        }
        core->find_index = 0;
        if (core->find_count > 0) {
            // the match is selected and scrolled into view, a next or previous search starts from the selected one and wraps around the page
            FindOptions options { FindOption::CaseInsensitive, FindOption::WrapAround };
            if (step < 0)
                options.add(FindOption::Backwards);
            if (core->page->findString(query, options).range) {
                // the first match after the selection is the one right behind the current match, none means the current match is the last
                auto matches = core->page->findTextMatches(query, { FindOption::CaseInsensitive }, YOZORA_FIND_MAX, false);
                core->find_count = static_cast<int>(matches.ranges.size());
                core->find_index = matches.indexForSelection ? static_cast<int>(*matches.indexForSelection) : core->find_count;
                core->find_index = std::clamp(core->find_index, core->find_count ? 1 : 0, core->find_count);
            }
        }
        publish_find(*core, true);
        core->dirty = true;
        core->rendering = true;
    });
}

extern "C" void yozora_core_find_clear(yozora_core* core)
{
    if (!core)
        return;
    YozoraCoreThread::post([core] { find_clear_now(*core); });
}

extern "C" void yozora_core_find_state(yozora_core* core, yozora_find_state* out)
{
    if (!out)
        return;
    *out = { };
    if (!core)
        return;
    pthread_mutex_lock(&core->lock);
    *out = core->shared.find;
    pthread_mutex_unlock(&core->lock);
}

extern "C" int yozora_core_scroll_y(yozora_core* core)
{
    if (!core)
        return 0;
    pthread_mutex_lock(&core->lock);
    int result = core->shared.scroll_y;
    pthread_mutex_unlock(&core->lock);
    return result;
}

static void send_mouse(LocalFrame& frame, PlatformEvent::Type type, const IntPoint& point)
{
    bool moved = type == PlatformEvent::Type::MouseMoved;
    PlatformMouseEvent event(DoublePoint(point), DoublePoint(point), moved ? MouseButton::None : MouseButton::Left, type, moved ? 0 : 1, { }, MonotonicTime::now(), 0, SyntheticClickType::NoTap, MouseEventInputSource::UserDriven);
    if (type == PlatformEvent::Type::MousePressed)
        frame.eventHandler().handleMousePressEvent(event);
    else if (type == PlatformEvent::Type::MouseReleased)
        frame.eventHandler().handleMouseReleaseEvent(event);
    else
        frame.eventHandler().handleMouseMoveEvent(event);
}

// the point is in the page the interface shows, at the scroll position it asked for last. the two ends of a
// selection are found as a mouse finds them, from a point of the view
static void select_between(yozora_core& core, int from_x, int from_document_y, int to_x, int to_document_y)
{
    RefPtr frame = core.page->localMainFrame();
    if (!frame || !frame->view())
        return;
    int scroll = frame->view()->scrollPosition().y();
    // text the page marks as not selectable is skipped, the position lookup would take the nearest text that can be
    for (auto point : { IntPoint(from_x, from_document_y - scroll), IntPoint(to_x, to_document_y - scroll) }) {
        auto hit = frame->eventHandler().hitTestResultAtPoint(point, { HitTestRequest::Type::ReadOnly, HitTestRequest::Type::AllowChildFrameContent });
        RefPtr node = hit.innerNode();
        CheckedPtr renderer = node ? node->renderer() : nullptr;
        if (!renderer || renderer->style().usedUserSelect() == UserSelect::None)
            return;
    }
    auto from = frame->visiblePositionForPoint(IntPoint(from_x, from_document_y - scroll));
    auto to = frame->visiblePositionForPoint(IntPoint(to_x, to_document_y - scroll));
    if (from.isNull() || to.isNull())
        return;
    VisibleSelection selection(from, to);
    selection.expandUsingGranularity(TextGranularity::WordGranularity);
    if (!selection.isRange())
        return;
    frame->selection().setSelection(selection, FrameSelection::defaultSetSelectionOptions(UserTriggered::Yes));
    core.rendering = true;
}

extern "C" void yozora_core_select_word(yozora_core* core, int x, int y)
{
    if (!core)
        return;
    int document_y = yozora_core_scroll_y(core) + y;
    YozoraCoreThread::post([core, x, document_y] { select_between(*core, x, document_y, x, document_y); });
}

extern "C" void yozora_core_select_range(yozora_core* core, int from_x, int from_y, int to_x, int to_y)
{
    if (!core)
        return;
    int scroll = yozora_core_scroll_y(core);
    YozoraCoreThread::post([core, from_x, from_document = scroll + from_y, to_x, to_document = scroll + to_y] {
        if (core->press_on_target)
            return;
        select_between(*core, from_x, from_document, to_x, to_document);
    });
}

// a hit address the interface may open or copy: web addresses only, a javascript or data address does nothing useful on a sheet
static bool copy_hit_url(const URL& url, char* out, size_t capacity)
{
    if (url.isEmpty() || !url.protocolIsInHTTPFamily())
        return false;
    CString text = url.string().utf8();
    if (text.length() >= capacity)
        return false;
    std::memcpy(out, text.data(), text.length() + 1);
    return true;
}

extern "C" void yozora_core_long_press(yozora_core* core, int x, int y)
{
    if (!core)
        return;
    int document_y = yozora_core_scroll_y(core) + y;
    YozoraCoreThread::post([core, x, y, document_y] {
        RefPtr frame = core->page->localMainFrame();
        if (!frame || !frame->view())
            return;
        auto hit = frame->eventHandler().hitTestResultAtPoint(IntPoint(x, document_y - frame->view()->scrollPosition().y()),
            { HitTestRequest::Type::ReadOnly, HitTestRequest::Type::AllowChildFrameContent });
        auto found = std::make_unique<yozora_hit>();
        std::memset(found.get(), 0, sizeof(*found));
        found->x = x;
        found->y = y;
        bool link = copy_hit_url(hit.absoluteLinkURL(), found->link, sizeof(found->link));
        bool image = copy_hit_url(hit.absoluteImageURL(), found->image, sizeof(found->image));
        bool media = copy_hit_url(hit.absoluteMediaURL(), found->media, sizeof(found->media));
        core->press_on_target = link || image || media;
        core->press_passes_through = false;
        if (!core->press_on_target) {
            // a finger held on words selects the word. on anything else (a challenge checkbox, a button, a
            // block, a frame) it was a slow tap and the release clicks: a position lookup would pick the
            // nearest text and select it, which Safari does not do
            RefPtr node = hit.innerNode();
            bool onText = node && node->isTextNode();
            for (RefPtr ancestor = onText ? node->parentElement() : nullptr; ancestor; ancestor = ancestor->parentElement()) {
                if (is<HTMLFormControlElement>(*ancestor)) {
                    onText = false;
                    break;
                }
            }
            if (onText)
                select_between(*core, x, document_y, x, document_y);
            else
                core->press_passes_through = true;
            return;
        }
        // a selection that was open would stay under the sheet
        frame->selection().clear();
        core->rendering = true;
        if (link) {
            String text = hit.textContent().simplifyWhiteSpace(deprecatedIsSpaceOrNewline);
            std::snprintf(found->link_text, sizeof(found->link_text), "%s", text.left(80).utf8().data());
        }
        pthread_mutex_lock(&core->lock);
        if (core->shared.hits.size() < 4)
            core->shared.hits.push_back(WTF::move(found));
        pthread_mutex_unlock(&core->lock);
    });
}

extern "C" void yozora_core_download(yozora_core* core, const char* url)
{
    if (!core || !url)
        return;
    std::string address(url);
    YozoraCoreThread::post([core, address] {
        RefPtr frame = core->page->localMainFrame();
        URL target { String::fromUTF8(address.c_str()) };
        if (!frame || !target.isValid() || !target.protocolIsInHTTPFamily()) {
            yozora_core_message(*core, "Этот файл не удалось загрузить");
            return;
        }
        // asked the way a click on the link would ask: the page is the referrer and the first party
        ResourceRequest request { URL(target) };
        if (RefPtr document = frame->document()) {
            request.setHTTPReferrer(document->url().string());
            request.setFirstPartyForCookies(document->url());
        }
        request.setHTTPUserAgent(frame->loader().userAgent(target));
        if (YozoraDownloads::start(request, String()))
            yozora_core_message(*core, "Загрузка файла началась");
        else
            yozora_core_message(*core, "Этот файл не удалось загрузить");
    });
}

extern "C" int yozora_core_take_hit(yozora_core* core, yozora_hit* out)
{
    if (!core || !out)
        return 0;
    pthread_mutex_lock(&core->lock);
    bool taken = !core->shared.hits.empty();
    if (taken) {
        *out = *core->shared.hits.front();
        core->shared.hits.pop_front();
    }
    pthread_mutex_unlock(&core->lock);
    return taken ? 1 : 0;
}

extern "C" void yozora_core_select_all(yozora_core* core)
{
    if (!core)
        return;
    YozoraCoreThread::post([core] {
        if (RefPtr frame = core->page->localMainFrame()) {
            frame->selection().selectAll();
            core->rendering = true;
        }
    });
}

yozora_core* yozora_core_for_page(const WebCore::Page* page)
{
    for (auto* core : live_cores()) {
        if (core->page.get() == page)
            return core;
    }
    return nullptr;
}

void yozora_core_ask_credentials(yozora_core& core, const String& host, int port, const String& realm, const String& scheme, bool secure, unsigned failures,
                                 std::function<void(std::optional<std::pair<String, String>>)>&& answer)
{
    yozora_auth_request request { };
    request.id = core.next_auth_id++;
    std::snprintf(request.host, sizeof(request.host), "%s", host.left(250).utf8().data());
    request.port = port;
    std::snprintf(request.realm, sizeof(request.realm), "%s", realm.left(250).utf8().data());
    std::snprintf(request.scheme, sizeof(request.scheme), "%s", scheme.left(15).utf8().data());
    request.secure = secure ? 1 : 0;
    request.failures = static_cast<int>(failures);
    core.auth_waiting[request.id] = WTF::move(answer);
    pthread_mutex_lock(&core.lock);
    core.shared.auth_requests.push_back(request);
    pthread_mutex_unlock(&core.lock);
}

extern "C" int yozora_core_take_auth(yozora_core* core, yozora_auth_request* out)
{
    if (!core || !out)
        return 0;
    pthread_mutex_lock(&core->lock);
    bool taken = !core->shared.auth_requests.empty();
    if (taken) {
        *out = core->shared.auth_requests.front();
        core->shared.auth_requests.pop_front();
    }
    pthread_mutex_unlock(&core->lock);
    return taken ? 1 : 0;
}

extern "C" void yozora_core_auth_respond(yozora_core* core, unsigned id, const char* user, const char* password)
{
    if (!core)
        return;
    std::optional<std::pair<String, String>> credentials;
    if (user)
        credentials = std::make_pair(String::fromUTF8(user), String::fromUTF8(password ? password : ""));
    YozoraCoreThread::post([core, id, credentials = WTF::move(credentials)]() mutable {
        auto found = core->auth_waiting.find(id);
        if (found == core->auth_waiting.end())
            return;
        auto answer = WTF::move(found->second);
        core->auth_waiting.erase(found);
        answer(WTF::move(credentials));
    });
}

extern "C" void yozora_core_select_clear(yozora_core* core)
{
    if (!core)
        return;
    YozoraCoreThread::post([core] {
        if (RefPtr frame = core->page->localMainFrame()) {
            frame->selection().clear();
            core->rendering = true;
        }
    });
}

extern "C" int yozora_core_selection(yozora_core* core, yozora_selection* out)
{
    if (!core || !out)
        return 0;
    pthread_mutex_lock(&core->lock);
    *out = core->shared.selection;
    pthread_mutex_unlock(&core->lock);
    return out->active;
}

// the mouse sequence of a tap at a point of the document, on the core thread
static void click_at(yozora_core& core, int x, int document_y)
{
    RefPtr frame = core.page->localMainFrame();
    if (!frame || !frame->view())
        return;
    IntPoint point(x, document_y - frame->view()->scrollPosition().y());
    // a list with several choices is operated by the sheet of the interface, a tap on it would only replace the choice with one item
    if (yozora_tap_multiple_select(core, *frame, point)) {
        core.rendering = true;
        return;
    }
    send_mouse(*frame, PlatformEvent::Type::MouseMoved, point);
    send_mouse(*frame, PlatformEvent::Type::MousePressed, point);
    send_mouse(*frame, PlatformEvent::Type::MouseReleased, point);
    core.rendering = true;
}

extern "C" void yozora_core_tap(yozora_core* core, int x, int y)
{
    if (!core)
        return;
    int document_y = yozora_core_scroll_y(core) + y;
    YozoraCoreThread::post([core, x, document_y] { click_at(*core, x, document_y); });
}

extern "C" void yozora_core_long_press_release(yozora_core* core, int x, int y)
{
    if (!core)
        return;
    int document_y = yozora_core_scroll_y(core) + y;
    YozoraCoreThread::post([core, x, document_y] {
        if (!core->press_passes_through)
            return;
        core->press_passes_through = false;
        click_at(*core, x, document_y);
    });
}

// one finger as the page sees it, the shape of the synthetic touch of EventHandler that is private to its file
class YozoraTouchPoint final : public PlatformTouchPoint {
public:
    YozoraTouchPoint(State state, const IntPoint& point)
    {
        m_id = 0;
        m_state = state;
        m_screenPos = DoublePoint(point);
        m_pos = DoublePoint(point);
        m_radius = { 1, 1 };
        m_rotationAngle = 0;
        m_twist = 0;
        m_force = 1;
    }
};

class YozoraTouchEvent final : public PlatformTouchEvent {
public:
    YozoraTouchEvent(PlatformEvent::Type type, PlatformTouchPoint::State state, const IntPoint& point)
    {
        m_type = type;
        m_timestamp = MonotonicTime::now();
        m_touchPoints.append(YozoraTouchPoint(state, point));
    }
};

extern "C" void yozora_core_touch(yozora_core* core, int phase, int x, int y)
{
    if (!core || phase < 0 || phase > 3)
        return;
    int document_y = yozora_core_scroll_y(core) + y;
    YozoraCoreThread::post([core, phase, x, document_y] {
        RefPtr frame = core->page->localMainFrame();
        if (!frame || !frame->view())
            return;
        IntPoint point(x, document_y - frame->view()->scrollPosition().y());
        static constexpr PlatformEvent::Type types[] = { PlatformEvent::Type::TouchStart, PlatformEvent::Type::TouchMove, PlatformEvent::Type::TouchEnd, PlatformEvent::Type::TouchCancel };
        static constexpr PlatformTouchPoint::State states[] = { PlatformTouchPoint::TouchPressed, PlatformTouchPoint::TouchMoved, PlatformTouchPoint::TouchReleased, PlatformTouchPoint::TouchCancelled };
        YozoraTouchEvent event(types[phase], states[phase], point);
        // a const result takes the lvalue overloads of WTF::Expected, the rvalue ones of value_or do not compile
        const auto handled = frame->eventHandler().handleTouchEvent(event);
        bool prevented = handled.has_value() && handled.value();
        pthread_mutex_lock(&core->lock);
        // a new gesture starts unclaimed, a claim lasts until the finger leaves
        if (phase == 0)
            core->shared.touch_claimed = false;
        if (prevented && phase < 2)
            core->shared.touch_claimed = true;
        pthread_mutex_unlock(&core->lock);
        core->rendering = true;
    });
}

extern "C" int yozora_core_touch_claimed(yozora_core* core)
{
    if (!core)
        return 0;
    pthread_mutex_lock(&core->lock);
    int claimed = core->shared.touch_claimed ? 1 : 0;
    pthread_mutex_unlock(&core->lock);
    return claimed;
}

// the caret of a field is placed by a timer after focus, so the focused element is what tells whether the keyboard is wanted
static yozora_input_kind compute_input_kind(yozora_core& core)
{
    RefPtr frame = core.page->focusController().focusedOrMainFrame();
    RefPtr document = frame ? frame->document() : nullptr;
    RefPtr element = document ? document->focusedElement() : nullptr;
    if (!element)
        return YOZORA_INPUT_NONE;
    if (RefPtr input = dynamicDowncast<HTMLInputElement>(element.get())) {
        if (!input->isTextField() || input->isReadOnly() || input->isDisabledFormControl())
            return YOZORA_INPUT_NONE;
        if (input->isPasswordField())
            return YOZORA_INPUT_PASSWORD;
        if (input->isEmailField())
            return YOZORA_INPUT_EMAIL;
        if (input->isURLField())
            return YOZORA_INPUT_URL;
        if (input->isNumberField())
            return YOZORA_INPUT_NUMBER;
        if (input->isSearchField())
            return YOZORA_INPUT_SEARCH;
        return YOZORA_INPUT_TEXT;
    }
    if (RefPtr area = dynamicDowncast<HTMLTextAreaElement>(element.get()))
        return area->isReadOnly() || area->isDisabledFormControl() ? YOZORA_INPUT_NONE : YOZORA_INPUT_MULTILINE;
    return element->isRootEditableElement() ? YOZORA_INPUT_MULTILINE : YOZORA_INPUT_NONE;
}

extern "C" yozora_input_kind yozora_core_input_kind(yozora_core* core)
{
    if (!core)
        return YOZORA_INPUT_NONE;
    pthread_mutex_lock(&core->lock);
    auto kind = core->shared.input_kind;
    pthread_mutex_unlock(&core->lock);
    return kind;
}

static void send_key(LocalFrame& frame, PlatformEvent::Type type, const String& text, const String& key, const yozora_key& info)
{
    OptionSet<PlatformEvent::Modifier> modifiers;
    if (info.shift)
        modifiers.add(PlatformEvent::Modifier::ShiftKey);
    // pages read code and the identifier too: widgets that act on the space or return key test them, not only the text
    PlatformKeyboardEvent event(type, text, text, key, String::fromLatin1(info.code), String::fromLatin1(info.identifier), info.windows_code, false, false, false, modifiers, MonotonicTime::now());
    frame.eventHandler().keyEvent(event);
}

// the keypress default action, which inserts the text or submits the form, is in the editor client
static void type_character(LocalFrame& frame, char32_t character)
{
    bool enter = character == '\n';
    StringBuilder builder;
    builder.append(enter ? U'\r' : character);
    String text = builder.toString();
    String key = enter ? "Enter"_s : text;
    yozora_key info;
    yozora_key_for_character(character, &info);
    // the key goes down without text and the character follows as its own event, as the platforms of WebKit send them
    send_key(frame, PlatformEvent::Type::RawKeyDown, String(), key, info);
    yozora_key typed = info;
    typed.windows_code = 0;
    send_key(frame, PlatformEvent::Type::Char, text, key, typed);
    send_key(frame, PlatformEvent::Type::KeyUp, String(), key, info);
}


extern "C" int yozora_core_insert_text(yozora_core* core, const char* text)
{
    if (!core || !text || yozora_core_input_kind(core) == YOZORA_INPUT_NONE)
        return 0;
    std::string copy(text);
    YozoraCoreThread::post([core, copy] {
        if (compute_input_kind(*core) == YOZORA_INPUT_NONE)
            return;
        RefPtr frame = core->page->focusController().focusedOrMainFrame();
        for (auto character : StringView(String::fromUTF8(copy.c_str())).codePoints())
            type_character(*frame, character);
        core->rendering = true;
    });
    return 1;
}

extern "C" int yozora_core_delete_backward(yozora_core* core)
{
    if (!core || yozora_core_input_kind(core) == YOZORA_INPUT_NONE)
        return 0;
    YozoraCoreThread::post([core] {
        if (compute_input_kind(*core) == YOZORA_INPUT_NONE)
            return;
        RefPtr frame = core->page->focusController().focusedOrMainFrame();
        yozora_key info;
        yozora_key_for_backspace(&info);
        send_key(*frame, PlatformEvent::Type::RawKeyDown, String(), "Backspace"_s, info);
        send_key(*frame, PlatformEvent::Type::KeyUp, String(), "Backspace"_s, info);
        core->rendering = true;
    });
    return 1;
}

// an input method composes text before it is final: Japanese kana become kanji when the person picks a candidate. the editor keeps
// the composed text in the field as an underlined run, and replaces it with the final text when the composition is confirmed
extern "C" int yozora_core_set_composition(yozora_core* core, const char* text, int caret_start, int caret_end)
{
    if (!core || !text || yozora_core_input_kind(core) == YOZORA_INPUT_NONE)
        return 0;
    std::string copy(text);
    unsigned start = caret_start < 0 ? 0 : static_cast<unsigned>(caret_start);
    unsigned end = caret_end < caret_start ? start : static_cast<unsigned>(caret_end);
    YozoraCoreThread::post([core, copy, start, end] {
        if (compute_input_kind(*core) == YOZORA_INPUT_NONE)
            return;
        RefPtr frame = core->page->focusController().focusedOrMainFrame();
        String composed = String::fromUTF8(copy.c_str());
        if (composed.isEmpty()) {
            frame->editor().cancelComposition();
        } else {
            Vector<CompositionUnderline> underlines;
            underlines.append(CompositionUnderline(0, composed.length(), CompositionUnderlineColor::TextColor, Color::black, false));
            unsigned length = composed.length();
            Vector<CompositionHighlight> highlights;
            HashMap<String, Vector<CharacterRange>> annotations;
            frame->editor().setComposition(composed, underlines, highlights, annotations, std::min(start, length), std::min(end, length));
        }
        core->rendering = true;
    });
    return 1;
}

extern "C" int yozora_core_confirm_composition(yozora_core* core, const char* text)
{
    if (!core || yozora_core_input_kind(core) == YOZORA_INPUT_NONE)
        return 0;
    bool replace = text != nullptr;
    std::string copy(text ? text : "");
    YozoraCoreThread::post([core, copy, replace] {
        if (compute_input_kind(*core) == YOZORA_INPUT_NONE)
            return;
        RefPtr frame = core->page->focusController().focusedOrMainFrame();
        if (replace)
            frame->editor().confirmComposition(String::fromUTF8(copy.c_str()));
        else
            frame->editor().confirmComposition();
        core->rendering = true;
    });
    return 1;
}

extern "C" void yozora_core_reveal_input(yozora_core* core)
{
    if (!core)
        return;
    YozoraCoreThread::post([core] {
        if (RefPtr frame = core->page->focusController().focusedOrMainFrame())
            frame->selection().revealSelection();
    });
}

// a first warning gives back what the page on screen does not need: tiles the last pass did not touch and the
// WebCore caches. tiles, scene and recordings of the page stay so it is not blank while painted again, which
// takes seconds on a heavy page. a second warning close behind means the memory did not come back, then
// everything goes
static void release_memory_on_core(bool everything)
{
    if (live_cores().isEmpty())
        return;
    for (auto* core : live_cores()) {
        if (everything) {
            core->raster->reset();
            core->recorded_scene.reset();
            yozoraPurgeScene(core->graphics_root.get());
            core->dirty = true;
        } else
            core->raster->trimUnused();
    }
    // pending bytecode is handed to its writer before the collection drops its providers
    YozoraBytecodeCache::flush(0);
    // synchronous critical release already performs a full script collection
    releaseMemory(Critical::Yes, Synchronous::Yes);
    SkGraphics::PurgeAllCaches();
}

extern "C" void yozora_core_release_memory(yozora_core* core)
{
    if (core)
        YozoraCoreThread::call([] { release_memory_on_core(true); });
}

extern "C" void yozora_release_memory_async(void)
{
    static std::atomic<bool> pending { false };
    if (pending.exchange(true))
        return;
    // a busy script must not hold UIKit inside its memory warning handler
    static std::atomic<long long> last_release { 0 };
    long long now = steady_ms();
    bool everything = last_release.load() && now - last_release.load() < 15000;
    last_release = now;
    YozoraCoreThread::post([everything] {
        release_memory_on_core(everything);
        pending = false;
        std::fprintf(stderr, everything ? "yozora: memory pressure, everything released\n" : "yozora: memory pressure, unused tiles and caches released\n");
    });
}

// the thread stops running pages while the app is in the background, queued work such as a teardown still
// runs. the pages were hidden for a quiet run so the next foreground shows them again
static std::atomic<bool> pages_hidden_for_quiet { false };

extern "C" void yozora_set_background_downloads(int enabled)
{
    if (!enabled) {
        YozoraCoreThread::setPaused(true);
        return;
    }
    pages_hidden_for_quiet = true;
    YozoraCoreThread::setQuiet(true);
    YozoraCoreThread::setPaused(false);
    YozoraCoreThread::post([] {
        for (auto* core : live_cores()) {
            if (core->suspended)
                continue;
            core->page->setIsVisible(false);
            core->page->setIsInWindow(false);
        }
    });
}

extern "C" void yozora_set_background(int background)
{
    // the thread makes no passes in the background, so on return the last pass is as old as the absence and
    // the interface thread would ask "page does not respond" before the first pass of the resumed thread. the
    // clock starts again from the return
    if (!background && last_pass_ms.load())
        last_pass_ms = steady_ms();
    if (!background) {
        YozoraCoreThread::setQuiet(false);
        if (pages_hidden_for_quiet.exchange(false)) {
            YozoraCoreThread::post([] {
                for (auto* core : live_cores()) {
                    if (core->suspended)
                        continue;
                    core->page->setIsInWindow(true);
                    core->page->setIsVisible(true);
                    core->dirty = true;
                    core->rendering = true;
                }
            });
        }
    }
    YozoraCoreThread::setPaused(background != 0);
}

extern "C" int yozora_set_site_data(const char* directory, char* error, size_t capacity)
{
    if (!error || !capacity)
        return 0;
    error[0] = 0;
    if (!directory || !*directory || access(directory, W_OK) != 0) {
        std::snprintf(error, capacity, "directory is not writable");
        return 0;
    }
    std::string base(directory);
    YozoraCookies::setStorePath(base + "/cookies.db");
    YozoraStorage::setFile((base + "/local-storage.txt").c_str());
    YozoraIDB::setDirectory(String::fromUTF8((base + "/IndexedDB").c_str()));
    YozoraSites::setFile(YOZORA_SITE_NOTIFICATIONS, base + "/notifications.txt");
    YozoraSites::setFile(YOZORA_SITE_GEOLOCATION, base + "/geolocation.txt");
    YozoraSites::setFile(YOZORA_SITE_ADBLOCK_PAUSED, base + "/adblock-sites.txt");
    return 1;
}

extern "C" void yozora_flush_site_data(void)
{
    YozoraCoreThread::call([] { YozoraStorage::flush(); });
}

extern "C" void yozora_clear_site_data(void)
{
    YozoraCoreThread::call([] {
        YozoraCookies::clear();
        YozoraStorage::clear();
        YozoraIDB::clear();
        YozoraCacheStorage::clear();
        clearYozoraCredentials();
    });
}

extern "C" int yozora_cookie_header(const char* url, char* out, size_t capacity)
{
    if (!out || !capacity)
        return -1;
    out[0] = 0;
    if (!url)
        return 0;
    CString header;
    YozoraCoreThread::call([&] { header = YozoraCookies::headerForURL(URL { String::fromUTF8(url) }).utf8(); });
    if (header.length() >= capacity)
        return -1;
    std::memcpy(out, header.data(), header.length() + 1);
    return static_cast<int>(header.length());
}

extern "C" void yozora_set_private_session(int enabled)
{
    YozoraPrivateSession::set(enabled != 0);
    YozoraBytecodeCache::setPrivate(enabled != 0);
}

extern "C" int yozora_private_session(void)
{
    return YozoraPrivateSession::active() ? 1 : 0;
}

extern "C" void yozora_clear_private_session(void)
{
    YozoraCoreThread::call([] {
        YozoraCookies::clearPrivate();
        YozoraStorage::clearPrivate();
        YozoraIDB::clearPrivate();
        YozoraCacheStorage::clearPrivate();
    });
}

extern "C" int yozora_set_http_cache(const char* directory, size_t max_bytes, char* error, size_t capacity)
{
    if (!error || !capacity)
        return 0;
    error[0] = 0;
    if (!directory)
        return 0;
    return YozoraHttpCache::open(directory, max_bytes, error, capacity) ? 1 : 0;
}

extern "C" int yozora_set_bytecode_cache(const char* directory, size_t max_bytes, char* error, size_t capacity)
{
    if (!error || !capacity)
        return 0;
    error[0] = 0;
    struct stat info;
    if (!directory || !*directory || lstat(directory, &info) || !S_ISDIR(info.st_mode) || info.st_uid != geteuid() || (info.st_mode & 077)) {
        std::snprintf(error, capacity, "directory must be private to the user");
        return 0;
    }
    if (!bytecode_cache_directory().empty()) {
        std::snprintf(error, capacity, "bytecode cache is already set");
        return 0;
    }
    bytecode_cache_directory() = directory;
    bytecode_cache_limit() = max_bytes;
    return 1;
}

extern "C" void yozora_clear_bytecode_cache(void)
{
    YozoraCoreThread::call([] { YozoraBytecodeCache::clear(); });
}

extern "C" void yozora_flush_bytecode_cache(void)
{
    YozoraCoreThread::call([] { YozoraBytecodeCache::flush(0); });
    YozoraBytecodeCache::waitForWrites();
}

extern "C" void yozora_bytecode_cache_statistics(unsigned long long* loaded, unsigned long long* stale, unsigned long long* stored, unsigned long long* bytes)
{
    auto statistics = YozoraBytecodeCache::statistics();
    if (loaded)
        *loaded = statistics.loaded;
    if (stale)
        *stale = statistics.stale;
    if (stored)
        *stored = statistics.stored;
    if (bytes)
        *bytes = statistics.bytes;
}

extern "C" void yozora_clear_http_cache(void) { YozoraHttpCache::clear(); }
extern "C" void yozora_flush_http_cache(void) { YozoraHttpCache::flush(); }


// the string getters hand out a copy the interface thread owns, valid until the next call of the same getter
extern "C" const char* yozora_core_status(yozora_core* core)
{
    if (!core)
        return "";
    pthread_mutex_lock(&core->lock);
    core->ui_status = core->shared.status;
    pthread_mutex_unlock(&core->lock);
    return core->ui_status.c_str();
}

extern "C" const char* yozora_core_url(yozora_core* core)
{
    if (!core)
        return "";
    pthread_mutex_lock(&core->lock);
    core->ui_url = core->shared.url;
    pthread_mutex_unlock(&core->lock);
    return core->ui_url.c_str();
}

extern "C" const char* yozora_core_title(yozora_core* core)
{
    if (!core)
        return "";
    pthread_mutex_lock(&core->lock);
    core->ui_title = core->shared.title;
    pthread_mutex_unlock(&core->lock);
    return core->ui_title.c_str();
}

#define YOZORA_SHARED_GETTER(type, name, expression, fallback) \
    extern "C" type name(yozora_core* core) \
    { \
        if (!core) \
            return fallback; \
        pthread_mutex_lock(&core->lock); \
        type result = expression; \
        pthread_mutex_unlock(&core->lock); \
        return result; \
    }

YOZORA_SHARED_GETTER(int, yozora_core_can_go_back, core->shared.can_go_back, 0)
YOZORA_SHARED_GETTER(int, yozora_core_can_go_forward, core->shared.can_go_forward, 0)
YOZORA_SHARED_GETTER(float, yozora_core_progress, core->shared.progress, 0)
YOZORA_SHARED_GETTER(int, yozora_core_is_secure, core->shared.secure, 0)
YOZORA_SHARED_GETTER(yozora_load_state, yozora_core_state, core->shared.state, YOZORA_LOAD_FAILED)
YOZORA_SHARED_GETTER(yozora_page_error, yozora_core_page_error, core->shared.page_error, YOZORA_PAGE_ERROR_OTHER)

void yozora_core_console(yozora_core& core, const std::string& line)
{
    pthread_mutex_lock(&core.lock);
    if (core.shared.console.size() >= 200)
        core.shared.console.pop_front();
    core.shared.console.push_back(line.size() > 400 ? line.substr(0, 400) : line);
    pthread_mutex_unlock(&core.lock);
}

extern "C" int yozora_core_take_console(yozora_core* core, char* line, size_t capacity)
{
    if (!core || !line || !capacity)
        return 0;
    pthread_mutex_lock(&core->lock);
    bool found = !core->shared.console.empty();
    if (found) {
        std::snprintf(line, capacity, "%s", core->shared.console.front().c_str());
        core->shared.console.pop_front();
    }
    pthread_mutex_unlock(&core->lock);
    return found ? 1 : 0;
}

extern "C" int yozora_core_take_visit(yozora_core* core, yozora_record* visit)
{
    if (!core || !visit)
        return 0;
    pthread_mutex_lock(&core->lock);
    bool found = !core->shared.visits.empty();
    if (found) {
        *visit = core->shared.visits.front();
        core->shared.visits.pop_front();
    }
    pthread_mutex_unlock(&core->lock);
    return found ? 1 : 0;
}
