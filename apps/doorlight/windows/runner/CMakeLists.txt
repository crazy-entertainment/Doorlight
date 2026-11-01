cmake_minimum_required(VERSION 3.15)
project(runner LANGUAGES CXX)

option(SYBL_VISUAL_UAT "Build the isolated visual UAT host" OFF)
if(SYBL_VISUAL_UAT)
  include("${FLUTTER_MANAGED_DIR}/ephemeral/generated_config.cmake")
  set(_uat_entrypoint_found FALSE)
  foreach(_uat_environment IN LISTS FLUTTER_TOOL_ENVIRONMENT)
    string(REPLACE "\\" "/" _uat_normalized "${_uat_environment}")
    if(_uat_normalized MATCHES "^FLUTTER_TARGET=(.*/)?test_driver/visual_uat.dart$")
      set(_uat_entrypoint_found TRUE)
    endif()
  endforeach()
  if(NOT _uat_entrypoint_found)
    message(FATAL_ERROR "SYBL_VISUAL_UAT requires test_driver/visual_uat.dart; refusing a mixed native/Dart profile")
  endif()
  get_filename_component(_uat_base "${CMAKE_SOURCE_DIR}/../../../local/uat" ABSOLUTE)
  file(TO_NATIVE_PATH "${_uat_base}" _uat_native_base)
  string(REPLACE "\\" "\\\\" _uat_literal_base "${_uat_native_base}")
  set(SYBL_VISUAL_UAT_DEFINITIONS SYBL_VISUAL_UAT "SYBL_VISUAL_UAT_BASE=L\"${_uat_literal_base}\"")
  set(SYBL_VISUAL_UAT_DEFINITIONS SYBL_VISUAL_UAT "SYBL_VISUAL_UAT_BASE=L\"${_uat_literal_base}\"" PARENT_SCOPE)
endif()

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "annotation_overlay.cpp"
  "appearance_pipe.cpp"
  "companion_input.cpp"
  "capture_activity_monitor.cpp"
  "desktop_sonar.cpp"
  "flutter_window.cpp"
  "hologram_popup.cpp"
  "jami_channels.cpp"
  "main.cpp"
  "invite_link_win32.cpp"
  "picked_file_staging.cpp"
  "system_tray.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "window_bounds.cpp"
  "window_bounds_win32.cpp"
  "window_capture_protection.cpp"
  "window_dismiss.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})
if(SYBL_VISUAL_UAT)
  target_compile_definitions(${BINARY_NAME} PRIVATE ${SYBL_VISUAL_UAT_DEFINITIONS})
endif()

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib" "comctl32.lib" "gdi32.lib" "windowscodecs.lib" "winmm.lib" "wtsapi32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE userenv advapi32)
target_link_libraries(${BINARY_NAME} PRIVATE ole32 oleaut32 uiautomationcore)
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# C++/WinRT requires exceptions; keep it outside the runner's exception-free ABI.
add_library(nearby_radio STATIC "nearby_radio.cpp")
target_compile_features(nearby_radio PRIVATE cxx_std_20)
target_compile_options(nearby_radio PRIVATE /EHsc /bigobj)
target_compile_definitions(nearby_radio PRIVATE _HAS_EXCEPTIONS=1 NOMINMAX)
target_link_libraries(nearby_radio PRIVATE flutter flutter_wrapper_app windowsapp runtimeobject)
target_link_libraries(${BINARY_NAME} PRIVATE nearby_radio)

# === libjami engine bridge (M3) ============================================================================
# The daemon-ABI code is isolated in its own static library: it must compile with exceptions ENABLED and the
# default warning level (jami-core.lib was built that way), NOT the runner's /WX + _HAS_EXCEPTIONS=0. The
# runner only links it + calls jami_bridge::Start()/Stop() through the plain jami_bridge.h header.
# Source is shared; matched libraries and dependency build outputs stay local.
get_filename_component(JAMI_SOURCE "${CMAKE_SOURCE_DIR}/../../../native/jami" ABSOLUTE)
get_filename_component(_default_jami_daemon "${CMAKE_SOURCE_DIR}/../../../local/dev/jami-src/jami-daemon" ABSOLUTE)
set(SYBL_JAMI_DAEMON "${_default_jami_daemon}" CACHE PATH
  "Matched daemon archive and contrib build inputs")
get_filename_component(JAMI_DAEMON "${SYBL_JAMI_DAEMON}" ABSOLUTE)
set(JAMI_CONTRIB "${JAMI_DAEMON}/contrib")
set(SYBL_JAMI_CORE_LIBRARY "${JAMI_DAEMON}/build/lib/jami-core.lib")
# This pins the existing input identity. An override must name a recorded build;
# matching this hash alone does not establish its dependency/source provenance.
set(SYBL_JAMI_CORE_SHA256
  "f00d3a49554954eeb5ce488fef89aec8e36d84ab631dbdadd57e189cfe392084"
  CACHE STRING "Recorded SHA-256 of the selected Windows daemon archive")
set(SYBL_OPENSSL_SSL_DLL "${JAMI_CONTRIB}/build/openssl/libssl-3-x64.dll")
set(SYBL_OPENSSL_CRYPTO_DLL "${JAMI_CONTRIB}/build/openssl/libcrypto-3-x64.dll")
set(SYBL_OPENSSL_SSL_SHA256
  "34dcc2b412ffb61a7c53da5a007af662c2e1d05afb2cce7239516bea5d6c6a00"
  CACHE STRING "Recorded SHA-256 of the selected Windows OpenSSL SSL DLL")
set(SYBL_OPENSSL_CRYPTO_SHA256
  "1178a48f308349803e6cba11c5b99addd0d780780071d0730655cb6e0719dee6"
  CACHE STRING "Recorded SHA-256 of the selected Windows OpenSSL Crypto DLL")
include("${CMAKE_CURRENT_SOURCE_DIR}/check_native_input.cmake")
add_custom_target(check_jami_core
  COMMAND "${CMAKE_COMMAND}"
    "-DSYBL_JAMI_CORE_LIBRARY=${SYBL_JAMI_CORE_LIBRARY}"
    "-DSYBL_JAMI_CORE_SHA256=${SYBL_JAMI_CORE_SHA256}"
    "-DSYBL_OPENSSL_SSL_DLL=${SYBL_OPENSSL_SSL_DLL}"
    "-DSYBL_OPENSSL_SSL_SHA256=${SYBL_OPENSSL_SSL_SHA256}"
    "-DSYBL_OPENSSL_CRYPTO_DLL=${SYBL_OPENSSL_CRYPTO_DLL}"
    "-DSYBL_OPENSSL_CRYPTO_SHA256=${SYBL_OPENSSL_CRYPTO_SHA256}"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/check_native_input.cmake"
  VERBATIM)
add_dependencies(${BINARY_NAME} check_jami_core)
function(sybl_test name)
  add_executable(${name} ${ARGN})
  target_compile_features(${name} PRIVATE cxx_std_17)
  add_test(NAME ${name} COMMAND ${name})
endfunction()

sybl_test(nearby_radio_mailbox_test "nearby_radio_mailbox_test.cpp")
sybl_test(widget_companion_test "widget_companion_test.cpp")
sybl_test(appearance_pipe_test "appearance_pipe_test.cpp" "appearance_pipe.cpp")
target_compile_definitions(appearance_pipe_test PRIVATE NOMINMAX UNICODE _UNICODE)
target_compile_options(appearance_pipe_test PRIVATE /UNDEBUG /W4 /WX)
target_link_libraries(appearance_pipe_test PRIVATE userenv advapi32)
sybl_test(companion_input_test "companion_input_test.cpp" "companion_input.cpp")
target_compile_definitions(companion_input_test PRIVATE NOMINMAX UNICODE _UNICODE)
target_compile_options(companion_input_test PRIVATE /UNDEBUG /W4 /WX)
target_link_libraries(companion_input_test PRIVATE user32 shell32)
sybl_test(nearby_radio_lifetime_test "nearby_radio_lifetime_test.cpp")
target_compile_options(nearby_radio_mailbox_test PRIVATE /UNDEBUG)

sybl_test(received_seed_test "received_seed_test.cpp")
target_include_directories(received_seed_test PRIVATE "${JAMI_SOURCE}/src")
target_compile_options(received_seed_test PRIVATE /UNDEBUG)
set(SYBL_JSONCPP "${JAMI_CONTRIB}/build/jsoncpp")

add_library(jami_bridge STATIC
  "jami_bridge.cpp"
  "archive_path_policy.cpp"
  "archive_protection.cpp"
  "archive_secret_store.cpp"
  "command_journal_store.cpp"
  "stage_registry.cpp"
  "identity_restore.cpp"
  "screen_source.cpp"
  "friend_routing.cpp"
  "group_policy.cpp"
  "known_device_policy.cpp"
  "call_policy.cpp"
  "conversation_load_registry.cpp"
  "dm_topic_wire.cpp"
  "file_thumbnail_wire.cpp"
  "hologram_wire.cpp"
  "timeline_wire.cpp"
  "presence_metadata.cpp"
  "presence_wire.cpp"
  "remote_control_activation.cpp"
  "remote_control_routing.cpp"
  "remote_control_grants.cpp"
  "remote_control_focus.cpp"
  "remote_control_ice.cpp"
  "remote_control_lan.cpp"
  "remote_control_preview.cpp"
  "remote_control_controller.cpp"
  "remote_control_role.cpp"
  "remote_control_protocol.cpp"
  "remote_control_policy.cpp"
  "remote_control_runtime.cpp"
  "win32_dpapi.cpp"
  "win32_input_adapter.cpp"
  "remote_control_host.cpp")
target_compile_features(jami_bridge PRIVATE cxx_std_20)
if(SYBL_VISUAL_UAT)
  target_compile_definitions(jami_bridge PRIVATE ${SYBL_VISUAL_UAT_DEFINITIONS})
endif()
target_compile_options(jami_bridge PRIVATE /EHsc /bigobj)
target_include_directories(jami_bridge PRIVATE
  "${CMAKE_SOURCE_DIR}/../third_party/record_windows/windows/include"
  "${JAMI_SOURCE}/src/jami"
  "${JAMI_SOURCE}/src"
  "${SYBL_JSONCPP}/include"
  # FFmpeg (libavutil) headers — jami_bridge allocates the RGBA pull-buffer (av_frame_alloc/av_frame_get_buffer)
  # the daemon scaler converts into, and reads back its planes. Symbols resolve from jami-core.lib (bundles ffmpeg).
  "${JAMI_CONTRIB}/build/ffmpeg/Build/win32/x64/include")
# Release-only: jami-core.lib is /MD Release (_ITERATOR_DEBUG_LEVEL=0), so a Debug /MDd build fails the final
# link with LNK2038 IDL/runtime mismatches. Fail fast at compile time with a clear #error instead. (Profile uses
# Release flags -> /MD -> links fine, so the guard is Debug-config only.)
target_compile_definitions(jami_bridge PRIVATE "$<$<CONFIG:Debug>:SYBL_JAMI_DEBUG_UNSUPPORTED>")
# std::filesystem::u8path (used to build received-file paths from UTF-8 names) is deprecated in C++20 but is the
# clearest UTF-8→path conversion; silence the noise (the lib is not /WX, so it's only cosmetic).
target_compile_definitions(jami_bridge PRIVATE "_SILENCE_CXX20_U8PATH_DEPRECATION_WARNING")
target_link_libraries(${BINARY_NAME} PRIVATE jami_bridge)

sybl_test(screen_source_test "screen_source.cpp" "screen_source_test.cpp")

sybl_test(friend_routing_test "friend_routing.cpp" "friend_routing_test.cpp")

sybl_test(group_policy_test
  "friend_routing.cpp"
  "timeline_wire.cpp"
  "group_policy.cpp"
  "group_policy_test.cpp")

sybl_test(group_call_wire_test
  "friend_routing.cpp"
  "group_call_wire_test.cpp")

sybl_test(known_device_policy_test
  "known_device_policy.cpp"
  "timeline_wire.cpp"
  "known_device_policy_test.cpp")

sybl_test(device_pairing_test "device_pairing_test.cpp")
sybl_test(reset_doorlight_test "reset_doorlight_test.cpp")

sybl_test(call_policy_test "call_policy.cpp" "call_policy_test.cpp")

sybl_test(conversation_load_registry_test
  "conversation_load_registry.cpp"
  "conversation_load_registry_test.cpp")

sybl_test(timeline_wire_test "timeline_wire.cpp" "timeline_wire_test.cpp")

sybl_test(file_thumbnail_wire_test
  "file_thumbnail_wire.cpp"
  "timeline_wire.cpp"
  "file_thumbnail_wire_test.cpp")

sybl_test(presence_metadata_test
  "presence_metadata.cpp"
  "timeline_wire.cpp"
  "presence_metadata_test.cpp")
target_link_libraries(presence_metadata_test PRIVATE user32 version)

sybl_test(presence_wire_test
  "presence_wire.cpp"
  "presence_metadata.cpp"
  "timeline_wire.cpp"
  "presence_wire_test.cpp"
  "${SYBL_JSONCPP}/src/lib_json/json_reader.cpp"
  "${SYBL_JSONCPP}/src/lib_json/json_value.cpp"
  "${SYBL_JSONCPP}/src/lib_json/json_writer.cpp")
target_include_directories(presence_wire_test PRIVATE "${SYBL_JSONCPP}/include")
target_link_libraries(presence_wire_test PRIVATE user32 version)

sybl_test(pending_request_gate_test "pending_request_gate_test.cpp")

sybl_test(picked_file_staging_test
  "picked_file_staging.cpp"
  "picked_file_staging_test.cpp")
sybl_test(native_recording_lease_test "native_recording_lease_test.cpp")
sybl_test(native_recording_bridge_test
  "native_recording_bridge_test.cpp"
  "../../third_party/record_windows/windows/sybl_recording_bridge.cpp")
target_compile_definitions(native_recording_bridge_test PRIVATE FLUTTER_PLUGIN_IMPL)
target_link_libraries(native_recording_bridge_test PRIVATE flutter_wrapper_plugin)
target_link_libraries(picked_file_staging_test PRIVATE bcrypt ole32 shell32)

sybl_test(invite_link_win32_test
  "invite_link_win32.cpp"
  "invite_link_win32_test.cpp")
target_link_libraries(invite_link_win32_test PRIVATE user32 advapi32)

sybl_test(video_frame_limits_test "video_frame_limits_test.cpp")

# Only the pure placement decision is compiled here; the registry half lives in
# window_bounds_win32.cpp so this test needs no Win32 and touches no real key.
sybl_test(window_bounds_test "window_bounds.cpp" "window_bounds_test.cpp")

sybl_test(window_presentation_test "window_presentation_test.cpp" "win32_window.cpp" "window_bounds.cpp" "Runner.rc")
target_compile_definitions(window_presentation_test PRIVATE UNICODE _UNICODE)
target_link_libraries(window_presentation_test PRIVATE flutter dwmapi comctl32)
add_custom_command(TARGET window_presentation_test POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different "${FLUTTER_LIBRARY}"
    "$<TARGET_FILE_DIR:window_presentation_test>"
  VERBATIM)

sybl_test(window_appearance_test "window_appearance_test.cpp" "win32_window.cpp" "window_bounds.cpp" "Runner.rc")
target_compile_definitions(window_appearance_test PRIVATE UNICODE _UNICODE)
target_link_libraries(window_appearance_test PRIVATE flutter dwmapi comctl32)
add_custom_command(TARGET window_appearance_test POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different "${FLUTTER_LIBRARY}"
    "$<TARGET_FILE_DIR:window_appearance_test>"
  VERBATIM)

# M10 control core. Production resolves JsonCpp from the one copy already
# bundled in jami-core; the dependency-free parser test compiles the same pinned
# sources locally so it does not need to link the daemon/media engine.
sybl_test(remote_control_protocol_test
  "remote_control_protocol.cpp"
  "remote_control_protocol_test.cpp"
  "${SYBL_JSONCPP}/src/lib_json/json_reader.cpp"
  "${SYBL_JSONCPP}/src/lib_json/json_value.cpp"
  "${SYBL_JSONCPP}/src/lib_json/json_writer.cpp")
target_include_directories(remote_control_protocol_test PRIVATE "${SYBL_JSONCPP}/include")

sybl_test(remote_control_cursor_test "remote_control_cursor_test.cpp")

sybl_test(remote_control_activation_test
  "remote_control_activation.cpp"
  "remote_control_activation_test.cpp")

sybl_test(remote_control_policy_test
  "remote_control_policy.cpp"
  "remote_control_policy_test.cpp")
sybl_test(native_authority_lease_test "native_authority_lease_test.cpp")
target_compile_options(native_authority_lease_test PRIVATE /UNDEBUG)

sybl_test(win32_input_adapter_test
  "remote_control_policy.cpp"
  "win32_input_adapter.cpp"
  "win32_input_adapter_test.cpp")
target_link_libraries(win32_input_adapter_test PRIVATE user32 bcrypt)

sybl_test(remote_control_runtime_test
  "remote_control_policy.cpp"
  "remote_control_runtime.cpp"
  "remote_control_runtime_test.cpp")
target_link_libraries(remote_control_runtime_test PRIVATE user32 dwmapi advapi32)

# Production host -> runtime -> policy -> default Win32 adapter -> SendInput
# import. Tests observe the import; ordinary CTest runs do not send OS input.
add_executable(remote_control_host_test
  "remote_control_host_test.cpp"
  "remote_control_host.cpp"
  "remote_control_activation.cpp"
  "remote_control_protocol.cpp"
  "remote_control_policy.cpp"
  "remote_control_runtime.cpp"
  "remote_control_grants.cpp"
  "remote_control_focus.cpp"
  "remote_control_ice.cpp"
  "remote_control_preview.cpp"
  "screen_source.cpp"
  "win32_input_adapter.cpp"
  "win32_dpapi.cpp"
  "${SYBL_JSONCPP}/src/lib_json/json_reader.cpp"
  "${SYBL_JSONCPP}/src/lib_json/json_value.cpp"
  "${SYBL_JSONCPP}/src/lib_json/json_writer.cpp")
target_compile_features(remote_control_host_test PRIVATE cxx_std_20)
target_include_directories(remote_control_host_test PRIVATE
  "${SYBL_JSONCPP}/include"
  "${FLUTTER_MANAGED_DIR}/ephemeral/cpp_client_wrapper/include")
target_link_libraries(remote_control_host_test PRIVATE
  user32 gdi32 dwmapi advapi32 bcrypt crypt32 shell32)
add_test(NAME remote_control_host_test COMMAND remote_control_host_test)

sybl_test(remote_control_routing_test
  "remote_control_routing.cpp"
  "remote_control_routing_test.cpp")

sybl_test(remote_control_grants_test
  "remote_control_grants.cpp"
  "win32_dpapi.cpp"
  "remote_control_grants_test.cpp")
target_link_libraries(remote_control_grants_test PRIVATE crypt32 shell32)

sybl_test(archive_secret_store_test
  "archive_secret_store.cpp"
  "archive_secret_store_test.cpp"
  "win32_dpapi.cpp")
target_link_libraries(archive_secret_store_test PRIVATE crypt32 bcrypt shell32)

sybl_test(command_journal_store_test
  "command_journal_store.cpp" "command_journal_store_test.cpp" "win32_dpapi.cpp")
target_include_directories(command_journal_store_test PRIVATE "${JAMI_SOURCE}/src")
target_compile_options(command_journal_store_test PRIVATE /UNDEBUG)
target_link_libraries(command_journal_store_test PRIVATE crypt32 bcrypt)

sybl_test(stage_registry_test "stage_registry.cpp" "stage_registry_test.cpp"
  "${SYBL_JSONCPP}/src/lib_json/json_reader.cpp"
  "${SYBL_JSONCPP}/src/lib_json/json_value.cpp"
  "${SYBL_JSONCPP}/src/lib_json/json_writer.cpp")
target_compile_options(stage_registry_test PRIVATE /UNDEBUG)
target_include_directories(stage_registry_test PRIVATE "${SYBL_JSONCPP}/include")

sybl_test(archive_path_policy_test
  "archive_path_policy.cpp"
  "archive_path_policy_test.cpp")

sybl_test(archive_protection_test
  "archive_protection.cpp"
  "archive_protection_test.cpp"
  "archive_secret_store.cpp"
  "win32_dpapi.cpp")
target_link_libraries(archive_protection_test PRIVATE crypt32 bcrypt shell32)

add_executable(identity_restore_test "identity_restore.cpp" "identity_restore_test.cpp"
  "archive_secret_store.cpp" "timeline_wire.cpp" "win32_dpapi.cpp"
  "${SYBL_JSONCPP}/src/lib_json/json_reader.cpp"
  "${SYBL_JSONCPP}/src/lib_json/json_value.cpp"
  "${SYBL_JSONCPP}/src/lib_json/json_writer.cpp")
target_compile_features(identity_restore_test PRIVATE cxx_std_17)
target_include_directories(identity_restore_test PRIVATE "${SYBL_JSONCPP}/include")
target_link_libraries(identity_restore_test PRIVATE crypt32 bcrypt shell32 version)
add_test(NAME identity_restore_test COMMAND identity_restore_test
  "--fixture-root=${CMAKE_SOURCE_DIR}/../../../local/tmp/native-identity-restore-tests")

sybl_test(remote_control_focus_test
  "remote_control_focus.cpp"
  "remote_control_focus_test.cpp")
target_link_libraries(remote_control_focus_test PRIVATE user32)

sybl_test(remote_control_ice_test
  "remote_control_ice.cpp"
  "remote_control_ice_test.cpp")

sybl_test(remote_control_lan_test
  "remote_control_lan.cpp"
  "remote_control_lan_test.cpp")
target_link_libraries(remote_control_lan_test PRIVATE ws2_32 iphlpapi)

sybl_test(remote_control_preview_test
  "remote_control_preview.cpp"
  "remote_control_preview_test.cpp")

sybl_test(remote_control_role_test
  "remote_control_role.cpp"
  "remote_control_role_test.cpp")

sybl_test(window_capture_protection_test
  "window_capture_protection.cpp"
  "window_capture_protection_test.cpp")
target_link_libraries(window_capture_protection_test PRIVATE user32)

add_executable(capture_activity_monitor_test
  "capture_activity_monitor.cpp"
  "capture_activity_monitor_test.cpp")
target_compile_features(capture_activity_monitor_test PRIVATE cxx_std_17)
target_compile_options(capture_activity_monitor_test PRIVATE /EHsc)
target_link_libraries(capture_activity_monitor_test PRIVATE
  Rstrtmgr Advapi32 Shell32 Ole32 Bcrypt uuid)
add_test(NAME capture_activity_monitor_test
  COMMAND capture_activity_monitor_test
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../../local/tmp")

sybl_test(system_tray_test
  "system_tray.cpp"
  "system_tray_test.cpp")
target_link_libraries(system_tray_test PRIVATE shell32 user32)

sybl_test(annotation_overlay_test
  "annotation_overlay.cpp"
  "annotation_overlay_test.cpp")
target_link_libraries(annotation_overlay_test PRIVATE gdi32 user32)

sybl_test(desktop_sonar_test "desktop_sonar.cpp" "desktop_sonar_test.cpp")
target_link_libraries(desktop_sonar_test PRIVATE gdi32 user32)
sybl_test(window_dismiss_test "window_dismiss.cpp" "window_dismiss_test.cpp")
target_compile_definitions(window_dismiss_test PRIVATE NOMINMAX UNICODE _UNICODE)
target_link_libraries(window_dismiss_test PRIVATE gdi32 user32 dwmapi ole32 oleaut32 uiautomationcore)

sybl_test(annotation_ingress_test "annotation_ingress_test.cpp")

sybl_test(dm_topic_wire_test
  "dm_topic_wire.cpp"
  "dm_topic_wire_test.cpp")

sybl_test(remote_control_controller_test
  "remote_control_protocol.cpp"
  "remote_control_controller.cpp"
  "remote_control_controller_test.cpp"
  "${SYBL_JSONCPP}/src/lib_json/json_reader.cpp"
  "${SYBL_JSONCPP}/src/lib_json/json_value.cpp"
  "${SYBL_JSONCPP}/src/lib_json/json_writer.cpp")
target_include_directories(remote_control_controller_test PRIVATE
  "${SYBL_JSONCPP}/include")

# The fat static engine (daemon + all contrib bundled) + the contrib /LIBPATH dirs so embedded /DEFAULTLIB
# directives resolve + the Windows system libs the daemon references. Mirrors local/dev/jami-harness exactly
# (the required link set — see docs/OPERATIONS.md). The final EXE link pulls these.
target_link_libraries(${BINARY_NAME} PRIVATE "${SYBL_JAMI_CORE_LIBRARY}")
target_link_directories(${BINARY_NAME} PRIVATE
  "${JAMI_CONTRIB}/msvc/lib/x64"
  "${JAMI_CONTRIB}/build/ffmpeg/Build/win32/x64/lib"
  "${JAMI_CONTRIB}/build/opendht/build/Release"
  "${JAMI_CONTRIB}/build/argon2/vs2015/Argon2Ref/vs2015/build"
  "${JAMI_CONTRIB}/build/yaml-cpp/build/Release"
  "${JAMI_CONTRIB}/build/natpmp/build/Release"
  "${JAMI_CONTRIB}/build/pjproject/pjsip/lib"
  "${JAMI_CONTRIB}/build/pjproject/pjmedia/lib"
  "${JAMI_CONTRIB}/build/pjproject/pjlib-util/lib"
  "${JAMI_CONTRIB}/build/pjproject/pjlib/lib"
  "${JAMI_CONTRIB}/build/pjproject/pjnath/lib"
  "${JAMI_CONTRIB}/build/fmt/msvc/Release"
  "${JAMI_CONTRIB}/build/llhttp/build/Release"
  "${JAMI_CONTRIB}/build/openssl"
  "${JAMI_CONTRIB}/build/speexdsp/lib"
  "${JAMI_CONTRIB}/build/webrtc-audio-processing/build/Release"
  "${JAMI_CONTRIB}/build/portaudio/build/Release"
  "${JAMI_CONTRIB}/build/libgit2/build/Release"
  "${JAMI_CONTRIB}/build/dhtnet/build/Release"
  "${JAMI_CONTRIB}/build/simdutf/build/src/Release")
target_link_libraries(${BINARY_NAME} PRIVATE
  ws2_32 advapi32 secur32 crypt32 bcrypt ncrypt
  iphlpapi dnsapi mswsock
  ole32 oleaut32 uuid
  strmiids mf mfplat mfuuid mfreadwrite mfsensorgroup
  winmm avrt ksuser
  user32 gdi32 shell32 shlwapi version setupapi comdlg32
  dxgi d3d11 dwmapi wininet userenv psapi powrprof wevtapi
  Gdiplus Wldap32 Normaliz
  runtimeobject windowsapp Rstrtmgr)
# jami-core.lib's objects are /GL (built with LTCG) -> the final link needs /LTCG. The daemon's own x64 target
# excludes the static CRT defaults because it and its consumers are /MD; mirror that upstream setting so the
# Flutter process has one CRT instead of accepting LNK4098 and potentially mixing allocator ownership. The
# /ignore codes cover the same benign PDB/duplicate-section warnings as the proven daemon harness.
target_link_options(${BINARY_NAME} PRIVATE
  "/LTCG"
  "/NODEFAULTLIB:libcmtd"
  "/NODEFAULTLIB:libcmt"
  "/ignore:4099"
  "/ignore:4006"
  "/ignore:4078")

# The daemon's OpenSSL is built SHARED, so the exe has a runtime dependency on these two DLLs (confirmed via
# `dumpbin /dependents`: the only non-system, non-Flutter deps). Copy them next to the exe so it runs
# standalone. Everything else in the engine is statically linked; remaining deps are Windows system DLLs + the
# VC++ runtime (assumed present on dev machines).
set(JAMI_RUNTIME_DLLS
  "${SYBL_OPENSSL_SSL_DLL}"
  "${SYBL_OPENSSL_CRYPTO_DLL}")
foreach(_dll ${JAMI_RUNTIME_DLLS})
  add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${_dll}" "$<TARGET_FILE_DIR:${BINARY_NAME}>"
    VERBATIM)
endforeach()
add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND "${CMAKE_COMMAND}"
    "-DSYBL_JAMI_CORE_LIBRARY=${SYBL_JAMI_CORE_LIBRARY}"
    "-DSYBL_JAMI_CORE_SHA256=${SYBL_JAMI_CORE_SHA256}"
    "-DSYBL_OPENSSL_SSL_DLL=${SYBL_OPENSSL_SSL_DLL}"
    "-DSYBL_OPENSSL_SSL_SHA256=${SYBL_OPENSSL_SSL_SHA256}"
    "-DSYBL_OPENSSL_CRYPTO_DLL=${SYBL_OPENSSL_CRYPTO_DLL}"
    "-DSYBL_OPENSSL_CRYPTO_SHA256=${SYBL_OPENSSL_CRYPTO_SHA256}"
    "-DSYBL_VERIFY_RUNTIME_DIR=$<TARGET_FILE_DIR:${BINARY_NAME}>"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/check_native_input.cmake"
  VERBATIM)
# ===========================================================================================================

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Explicit acceptance targets. Both link the same native archive and libraries
# as the application. They do not add a test mode to the shipped executable.
if(NOT SYBL_VISUAL_UAT)
add_executable(rc6_flutter_transport_test EXCLUDE_FROM_ALL
  "rc6_flutter_transport_test.cpp"
  "jami_channels.cpp"
  "hologram_popup.cpp"
  "annotation_overlay.cpp"
  "capture_activity_monitor.cpp"
  "picked_file_staging.cpp"
  "utils.cpp"
  "window_bounds.cpp"
  "window_bounds_win32.cpp"
  "window_capture_protection.cpp")
add_executable(rc6_windows_input_probe EXCLUDE_FROM_ALL
  "rc6_windows_input_probe.cpp")
foreach(_acceptance rc6_flutter_transport_test rc6_windows_input_probe)
  add_dependencies(${_acceptance} check_jami_core)
  target_compile_features(${_acceptance} PRIVATE cxx_std_20)
  target_compile_options(${_acceptance} PRIVATE /EHsc /bigobj /UNDEBUG)
  target_compile_definitions(${_acceptance} PRIVATE NOMINMAX)
  target_include_directories(${_acceptance} PRIVATE
    "${CMAKE_SOURCE_DIR}" "${SYBL_JSONCPP}/include")
  target_link_libraries(${_acceptance} PRIVATE
    $<TARGET_PROPERTY:${BINARY_NAME},LINK_LIBRARIES>)
  target_link_directories(${_acceptance} PRIVATE
    $<TARGET_PROPERTY:${BINARY_NAME},LINK_DIRECTORIES>)
  target_link_options(${_acceptance} PRIVATE
    $<TARGET_PROPERTY:${BINARY_NAME},LINK_OPTIONS>)
  foreach(_dll ${JAMI_RUNTIME_DLLS} "${FLUTTER_LIBRARY}")
    add_custom_command(TARGET ${_acceptance} POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${_dll}" "$<TARGET_FILE_DIR:${_acceptance}>"
      VERBATIM)
  endforeach()
  add_custom_command(TARGET ${_acceptance} POST_BUILD
    COMMAND "${CMAKE_COMMAND}"
      "-DSYBL_JAMI_CORE_LIBRARY=${SYBL_JAMI_CORE_LIBRARY}"
      "-DSYBL_JAMI_CORE_SHA256=${SYBL_JAMI_CORE_SHA256}"
      "-DSYBL_OPENSSL_SSL_DLL=${SYBL_OPENSSL_SSL_DLL}"
      "-DSYBL_OPENSSL_SSL_SHA256=${SYBL_OPENSSL_SSL_SHA256}"
      "-DSYBL_OPENSSL_CRYPTO_DLL=${SYBL_OPENSSL_CRYPTO_DLL}"
      "-DSYBL_OPENSSL_CRYPTO_SHA256=${SYBL_OPENSSL_CRYPTO_SHA256}"
      "-DSYBL_VERIFY_RUNTIME_DIR=$<TARGET_FILE_DIR:${_acceptance}>"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/check_native_input.cmake"
    VERBATIM)
endforeach()
endif()
# These executables use assert() as their test oracle, including in Release.
# Keep the production targets' Release settings while enabling those checks.
get_property(_runner_targets DIRECTORY PROPERTY BUILDSYSTEM_TARGETS)
foreach(_native_test IN LISTS _runner_targets)
  if(_native_test MATCHES "_test$")
    target_compile_options(${_native_test} PRIVATE /UNDEBUG)
  endif()
endforeach()

sybl_test(hologram_wire_test
  "hologram_wire.cpp" "hologram_wire_test.cpp" "friend_routing.cpp"
  "${SYBL_JSONCPP}/src/lib_json/json_reader.cpp"
  "${SYBL_JSONCPP}/src/lib_json/json_value.cpp"
  "${SYBL_JSONCPP}/src/lib_json/json_writer.cpp")
target_compile_options(hologram_wire_test PRIVATE /UNDEBUG)
target_include_directories(hologram_wire_test PRIVATE "${SYBL_JSONCPP}/include")
