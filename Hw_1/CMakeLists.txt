cmake_minimum_required(VERSION 3.16)
project(hw1_cpu_load LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# cpustat - загрузка по ядрам, threads - N потоков в одном процессе, iowait - ожидание диска
foreach(tool cpustat threads iowait)
    add_executable(${tool} src/${tool}.cpp)
    target_compile_options(${tool} PRIVATE -Wall -Wextra)
endforeach()
