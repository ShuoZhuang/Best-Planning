# 共享原生库的构建描述（被 update_helper 与 installer 共同 include）。
#
# 不单独作为顶层工程：每个使用方把它编进自己的构建目录，避免在缺少 Windows SDK
# 的机器上阻断 Flutter 应用构建。

set(NATIVE_SHARED_ROOT "${CMAKE_CURRENT_LIST_DIR}")

add_library(native_shared STATIC
  "${NATIVE_SHARED_ROOT}/src/deployment_errors.cpp"
  "${NATIVE_SHARED_ROOT}/src/package_deployment.cpp"
  "${NATIVE_SHARED_ROOT}/src/package_inspector.cpp"
  "${NATIVE_SHARED_ROOT}/src/planner_identity.cpp"
  "${NATIVE_SHARED_ROOT}/src/text.cpp"
  "${NATIVE_SHARED_ROOT}/src/zip_reader.cpp"
)

target_include_directories(native_shared PUBLIC "${NATIVE_SHARED_ROOT}/include")
target_compile_features(native_shared PUBLIC cxx_std_20)
target_compile_options(native_shared PRIVATE /EHsc /W4 /permissive- /utf-8)
target_compile_definitions(native_shared PUBLIC
  UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)

# C++/WinRT 投影头文件在 SDK 的 `cppwinrt` 子目录里；VS 的 CMake 工程不会自动加入它。
if(DEFINED WINRT_INCLUDE AND EXISTS "${WINRT_INCLUDE}")
  target_include_directories(native_shared PUBLIC "${WINRT_INCLUDE}")
else()
  file(GLOB _winrt_candidates
    "C:/Program Files (x86)/Windows Kits/10/Include/*/cppwinrt"
    "E:/Windows Kits/10/Include/*/cppwinrt"
  )
  if(_winrt_candidates)
    list(SORT _winrt_candidates)
    list(GET _winrt_candidates -1 _winrt_include)
    target_include_directories(native_shared PUBLIC "${_winrt_include}")
  endif()
endif()

# windowsapp: C++/WinRT 运行时；crypt32/wintrust: MSIX 签名与证书链；
# ole32/oleaut32: AppxPackaging 与 ApplicationActivationManager 的 COM；
# bcrypt: SHA-256；shlwapi: 流式打开包文件。
target_link_libraries(native_shared PUBLIC
  windowsapp
  ole32
  oleaut32
  crypt32
  wintrust
  bcrypt
  shlwapi
)
