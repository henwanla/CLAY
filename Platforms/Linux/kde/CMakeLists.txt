cmake_minimum_required(VERSION 3.20)
project(clay-kde-settings LANGUAGES CXX)

find_package(KF6Config QUIET)
if(TARGET KF6::ConfigCore)
    set(config_library KF6::ConfigCore)
else()
    find_package(KF5Config REQUIRED)
    set(config_library KF5::ConfigCore)
endif()

add_executable(clay-kde-settings settings.cpp)
target_compile_features(clay-kde-settings PRIVATE cxx_std_17)
target_link_libraries(clay-kde-settings PRIVATE ${config_library})
