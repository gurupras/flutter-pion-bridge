# Release binaries for the CMake platform builds (Linux, Windows).
#
# The binaries are not committed. A platform CMakeLists uses the files that
# scripts/build_<platform>.sh leaves in the plugin source tree when they exist
# (local development); otherwise it calls pion_bridge_download_binaries(), which
# fetches the release archive matching pubspec.yaml's version from GitHub
# Releases, checks it against the release's SHA256SUMS, and extracts it under
# the app's build directory.
#
# PION_BRIDGE_BINARIES_BASE_URL (environment) replaces the release download URL,
# e.g. a mirror, or file:///path/to/dist to try archives before publishing them.

set(_PION_BRIDGE_ROOT "${CMAKE_CURRENT_LIST_DIR}/..")
set(_PION_BRIDGE_RELEASES "https://github.com/gurupras/flutter-pion-bridge/releases/download")

# pion_bridge_download_binaries(<platform> <out-var>)
# Sets <out-var> to the directory holding the extracted archive for <platform>
# (linux-x64, linux-arm64, windows-x64).
function(pion_bridge_download_binaries PLATFORM OUT_DIR_VAR)
  file(STRINGS "${_PION_BRIDGE_ROOT}/pubspec.yaml" _version_lines REGEX "^version:")
  list(GET _version_lines 0 _version_line)
  string(REGEX REPLACE "^version:[ \t]*([^+ \t]+).*$" "\\1" _version "${_version_line}")

  set(_base "$ENV{PION_BRIDGE_BINARIES_BASE_URL}")
  if(NOT _base)
    set(_base "${_PION_BRIDGE_RELEASES}/v${_version}")
  endif()
  set(_name "pionbridge-${_version}-${PLATFORM}.tar.gz")
  set(_root "${CMAKE_BINARY_DIR}/pion_bridge_binaries")
  set(_dir "${_root}/${_version}/${PLATFORM}")

  if(NOT EXISTS "${_dir}/.complete")
    set(_hint "Build the binaries locally (scripts/build_*.sh) or set PION_BRIDGE_BINARIES_BASE_URL.")
    file(REMOVE_RECURSE "${_dir}" "${_root}/download")
    file(MAKE_DIRECTORY "${_root}/download")

    file(DOWNLOAD "${_base}/SHA256SUMS" "${_root}/download/SHA256SUMS"
         STATUS _status TLS_VERIFY ON)
    list(GET _status 0 _code)
    if(NOT _code EQUAL 0)
      message(FATAL_ERROR "pion_bridge: downloading ${_base}/SHA256SUMS failed: ${_status}\n${_hint}")
    endif()
    file(STRINGS "${_root}/download/SHA256SUMS" _sums)
    set(_expected "")
    foreach(_line IN LISTS _sums)
      if(_line MATCHES "^([0-9a-fA-F]+)[ \t]+\\*?(.+)$" AND CMAKE_MATCH_2 STREQUAL _name)
        set(_expected "${CMAKE_MATCH_1}")
      endif()
    endforeach()
    if(NOT _expected)
      message(FATAL_ERROR "pion_bridge: ${_name} is not listed in ${_base}/SHA256SUMS\n${_hint}")
    endif()

    message(STATUS "pion_bridge: downloading ${_base}/${_name}")
    file(DOWNLOAD "${_base}/${_name}" "${_root}/download/${_name}"
         EXPECTED_HASH SHA256=${_expected} STATUS _status TLS_VERIFY ON)
    list(GET _status 0 _code)
    if(NOT _code EQUAL 0)
      message(FATAL_ERROR "pion_bridge: downloading ${_base}/${_name} failed: ${_status}\n${_hint}")
    endif()

    file(MAKE_DIRECTORY "${_dir}")
    execute_process(COMMAND "${CMAKE_COMMAND}" -E tar xzf "${_root}/download/${_name}"
                    WORKING_DIRECTORY "${_dir}" RESULT_VARIABLE _result)
    if(NOT _result EQUAL 0)
      message(FATAL_ERROR "pion_bridge: extracting ${_name} failed: ${_result}")
    endif()
    file(REMOVE_RECURSE "${_root}/download")
    file(TOUCH "${_dir}/.complete")
  endif()

  set(${OUT_DIR_VAR} "${_dir}" PARENT_SCOPE)
endfunction()
