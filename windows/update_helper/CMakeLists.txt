cmake_minimum_required(VERSION 3.20)
project(update_helper LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(update_helper
  main.cpp
  package_inspector.cpp
)

target_compile_options(update_helper PRIVATE /EHsc /W4 /permissive- /utf-8)
target_compile_definitions(update_helper PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)

# C++/WinRT 投影头文件在 SDK 的 `cppwinrt` 子目录里；VS 的 CMake 工程不会自动加入它。
if(DEFINED WINRT_INCLUDE AND EXISTS "${WINRT_INCLUDE}")
  target_include_directories(update_helper PRIVATE "${WINRT_INCLUDE}")
else()
  file(GLOB _winrt_candidates
    "C:/Program Files (x86)/Windows Kits/10/Include/*/cppwinrt"
    "E:/Windows Kits/10/Include/*/cppwinrt"
  )
  if(_winrt_candidates)
    list(SORT _winrt_candidates)
    list(GET _winrt_candidates -1 _winrt_include)
    target_include_directories(update_helper PRIVATE "${_winrt_include}")
  endif()
endif()

# windowsapp: C++/WinRT 投影的运行时入口；crypt32/wintrust: MSIX 签名与证书链；
# ole32/oleaut32: AppxPackaging 与 ApplicationActivationManager 的 COM。
target_link_libraries(update_helper PRIVATE
  windowsapp
  ole32
  oleaut32
  crypt32
  wintrust
  shlwapi
)

# 独立的构建目标：不并入 Flutter 的 CMake 工程，避免在缺少 Windows SDK 的机器上
# 阻断应用构建。发布流水线会单独构建它并放进 MSIX。
set_target_properties(update_helper PROPERTIES
  OUTPUT_NAME "update_helper"
)
