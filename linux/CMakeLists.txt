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
