cmake_minimum_required(VERSION 3.20)
project(DoorlightWindowsDiagnostics LANGUAGES CXX)

if(NOT WIN32 OR NOT MSVC)
  message(FATAL_ERROR "These diagnostics require Windows and MSVC.")
endif()
enable_testing()
get_filename_component(runner "${CMAKE_CURRENT_LIST_DIR}/../../apps/doorlight/windows/runner" ABSOLUTE)

add_executable(picked_file_staging_test
  "${runner}/picked_file_staging.cpp" "${runner}/picked_file_staging_test.cpp")
target_link_libraries(picked_file_staging_test PRIVATE bcrypt ole32 shell32)

add_executable(window_dismiss_test
  "${runner}/window_dismiss.cpp" "${runner}/window_dismiss_test.cpp")
target_link_libraries(window_dismiss_test PRIVATE gdi32 user32 dwmapi ole32 oleaut32 uiautomationcore)

add_executable(affinity_probe affinity_probe.cpp "${runner}/window_dismiss.cpp")
target_include_directories(affinity_probe PRIVATE "${runner}")
target_link_libraries(affinity_probe PRIVATE gdi32 user32 dwmapi ole32 oleaut32 uiautomationcore)

add_executable(affinity_capture_probe affinity_capture_probe.cpp "${runner}/window_dismiss.cpp")
target_include_directories(affinity_capture_probe PRIVATE "${runner}")
target_link_libraries(affinity_capture_probe PRIVATE gdi32 user32 dwmapi ole32 oleaut32 uiautomationcore)

foreach(target picked_file_staging_test window_dismiss_test affinity_probe affinity_capture_probe)
  target_compile_features(${target} PRIVATE cxx_std_17)
  target_compile_definitions(${target} PRIVATE NOMINMAX UNICODE _UNICODE)
endforeach()
add_test(NAME picked_file_staging_test COMMAND picked_file_staging_test)
add_test(NAME window_dismiss_test COMMAND window_dismiss_test)
set_tests_properties(picked_file_staging_test window_dismiss_test PROPERTIES TIMEOUT 60)
