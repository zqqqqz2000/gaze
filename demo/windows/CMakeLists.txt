cmake_minimum_required(VERSION 3.20)

project(GazeWinHost LANGUAGES CXX)

add_executable(GazeWinHost
    GazeWinHost.cpp
)

target_compile_features(GazeWinHost PRIVATE cxx_std_17)
target_include_directories(GazeWinHost PRIVATE
    ../../core/include
)

if(WIN32)
    target_link_libraries(GazeWinHost PRIVATE ws2_32 gdiplus)
else()
    message(FATAL_ERROR "GazeWinHost is a Windows-only demo and requires WinSock2.")
endif()
