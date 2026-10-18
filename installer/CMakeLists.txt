cmake_minimum_required(VERSION 3.20)
project(best_planning_setup LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include("${CMAKE_CURRENT_LIST_DIR}/../windows/native_shared/native_shared.cmake")

# 版本只从构建参数进入资源，不在 .rc 里手写第二份（规格 §7.2、§14.3）。
if(NOT DEFINED APPSETUP_VERSION_MAJOR)
  set(APPSETUP_VERSION_MAJOR 1)
endif()
if(NOT DEFINED APPSETUP_VERSION_MINOR)
  set(APPSETUP_VERSION_MINOR 10)
endif()
if(NOT DEFINED APPSETUP_VERSION_PATCH)
  set(APPSETUP_VERSION_PATCH 0)
endif()
if(NOT DEFINED APPSETUP_VERSION_BUILD)
  set(APPSETUP_VERSION_BUILD 47)
endif()
if(NOT DEFINED APPSETUP_VERSION_TEXT)
  set(APPSETUP_VERSION_TEXT "1.10.0+47")
endif()

configure_file(
  "${CMAKE_CURRENT_LIST_DIR}/resources/version.h.in"
  "${CMAKE_CURRENT_BINARY_DIR}/version_generated.h"
  @ONLY)

add_library(installer_core STATIC
  src/application_launcher.cpp
  src/certificate_manager.cpp
  src/elevation_broker.cpp
  src/installer_controller.cpp
  src/installer_errors.cpp
  src/installer_log.cpp
  src/installer_state_machine.cpp
  src/installer_ui.cpp
  src/package_deployer.cpp
  src/package_verifier.cpp
  src/payload_metadata.cpp
  src/payload_reader.cpp
  src/secure_session.cpp
)

target_include_directories(installer_core PUBLIC
  "${CMAKE_CURRENT_LIST_DIR}/include"
  "${CMAKE_CURRENT_BINARY_DIR}")
target_compile_options(installer_core PRIVATE /EHsc /W4 /permissive- /utf-8)
target_compile_definitions(installer_core PUBLIC
  UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_link_libraries(installer_core PUBLIC
  native_shared
  comctl32
  shell32
  advapi32
)

add_executable(BestPlanningSetup WIN32
  src/main.cpp
  resources/installer.rc)
target_link_libraries(BestPlanningSetup PRIVATE installer_core)
target_compile_options(BestPlanningSetup PRIVATE /EHsc /W4 /permissive- /utf-8)
# 清单由 installer.rc 显式嵌入；禁用链接器的自动清单，避免 MANIFEST 资源重复。
target_link_options(BestPlanningSetup PRIVATE /MANIFEST:NO)
set_target_properties(BestPlanningSetup PROPERTIES OUTPUT_NAME "BestPlanningSetup")

# 单元测试可执行文件：与发布二进制共用同一份核心代码。
add_executable(installer_tests
  tests/test_main.cpp
  tests/state_machine_test.cpp
  tests/version_policy_test.cpp
  tests/payload_verifier_test.cpp
  tests/certificate_policy_test.cpp
  tests/error_mapping_test.cpp
)
target_link_libraries(installer_tests PRIVATE installer_core)
target_compile_options(installer_tests PRIVATE /EHsc /W4 /permissive- /utf-8)

# 发布工具：把最终 MSIX、公开证书与元数据写入 Setup EXE 的只读资源。
add_executable(embed_payload tools/embed_payload.cpp)
target_include_directories(embed_payload PRIVATE "${CMAKE_CURRENT_LIST_DIR}/include")
target_link_libraries(embed_payload PRIVATE native_shared)
target_compile_options(embed_payload PRIVATE /EHsc /W4 /permissive- /utf-8)
