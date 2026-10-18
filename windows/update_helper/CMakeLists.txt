cmake_minimum_required(VERSION 3.20)
project(update_helper LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include("${CMAKE_CURRENT_LIST_DIR}/../native_shared/native_shared.cmake")

add_executable(update_helper
  main.cpp
)

target_compile_options(update_helper PRIVATE /EHsc /W4 /permissive- /utf-8)
target_compile_definitions(update_helper PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)

target_link_libraries(update_helper PRIVATE native_shared)
