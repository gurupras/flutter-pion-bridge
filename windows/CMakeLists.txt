cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "pion_bridge")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "pion_bridge_plugin")

add_library(${PLUGIN_NAME} SHARED
  "pionbridge_plugin.cpp"
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}")

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# Bundle pionbridge.exe next to the host executable
set(PIONBRIDGE_EXE "${CMAKE_CURRENT_SOURCE_DIR}/runner/resources/pionbridge.exe")
if(EXISTS "${PIONBRIDGE_EXE}")
  install(FILES "${PIONBRIDGE_EXE}"
          DESTINATION "${CMAKE_INSTALL_PREFIX}")
endif()
