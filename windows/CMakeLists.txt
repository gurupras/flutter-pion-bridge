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

# Bundle pionbridge.exe next to the host executable
# Apps that only use shared mode with their own library (e.g. one that links
# package cshared together with their media code) can skip bundling the
# sidecar and pionbridge.dll: set(PION_BRIDGE_BUNDLE_BINARIES OFF) before the
# generated plugins are included.
option(PION_BRIDGE_BUNDLE_BINARIES "Bundle the pionbridge sidecar and pionbridge.dll" ON)
if(NOT PION_BRIDGE_BUNDLE_BINARIES)
  return()
endif()

set(PIONBRIDGE_EXE "${CMAKE_CURRENT_SOURCE_DIR}/runner/resources/pionbridge.exe")
if(EXISTS "${PIONBRIDGE_EXE}")
  install(FILES "${PIONBRIDGE_EXE}"
          DESTINATION "${CMAKE_INSTALL_PREFIX}")
endif()

# Shared mode (PionBridgeMode.shared): the in-process DLL, loaded with dart:ffi.
set(PIONBRIDGE_DLL "${CMAKE_CURRENT_SOURCE_DIR}/runner/resources/pionbridge.dll")
if(EXISTS "${PIONBRIDGE_DLL}")
  install(FILES "${PIONBRIDGE_DLL}"
          DESTINATION "${CMAKE_INSTALL_PREFIX}")
endif()
