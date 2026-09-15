cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "pion_bridge")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "pion_bridge_plugin")

add_library(${PLUGIN_NAME} SHARED
  "pionbridge_plugin.cpp"
  "pion_bridge_plugin_c_api.cpp"
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# Bundle pionbridge.exe (and, when built, the shared-mode pionbridge.dll) next to
# the host executable through <plugin>_bundled_libraries, which the app's
# CMakeLists installs into its bundle. An install() here cannot: the app sets
# CMAKE_INSTALL_PREFIX to the bundle directory only after including the plugins,
# so a clean build installed the binaries under the default prefix and the
# bundle only got them from a second configure.
# Apps that only use shared mode with their own library (e.g. one that links
# package cshared together with their media code) can skip bundling the
# sidecar and pionbridge.dll: set(PION_BRIDGE_BUNDLE_BINARIES OFF) before the
# generated plugins are included.
option(PION_BRIDGE_BUNDLE_BINARIES "Bundle the pionbridge sidecar and pionbridge.dll" ON)
if(NOT PION_BRIDGE_BUNDLE_BINARIES)
  return()
endif()

# build_windows.sh leaves local builds in runner/resources; without them, the
# release archive for this version is downloaded
# (build_support/pion_bridge_binaries.cmake).
set(PIONBRIDGE_BUNDLED "")
set(PIONBRIDGE_EXE "${CMAKE_CURRENT_SOURCE_DIR}/runner/resources/pionbridge.exe")
# Shared mode (PionBridgeMode.shared): the in-process DLL, loaded with dart:ffi.
# A local build may lack it (no MinGW); release archives always carry it.
set(PIONBRIDGE_DLL "${CMAKE_CURRENT_SOURCE_DIR}/runner/resources/pionbridge.dll")
if(NOT EXISTS "${PIONBRIDGE_EXE}")
  include("${CMAKE_CURRENT_SOURCE_DIR}/../build_support/pion_bridge_binaries.cmake")
  pion_bridge_download_binaries("windows-x64" PIONBRIDGE_DOWNLOADED)
  set(PIONBRIDGE_EXE "${PIONBRIDGE_DOWNLOADED}/pionbridge.exe")
  set(PIONBRIDGE_DLL "${PIONBRIDGE_DOWNLOADED}/pionbridge.dll")
endif()
list(APPEND PIONBRIDGE_BUNDLED "${PIONBRIDGE_EXE}")
if(EXISTS "${PIONBRIDGE_DLL}")
  list(APPEND PIONBRIDGE_BUNDLED "${PIONBRIDGE_DLL}")
endif()
set(pion_bridge_bundled_libraries "${PIONBRIDGE_BUNDLED}" PARENT_SCOPE)
