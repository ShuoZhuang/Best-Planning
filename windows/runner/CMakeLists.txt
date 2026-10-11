cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "timetable_ocr_channel.cpp"
  "tray_icon.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "window_channel.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})
# C++/WinRT async OCR APIs use standard coroutines.
set_target_properties(${BINARY_NAME} PROPERTIES
  CXX_STANDARD 20
  CXX_STANDARD_REQUIRED YES
  CXX_EXTENSIONS NO
)

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
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "windowsapp.lib")
# Shell_NotifyIconW / TrackPopupMenuEx for the notification-area icon.
target_link_libraries(${BINARY_NAME} PRIVATE "shell32.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# ---------------------------------------------------------------------------
# Native tests (1.8.0, task 4).
#
# The notification-area message table is the one piece of the runner that has a
# real, mechanically checkable contract, and the defect it fixes ("left click does
# nothing on some shells") is a missing `case` — invisible to widget tests and
# easy to miss by hand.
#
# The target links **nothing** from Flutter or the engine: it compiles one header
# and one .cpp. That is deliberate, because a test that needs the engine cannot be
# run as a plain build step, and a test nobody runs is not a test.
#
# Off by default so the app build is unchanged; turn it on with
#   cmake --build build/windows/x64 --config Debug \
#         --target tray_icon_message_policy_test
# after configuring with -DPLANNER_BUILD_NATIVE_TESTS=ON.
# ---------------------------------------------------------------------------
option(PLANNER_BUILD_NATIVE_TESTS "Build the runner's native unit tests" OFF)

if(PLANNER_BUILD_NATIVE_TESTS)
  enable_testing()

  add_executable(tray_icon_message_policy_test
    "tray_icon_message_policy_test.cpp"
  )
  target_include_directories(tray_icon_message_policy_test PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
  )
  # Same standard as the runner so the header is compiled identically in both.
  set_target_properties(tray_icon_message_policy_test PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED YES
    CXX_EXTENSIONS NO
  )
  add_test(NAME tray_icon_message_policy COMMAND tray_icon_message_policy_test)
endif()

