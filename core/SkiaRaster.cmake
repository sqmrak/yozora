get_target_property(raster_sources Skia SOURCES)
if (CMAKE_SYSTEM_NAME STREQUAL "iOS" AND CMAKE_OSX_ARCHITECTURES STREQUAL "arm64")
    enable_language(OBJCXX)
    list(FILTER raster_sources EXCLUDE REGEX "^src/gpu/ganesh/gl/")
    set(metal_sources
        src/gpu/ganesh/mtl/GrMtlAttachment.mm
        src/gpu/ganesh/mtl/GrMtlBackendSemaphore.mm
        src/gpu/ganesh/mtl/GrMtlBackendSurface.mm
        src/gpu/ganesh/mtl/GrMtlBuffer.mm
        src/gpu/ganesh/mtl/GrMtlCaps.mm
        src/gpu/ganesh/mtl/GrMtlCommandBuffer.mm
        src/gpu/ganesh/mtl/GrMtlDepthStencil.mm
        src/gpu/ganesh/mtl/GrMtlDirectContext.mm
        src/gpu/ganesh/mtl/GrMtlFramebuffer.mm
        src/gpu/ganesh/mtl/GrMtlGpu.mm
        src/gpu/ganesh/mtl/GrMtlOpsRenderPass.mm
        src/gpu/ganesh/mtl/GrMtlPipelineState.mm
        src/gpu/ganesh/mtl/GrMtlPipelineStateBuilder.mm
        src/gpu/ganesh/mtl/GrMtlPipelineStateDataManager.mm
        src/gpu/ganesh/mtl/GrMtlRenderTarget.mm
        src/gpu/ganesh/mtl/GrMtlResourceProvider.mm
        src/gpu/ganesh/mtl/GrMtlSampler.mm
        src/gpu/ganesh/mtl/GrMtlSemaphore.mm
        src/gpu/ganesh/mtl/GrMtlTexture.mm
        src/gpu/ganesh/mtl/GrMtlTextureRenderTarget.mm
        src/gpu/ganesh/mtl/GrMtlTrampoline.mm
        src/gpu/ganesh/mtl/GrMtlTypesPriv.mm
        src/gpu/ganesh/mtl/GrMtlUniformHandler.mm
        src/gpu/ganesh/mtl/GrMtlUtil.mm
        src/gpu/ganesh/mtl/GrMtlVaryingHandler.mm
        src/gpu/ganesh/surface/SkSurface_GaneshMtl.mm
        src/gpu/mtl/MtlMemoryAllocatorImpl.mm
        src/gpu/mtl/MtlUtils.mm
    )
    set_source_files_properties(${metal_sources} PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
    list(APPEND raster_sources ${metal_sources} src/gpu/ganesh/GrUniformDataManager.cpp)
    # the cross toolchain has no ios compiler-rt for clang's @available calls
    list(APPEND raster_sources "${YOZORA_LLVM_SRC}/compiler-rt/lib/builtins/os_version_check.c")
    set_source_files_properties("${YOZORA_LLVM_SRC}/compiler-rt/lib/builtins/os_version_check.c" PROPERTIES COMPILE_OPTIONS "-include;stdbool.h")
    target_compile_definitions(Skia PRIVATE SK_METAL SK_GANESH)
    target_link_libraries(Skia PRIVATE "-weak_framework Metal" "-framework Foundation")
else ()
    list(FILTER raster_sources EXCLUDE REGEX "^src/gpu/")
endif ()
set_property(TARGET Skia PROPERTY SOURCES ${raster_sources})
