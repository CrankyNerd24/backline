# Builds the DSP core on its own, outside Xcode, for tests and offline tools.
# The app target in Backline.xcodeproj compiles the same sources directly.
cmake_minimum_required(VERSION 3.20)
project(BacklineDSP CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

set(DSP_DIR ${CMAKE_SOURCE_DIR}/Backline/Engine/DSP)
add_library(backline_dsp STATIC ${DSP_DIR}/Engine.cpp ${DSP_DIR}/Voices.cpp)
target_include_directories(backline_dsp PUBLIC ${DSP_DIR})
target_compile_options(backline_dsp PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_executable(engine_tests Tests/DSP/EngineTests.cpp)
target_link_libraries(engine_tests backline_dsp)

add_executable(backline-render tools/RenderWav.cpp)
target_link_libraries(backline-render backline_dsp)

enable_testing()
add_test(NAME engine_tests COMMAND engine_tests)
