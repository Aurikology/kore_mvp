cmake_minimum_required(VERSION 3.18.1)
project(kore_signal)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wextra -O3 -fPIC")

# Main library target
add_library(kore_signal SHARED
    signal_filter.cc
    ffi_bindings.cc
)

# Include directories
target_include_directories(kore_signal PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)

# Link against c++ standard library
target_link_libraries(kore_signal PRIVATE c++)
