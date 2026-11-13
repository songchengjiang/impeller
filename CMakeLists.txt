cmake_minimum_required(VERSION 3.25)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR
   AND NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET)
  set(CMAKE_OSX_DEPLOYMENT_TARGET 26.0 CACHE STRING "Minimum macOS version")
endif()
project(Impeller2D VERSION 0.1.0 LANGUAGES CXX OBJCXX)

if(NOT CMAKE_SYSTEM_NAME STREQUAL "Darwin")
  message(FATAL_ERROR "Impeller2D currently builds for macOS with Metal.")
endif()

include(GNUInstallDirs)
if(PROJECT_IS_TOP_LEVEL)
  include(CTest)
endif()
find_package(Python3 REQUIRED COMPONENTS Interpreter)
if(NOT DEFINED ICU_ROOT)
  find_program(impeller_brew brew)
  if(impeller_brew)
    execute_process(COMMAND "${impeller_brew}" --prefix icu4c
      OUTPUT_VARIABLE ICU_ROOT OUTPUT_STRIP_TRAILING_WHITESPACE)
  endif()
endif()
find_package(ICU REQUIRED COMPONENTS uc i18n)
find_package(PkgConfig REQUIRED)
pkg_check_modules(HARFBUZZ REQUIRED IMPORTED_TARGET harfbuzz)
find_package(absl CONFIG REQUIRED)

option(IMPELLER2D_BUILD_EXAMPLE "Build the AppKit example" ${PROJECT_IS_TOP_LEVEL})
set(IMPELLER2D_DEPENDENCIES "${CMAKE_CURRENT_SOURCE_DIR}/.deps" CACHE PATH
  "Dependency directory prepared by scripts/bootstrap_macos.py")
set(IMPELLER2D_SKIA_SOURCE "${IMPELLER2D_DEPENDENCIES}/skia" CACHE PATH "Skia checkout")
set(IMPELLER2D_SKIA_BUILD "${IMPELLER2D_DEPENDENCIES}/skia/out/impeller" CACHE PATH "Skia build output")
set(IMPELLER2D_FLATBUFFERS_SOURCE "${IMPELLER2D_DEPENDENCIES}/flatbuffers" CACHE PATH "FlatBuffers checkout")
set(IMPELLER2D_FLATC "${IMPELLER2D_DEPENDENCIES}/flatbuffers-build/flatc" CACHE FILEPATH "FlatBuffers compiler")
set(IMPELLER2D_IMPELLERC "${IMPELLER2D_DEPENDENCIES}/impellerc" CACHE FILEPATH "Impeller offline shader compiler")
option(IMPELLER2D_REBUILD_SHADERS "Rebuild the checked-in Metal shader libraries from GLSL" OFF)
if(IMPELLER2D_REBUILD_SHADERS)
  set(impeller_metal_deployment "${CMAKE_OSX_DEPLOYMENT_TARGET}")
  if(NOT impeller_metal_deployment)
    set(impeller_metal_deployment 26.0)
  endif()
  find_program(IMPELLER2D_METAL NAMES metal HINTS /usr/bin REQUIRED)
  if(NOT EXISTS "${IMPELLER2D_IMPELLERC}")
    message(FATAL_ERROR "Missing ${IMPELLER2D_IMPELLERC}. See the shader rebuild instructions.")
  endif()
  execute_process(COMMAND xcrun --sdk macosx --show-sdk-path
    OUTPUT_VARIABLE impeller_metal_sdk OUTPUT_STRIP_TRAILING_WHITESPACE
    COMMAND_ERROR_IS_FATAL ANY)
endif()
foreach(required IN ITEMS
    "${IMPELLER2D_SKIA_SOURCE}/include/core/SkCanvas.h"
    "${IMPELLER2D_FLATBUFFERS_SOURCE}/include/flatbuffers/flatbuffers.h"
    "${IMPELLER2D_FLATC}")
  if(NOT EXISTS "${required}")
    message(FATAL_ERROR "Missing ${required}. See README.md for dependency setup.")
  endif()
endforeach()

set(impeller_vendor "${CMAKE_CURRENT_SOURCE_DIR}/vendor")
set(impeller_cmake "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
set(impeller_generated "${CMAKE_CURRENT_BINARY_DIR}/generated")
include(cmake/EngineSources.cmake)
include(cmake/BuildShaders.cmake)

set(skia_libraries)
foreach(component IN ITEMS skparagraph skshaper skunicode_icu skunicode_core skia skcms)
  set(archive "${IMPELLER2D_SKIA_BUILD}/lib${component}.a")
  if(NOT EXISTS "${archive}")
    message(FATAL_ERROR "Missing ${archive}. See README.md for dependency setup.")
  endif()
  list(APPEND skia_libraries "${archive}")
endforeach()

add_library(impeller2d SHARED
  src/engine.mm
  ${impeller_engine_sources}
  ${impeller_generated_sources}
)
add_library(Impeller2D::impeller2d ALIAS impeller2d)
target_compile_features(impeller2d PUBLIC cxx_std_20)
set_target_properties(impeller2d PROPERTIES
  OBJCXX_STANDARD 20
  OBJCXX_STANDARD_REQUIRED YES
  CXX_VISIBILITY_PRESET hidden
  OBJCXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN YES
  VERSION ${PROJECT_VERSION}
  SOVERSION ${PROJECT_VERSION_MAJOR}
)
target_compile_options(impeller2d PRIVATE -fno-rtti $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
target_compile_definitions(impeller2d PRIVATE
  IMPELLER_ENABLE_METAL=1 IMPELLER_SUPPORTS_RENDERING=1
)
target_include_directories(impeller2d
  PUBLIC "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>"
         "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
  PRIVATE "${impeller_vendor}" "${impeller_vendor}/txt/src" "${impeller_generated}"
          "${impeller_vendor}/generated"
)
target_include_directories(impeller2d SYSTEM PRIVATE
  "${IMPELLER2D_SKIA_SOURCE}" "${IMPELLER2D_FLATBUFFERS_SOURCE}/include")
target_link_libraries(impeller2d PRIVATE
  ${skia_libraries} ICU::uc ICU::i18n PkgConfig::HARFBUZZ
  absl::flat_hash_map absl::hash absl::int128 absl::status absl::statusor
  absl::strings absl::str_format
  "-framework AppKit" "-framework CoreFoundation" "-framework CoreGraphics" "-framework CoreText"
  "-framework Foundation" "-framework ImageIO" "-framework Metal"
  "-framework MetalPerformanceShaders" "-framework QuartzCore"
)

install(TARGETS impeller2d EXPORT Impeller2DConfig
  LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}")
install(DIRECTORY include/ DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")
install(EXPORT Impeller2DConfig NAMESPACE Impeller2D::
  DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/Impeller2D")
install(FILES LICENSE DESTINATION "${CMAKE_INSTALL_DATADIR}/Impeller2D")
install(FILES "${IMPELLER2D_SKIA_SOURCE}/LICENSE"
  DESTINATION "${CMAKE_INSTALL_DATADIR}/Impeller2D" RENAME LICENSE.Skia)
install(FILES "${IMPELLER2D_FLATBUFFERS_SOURCE}/LICENSE"
  DESTINATION "${CMAKE_INSTALL_DATADIR}/Impeller2D" RENAME LICENSE.FlatBuffers)

if(IMPELLER2D_BUILD_EXAMPLE)
  add_executable(impeller2d_demo examples/main.mm)
  set_target_properties(impeller2d_demo PROPERTIES OBJCXX_STANDARD 20
    OBJCXX_STANDARD_REQUIRED YES)
  target_compile_options(impeller2d_demo PRIVATE -fobjc-arc)
  target_link_libraries(impeller2d_demo PRIVATE Impeller2D::impeller2d
    "-framework AppKit" "-framework Metal" "-framework QuartzCore")
endif()

if(BUILD_TESTING AND PROJECT_IS_TOP_LEVEL)
  add_executable(impeller2d_smoke tests/smoke.mm)
  set_target_properties(impeller2d_smoke PROPERTIES OBJCXX_STANDARD 20
    OBJCXX_STANDARD_REQUIRED YES)
  target_compile_options(impeller2d_smoke PRIVATE -fobjc-arc)
  target_link_libraries(impeller2d_smoke PRIVATE Impeller2D::impeller2d
    "-framework Foundation" "-framework Metal")
  add_test(NAME impeller2d.smoke COMMAND impeller2d_smoke)
endif()
