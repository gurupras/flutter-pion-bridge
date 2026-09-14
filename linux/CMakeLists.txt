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

# Bundle the pionbridge binary alongside the plugin.
# build_linux.sh emits amd64 as "pionbridge" and arm64 as "pionbridge_arm64";
# pick the one matching the target arch and install it AS "pionbridge" so the
# plugin's runtime lookup (lib/pionbridge) is unchanged on every arch.
# Apps that only use shared mode with their own library (e.g. one that links
# package cshared together with their media code) can skip bundling the
# sidecar and libpionbridge: set(PION_BRIDGE_BUNDLE_BINARIES OFF) before the
# generated plugins are included.
option(PION_BRIDGE_BUNDLE_BINARIES "Bundle the pionbridge sidecar and libpionbridge" ON)
if(NOT PION_BRIDGE_BUNDLE_BINARIES)
  return()
endif()

if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
  set(PIONBRIDGE_BINARY "${CMAKE_CURRENT_SOURCE_DIR}/bundle/lib/pionbridge_arm64")
else()
  set(PIONBRIDGE_BINARY "${CMAKE_CURRENT_SOURCE_DIR}/bundle/lib/pionbridge")
endif()
if(EXISTS "${PIONBRIDGE_BINARY}")
  install(FILES "${PIONBRIDGE_BINARY}"
          DESTINATION "lib"
          RENAME "pionbridge"
          PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE
                      GROUP_READ GROUP_EXECUTE
                      WORLD_READ WORLD_EXECUTE)
endif()

# Shared mode: the same server as an in-process library, loaded by the Dart
# side with dart:ffi (PionBridgeMode.shared). Optional — only bundled when
# build_linux.sh has produced it. Installed as libpionbridge.so on every arch.
if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
  set(PIONBRIDGE_SHARED_LIB "${CMAKE_CURRENT_SOURCE_DIR}/bundle/lib/libpionbridge_arm64.so")
else()
  set(PIONBRIDGE_SHARED_LIB "${CMAKE_CURRENT_SOURCE_DIR}/bundle/lib/libpionbridge.so")
endif()
if(EXISTS "${PIONBRIDGE_SHARED_LIB}")
  install(FILES "${PIONBRIDGE_SHARED_LIB}"
          DESTINATION "lib"
          RENAME "libpionbridge.so")
endif()
