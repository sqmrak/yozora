function(yozora_add_core)
    get_filename_component(yozora_root "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/.." ABSOLUTE)
    add_library(YozoraCore STATIC
        "${yozora_root}/core/core/yozora_core.cpp"
        "${yozora_root}/core/core/YozoraCoreThread.cpp"
        "${yozora_root}/core/core/YozoraRaster.cpp"
        "${yozora_root}/core/core/yozora_scene_animation.c"
        "${yozora_root}/core/core/YozoraPageClient.cpp"
        "${yozora_root}/core/core/YozoraLoaderStrategy.cpp"
        "${yozora_root}/core/core/YozoraHttpCache.cpp"
        "${yozora_root}/core/core/YozoraCookies.cpp"
        "${yozora_root}/core/core/YozoraStorage.cpp"
        "${yozora_root}/core/core/YozoraMedia.cpp"
        "${yozora_root}/core/core/YozoraMediaSource.cpp"
        "${yozora_root}/core/core/YozoraWebSocketChannel.cpp"
        "${yozora_root}/core/core/YozoraDownloads.cpp"
        "${yozora_root}/core/core/YozoraIDB.cpp"
        "${yozora_root}/core/core/YozoraCacheStorage.cpp"
        "${yozora_root}/core/core/YozoraControls.cpp"
        "${yozora_root}/core/core/YozoraGeolocation.cpp"
        "${yozora_root}/core/core/YozoraNotifications.cpp"
        "${yozora_root}/core/core/YozoraSites.cpp"
        "${yozora_root}/core/core/YozoraAdblock.cpp"
        "${yozora_root}/core/core/YozoraTranslate.cpp"
        "${yozora_root}/core/yozora_types.c"
        "${yozora_root}/core/yozora_navigation.c"
        "${yozora_root}/core/yozora_store.c"
        "${yozora_root}/core/yozora_address.c"
        "${yozora_root}/core/yozora_dns.c"
        "${yozora_root}/core/yozora_signin.c"
        "${yozora_root}/core/yozora_icon_environment.c"
        "${yozora_root}/core/yozora_accent.c"
        "${yozora_root}/core/yozora_playlist.c"
        "${yozora_root}/core/yozora_icons.c"
        "${yozora_root}/core/yozora_mp4.c"
        "${yozora_root}/core/yozora_ts.c"
        "${yozora_root}/core/yozora_hls.c"
        "${yozora_root}/core/yozora_release.c"
        "${yozora_root}/core/yozora_log.c"
        "${yozora_root}/core/yozora_stream_proxy.c"
        "${yozora_root}/core/yozora_blocklist.c"
        "${yozora_root}/core/yozora_filter.c"
        "${yozora_root}/core/yozora_sitegrants.c"
        "${yozora_root}/core/yozora_budget.c"
        "${yozora_root}/core/yozora_httpcache.c"
        "${yozora_root}/core/yozora_keys.c"
        "${yozora_root}/core/yozora_motion.c"
        "${yozora_root}/core/yozora_zoom.c" "${yozora_root}/core/yozora_debug.c" "${yozora_root}/core/yozora_translate.c" "${yozora_root}/core/yozora_transfer.c" "${yozora_root}/core/yozora_color.c" "${yozora_root}/core/yozora_render_plan.c" "${yozora_root}/core/yozora_signin.c")
    if (CMAKE_SYSTEM_NAME STREQUAL "iOS" AND CMAKE_OSX_ARCHITECTURES STREQUAL "arm64")
        target_sources(YozoraCore PRIVATE "${yozora_root}/core/core/YozoraMetal.mm")
        target_include_directories(YozoraCore PRIVATE "${CMAKE_SOURCE_DIR}/Source/ThirdParty/skia")
        set_source_files_properties("${yozora_root}/core/core/YozoraMetal.mm" PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
        target_link_libraries(YozoraCore PUBLIC "-weak_framework Metal" "-weak_framework IOSurface")
    endif ()
    # glibc 2.43 declares memchr and strchr with _Generic, which -pedantic reports in C99 mode on the host
    set_source_files_properties("${yozora_root}/core/yozora_types.c" "${yozora_root}/core/yozora_navigation.c"
        "${yozora_root}/core/yozora_store.c" "${yozora_root}/core/yozora_address.c" "${yozora_root}/core/yozora_dns.c" "${yozora_root}/core/yozora_accent.c" "${yozora_root}/core/yozora_playlist.c" "${yozora_root}/core/yozora_icons.c" "${yozora_root}/core/yozora_mp4.c" "${yozora_root}/core/yozora_ts.c" "${yozora_root}/core/yozora_hls.c" "${yozora_root}/core/yozora_release.c" "${yozora_root}/core/yozora_log.c" "${yozora_root}/core/yozora_stream_proxy.c" "${yozora_root}/core/yozora_blocklist.c" "${yozora_root}/core/yozora_filter.c" "${yozora_root}/core/yozora_sitegrants.c" "${yozora_root}/core/yozora_budget.c" "${yozora_root}/core/yozora_httpcache.c" "${yozora_root}/core/yozora_keys.c" "${yozora_root}/core/yozora_motion.c" "${yozora_root}/core/yozora_zoom.c" "${yozora_root}/core/yozora_debug.c" "${yozora_root}/core/yozora_translate.c" "${yozora_root}/core/yozora_transfer.c" "${yozora_root}/core/yozora_color.c" "${yozora_root}/core/yozora_render_plan.c" "${yozora_root}/core/yozora_signin.c" "${yozora_root}/core/yozora_icon_environment.c" PROPERTIES COMPILE_OPTIONS "-std=c99;-Wall;-Wextra;-Werror;-pedantic;-Wno-c11-extensions")
    if (NOT ENABLE_WEBASSEMBLY)
        # JavaScriptCore has no WebAssembly on armv7 (nor in the host trees), core/wasm answers for it and
        # core/core/yozora_wasm_api.js is the page api. the arm64 slice built with YOZORA_WASM=ON keeps the
        # one of JavaScriptCore
        target_sources(YozoraCore PRIVATE
            "${yozora_root}/core/core/YozoraWasm.cpp"
            "${yozora_root}/core/wasm/yozora_wasm_module.c"
            "${yozora_root}/core/wasm/yozora_wasm_run.c")
        set_source_files_properties("${yozora_root}/core/wasm/yozora_wasm_module.c" "${yozora_root}/core/wasm/yozora_wasm_run.c"
            PROPERTIES COMPILE_OPTIONS "-std=c99;-Wall;-Wextra;-Werror;-pedantic;-Wno-c11-extensions")
        file(READ "${yozora_root}/core/core/yozora_wasm_api.js" yozora_wasm_api_js)
        file(WRITE "${CMAKE_BINARY_DIR}/yozora_wasm_api_script.inc" "R\"YZJS(${yozora_wasm_api_js})YZJS\"")
        set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${yozora_root}/core/core/yozora_wasm_api.js")
        set(yozora_wasm_engine ON)
    endif ()
    # the translation library is a javascript file, read at configure time into a raw string literal that YozoraTranslate.cpp includes
    file(READ "${yozora_root}/core/core/yozora_translate.js" yozora_translate_js)
    file(WRITE "${CMAKE_BINARY_DIR}/yozora_translate_script.inc" "R\"YZJS(${yozora_translate_js})YZJS\"")
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${yozora_root}/core/core/yozora_translate.js")
    get_target_property(yozora_includes WebCore INCLUDE_DIRECTORIES)
    target_include_directories(YozoraCore PRIVATE ${yozora_includes}
        "${CMAKE_BINARY_DIR}" "${YOZORA_WEBCORE_ROOT}"
        "${JavaScriptCore_FRAMEWORK_HEADERS_DIR}" "${JavaScriptCore_PRIVATE_FRAMEWORK_HEADERS_DIR}"
        "${WebCore_PRIVATE_FRAMEWORK_HEADERS_DIR}"
        "${Skia_FRAMEWORK_HEADERS_DIR}/top" "${Skia_FRAMEWORK_HEADERS_DIR}/mod")
    target_include_directories(YozoraCore PUBLIC "${yozora_root}/core/core" "${yozora_root}/core")
    if (yozora_wasm_engine)
        target_include_directories(YozoraCore PRIVATE "${yozora_root}/core/wasm")
        target_compile_definitions(YozoraCore PRIVATE YOZORA_WASM_ENGINE=1)
    endif ()
    target_link_libraries(YozoraCore PUBLIC SQLite3::SQLite3)
    set(YozoraCore_FRAMEWORKS WebCore JavaScriptCore PAL WTF bmalloc)
    _WEBKIT_TARGET_LINK_FRAMEWORK(YozoraCore)
    target_link_libraries(YozoraCore PUBLIC ${YozoraCore_PRIVATE_LIBRARIES})
    if (APPLE AND ENABLE_WEB_AUDIO)
        # AudioOutputDarwin.cpp plays through an AudioQueue and AudioDecodeDarwin.cpp reads files with
        # ExtAudioFile, every executable that links the core needs them
        target_link_libraries(YozoraCore PUBLIC "-framework AudioToolbox")
    endif ()
    add_executable(yozora-render "${yozora_root}/tools/yozora_render.cpp")
    target_link_libraries(yozora-render PRIVATE YozoraCore Skia::Skia)
    target_include_directories(yozora-render SYSTEM PRIVATE "${Skia_FRAMEWORK_HEADERS_DIR}/top" "${Skia_FRAMEWORK_HEADERS_DIR}/mod")
    if (NOT APPLE)
        add_executable(yozora-lazy-scene-tests "${yozora_root}/tests/test_lazy_scene.cpp")
        target_link_libraries(yozora-lazy-scene-tests PRIVATE YozoraCore)
        add_executable(yozora-scene-tests "${yozora_root}/tests/test_scene_raster.cpp")
        target_link_libraries(yozora-scene-tests PRIVATE YozoraCore Skia::Skia)
        target_include_directories(yozora-scene-tests PRIVATE "${YOZORA_WEBCORE_ROOT}"
            "${Skia_FRAMEWORK_HEADERS_DIR}/top" "${Skia_FRAMEWORK_HEADERS_DIR}/mod")
        target_compile_options(yozora-scene-tests PRIVATE -UNDEBUG)
        add_executable(yozora-scroll-tests "${yozora_root}/tests/test_core_scroll.cpp")
        target_link_libraries(yozora-scroll-tests PRIVATE YozoraCore)
        target_include_directories(yozora-scroll-tests PRIVATE ${yozora_includes}
            "${CMAKE_BINARY_DIR}" "${YOZORA_WEBCORE_ROOT}")
        target_compile_options(yozora-scroll-tests PRIVATE -UNDEBUG)
        add_executable(yozora-memory-tests "${yozora_root}/tests/test_core_memory.cpp")
        target_link_libraries(yozora-memory-tests PRIVATE YozoraCore)
        target_include_directories(yozora-memory-tests PRIVATE ${yozora_includes}
            "${CMAKE_BINARY_DIR}" "${YOZORA_WEBCORE_ROOT}")
        target_compile_options(yozora-memory-tests PRIVATE -UNDEBUG)
    endif ()
    if (APPLE)
        target_link_options(yozora-render PRIVATE "LINKER:-dead_strip")
        add_executable(Yozora
            "${yozora_root}/app/app_main.m"
            "${yozora_root}/app/YZBrowserController.m"
            "${yozora_root}/app/YZPageView.m"
            "${yozora_root}/app/YZSceneView.m"
            "${yozora_root}/app/YZTheme.m"
            "${yozora_root}/app/YZMotion.m"
            "${yozora_root}/app/YZSystemSheet.m"
            "${yozora_root}/app/YZControls.m"
            "${yozora_root}/app/YZFavicons.m"
            "${yozora_root}/app/YZStore.m"
            "${yozora_root}/app/YZTab.m"
            "${yozora_root}/app/YZHomeView.m"
            "${yozora_root}/app/YZErrorPage.m"
            "${yozora_root}/app/YZTabsView.m"
            "${yozora_root}/app/YZTabPager.m"
            "${yozora_root}/app/YZTabStack.m"
            "${yozora_root}/app/YZMenuView.m"
            "${yozora_root}/app/YZListController.m"
            "${yozora_root}/app/YZDownloadsController.m"
            "${yozora_root}/app/YZSettings.m"
            "${yozora_root}/app/YZSettingsController.m"
            "${yozora_root}/app/YZStrings.m"
            "${yozora_root}/app/YZLocation.m"
            "${yozora_root}/app/YZVideoController.m"
            "${yozora_root}/app/YZAccentEditor.m"
            "${yozora_root}/app/YZTintPicker.m"
            "${yozora_root}/app/YZMascotPreview.m"
            "${yozora_root}/app/YZWaveSeekBar.m"
            "${yozora_root}/app/YZPlayerViews.m"
            "${yozora_root}/app/YZStreamProxy.m"
            "${yozora_root}/app/YZUpdate.m"
            "${yozora_root}/app/YZUpdateUI.m"
            "${yozora_root}/app/YZMediaPlayer.m"
            "${yozora_root}/app/YZFindBar.m"
            "${yozora_root}/app/YZSheets.m"
            "${yozora_root}/app/YZDialog.m"
            "${yozora_root}/app/YZErrorPopup.m"
            "${yozora_root}/app/YZShape.m"
            "${yozora_root}/app/YZLog.m"
            "${yozora_root}/app/YZCrash.m"
            "${yozora_root}/app/YZLogController.m"
            "${yozora_root}/app/YZSystemNotifier.m"
            "${yozora_root}/app/YZSitesController.m"
            "${yozora_root}/app/YZCertificates.m"
            "${yozora_root}/app/YZCertificatesController.m"
            "${yozora_root}/app/YZAdblockController.m"
            "${yozora_root}/app/YZDebugOverlay.m"
            "${yozora_root}/app/YZTranslation.m"
            "${yozora_root}/app/YZTranslateBar.m"
            "${yozora_root}/app/YZTranslateSheet.m"
            "${yozora_root}/app/YZColorPicker.m"
            "${yozora_root}/app/YZSplashController.m"
            "${yozora_root}/app/YZTabStrip.m")
        target_compile_options(Yozora PRIVATE -fno-objc-arc -Wall -Wextra -Werror)
        target_link_libraries(Yozora PRIVATE YozoraCore "-framework UIKit" "-framework QuartzCore" "-framework AVFoundation" "-framework CoreMedia" "-framework CoreGraphics" "-framework Foundation" "-framework CoreLocation" "-lobjc")
        target_link_options(Yozora PRIVATE "LINKER:-dead_strip")
        add_executable(yozora-ui-tests
            "${yozora_root}/tests/test_tabs_view.m"
            "${yozora_root}/app/YZHomeView.m"
            "${yozora_root}/app/YZErrorPage.m"
            "${yozora_root}/app/YZStore.m"
            "${yozora_root}/app/YZTabsView.m"
            "${yozora_root}/app/YZTabPager.m"
            "${yozora_root}/app/YZTabStack.m"
            "${yozora_root}/app/YZTab.m"
            "${yozora_root}/app/YZTheme.m"
            "${yozora_root}/app/YZMotion.m"
            "${yozora_root}/app/YZSystemSheet.m"
            "${yozora_root}/app/YZControls.m"
            "${yozora_root}/app/YZFavicons.m"
            "${yozora_root}/app/YZSettings.m"
            "${yozora_root}/app/YZStrings.m")
        target_include_directories(yozora-ui-tests PRIVATE "${yozora_root}/app")
        target_compile_options(yozora-ui-tests PRIVATE -fno-objc-arc -Wall -Wextra -Werror -UNDEBUG)
        target_link_libraries(yozora-ui-tests PRIVATE YozoraCore "-framework UIKit" "-framework QuartzCore"
            "-framework Foundation" "-framework CoreGraphics" "-framework AVFoundation" "-framework CoreMedia" "-lobjc")
        target_link_options(yozora-ui-tests PRIVATE "LINKER:-dead_strip")
    else ()
        target_link_options(yozora-render PRIVATE "LINKER:--gc-sections")
    endif ()
endfunction()
cmake_language(DEFER CALL yozora_add_core)
