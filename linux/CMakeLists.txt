cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "pion_bridge")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "pion_bridge_plugin")

add_library(${PLUGIN_NAME} SHARED
  "pionbridge_plugin.cc"
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)

# Bundle the pionbridge sidecar and shared library alongside the plugin.
# Apps that only use shared mode with their own library (e.g. one that links
# package cshared together with their media code) can skip bundling the
# sidecar and libpionbridge: set(PION_BRIDGE_BUNDLE_BINARIES OFF) before the
# generated plugins are included.
option(PION_BRIDGE_BUNDLE_BINARIES "Bundle the pionbridge sidecar and libpionbridge" ON)
if(NOT PION_BRIDGE_BUNDLE_BINARIES)
  return()
endif()

# build_linux.sh leaves local builds in bundle/lib (arm64 with an _arm64
# suffix); without them, or with PION_BRIDGE_BINARIES_BASE_URL set, the
# release archive for this version is downloaded
# (build_support/pion_bridge_binaries.cmake). Both are installed under their
# canonical names so the runtime lookup (lib/pionbridge) is the same everywhere.
if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
  set(PIONBRIDGE_ARCH_SUFFIX "_arm64")
  set(PIONBRIDGE_PLATFORM "linux-arm64")
else()
  set(PIONBRIDGE_ARCH_SUFFIX "")
  set(PIONBRIDGE_PLATFORM "linux-x64")
endif()
set(PIONBRIDGE_BINARY "${CMAKE_CURRENT_SOURCE_DIR}/bundle/lib/pionbridge${PIONBRIDGE_ARCH_SUFFIX}")
# Shared mode: the same server as an in-process library, loaded by the Dart
# side with dart:ffi (PionBridgeMode.shared). A local build may lack it (no
# cross compiler for the arch); release archives always carry it.
set(PIONBRIDGE_SHARED_LIB "${CMAKE_CURRENT_SOURCE_DIR}/bundle/lib/libpionbridge${PIONBRIDGE_ARCH_SUFFIX}.so")
if(NOT EXISTS "${PIONBRIDGE_BINARY}" OR DEFINED ENV{PION_BRIDGE_BINARIES_BASE_URL})
  include("${CMAKE_CURRENT_SOURCE_DIR}/../build_support/pion_bridge_binaries.cmake")
  pion_bridge_download_binaries("${PIONBRIDGE_PLATFORM}" PIONBRIDGE_DOWNLOADED)
  set(PIONBRIDGE_BINARY "${PIONBRIDGE_DOWNLOADED}/pionbridge")
  set(PIONBRIDGE_SHARED_LIB "${PIONBRIDGE_DOWNLOADED}/libpionbridge.so")
endif()

install(FILES "${PIONBRIDGE_BINARY}"
        DESTINATION "lib"
        RENAME "pionbridge"
        PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE
                    GROUP_READ GROUP_EXECUTE
                    WORLD_READ WORLD_EXECUTE)
if(EXISTS "${PIONBRIDGE_SHARED_LIB}")
  install(FILES "${PIONBRIDGE_SHARED_LIB}"
          DESTINATION "lib"
          RENAME "libpionbridge.so")
endif()
