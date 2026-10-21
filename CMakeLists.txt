# Builds the DSP core and pedal core on their own, outside Xcode, for tests and
# offline tools.
# The app target in HouseKit.xcodeproj compiles the same sources directly.
cmake_minimum_required(VERSION 3.20)
project(HouseKitDSP CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

set(DSP_DIR ${CMAKE_SOURCE_DIR}/HouseKit/Engine/DSP)
add_library(housekit_dsp STATIC ${DSP_DIR}/Engine.cpp ${DSP_DIR}/Effects.cpp ${DSP_DIR}/Export.cpp ${DSP_DIR}/KitModels.cpp ${DSP_DIR}/Samples.cpp ${DSP_DIR}/Timeline.cpp
            ${DSP_DIR}/Voices.cpp)
target_include_directories(housekit_dsp PUBLIC ${DSP_DIR})
target_compile_options(housekit_dsp PRIVATE -Wall -Wextra -Wpedantic -Werror)

set(PEDAL_DIR ${CMAKE_SOURCE_DIR}/HouseKit/Input/PedalCore)
add_library(housekit_pedal STATIC ${PEDAL_DIR}/PedalCore.cpp)
target_include_directories(housekit_pedal PUBLIC ${PEDAL_DIR})
target_compile_options(housekit_pedal PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_executable(engine_tests Tests/DSP/EngineTests.cpp)
target_link_libraries(engine_tests housekit_dsp)
target_compile_definitions(engine_tests PRIVATE HOUSEKIT_SOURCE_DIR="${CMAKE_SOURCE_DIR}")

add_executable(housekit-render tools/RenderWav.cpp)
target_link_libraries(housekit-render housekit_dsp)

add_executable(pedal_tests Tests/Pedal/PedalTests.cpp)
target_link_libraries(pedal_tests housekit_pedal)

enable_testing()
add_test(NAME engine_tests COMMAND engine_tests)
add_test(NAME pedal_tests COMMAND pedal_tests)

add_executable(housekit-kit-demo tools/KitDemo.cpp)
target_link_libraries(housekit-kit-demo housekit_dsp)
