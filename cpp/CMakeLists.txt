cmake_minimum_required(VERSION 3.14)
project(kore_signal LANGUAGES CXX)

add_library(kore_signal SHARED
    kore_dsp.cc
    ffi_bindings.cc
)

target_compile_features(kore_signal PUBLIC cxx_std_17)
target_include_directories(kore_signal PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

set_target_properties(kore_signal PROPERTIES
    # Belt. The braces are the KORE_EXPORT macro on each entry point;
    # extern "C" alone exports nothing on MSVC.
    WINDOWS_EXPORT_ALL_SYMBOLS ON
    POSITION_INDEPENDENT_CODE ON
)

if(MSVC)
    # /EHsc is required: the FFI shim uses try/catch to stop exceptions
    # unwinding across the C boundary into Dart.
    #
    # Optimisation level is deliberately NOT set here. CMake supplies it per
    # configuration (/RTC1 /Od for Debug, /O2 for Release), and hardcoding
    # /O2 collides with Debug's /RTC1 - cl.exe rejects the pair outright
    # with D8016.
    target_compile_options(kore_signal PRIVATE /W4 /EHsc)
else()
    # These were previously set globally via CMAKE_CXX_FLAGS, which broke the
    # MSVC build outright - cl.exe rejects -O3 and -fPIC. Keep them here.
    # Likewise let the configuration pick the optimisation level.
    target_compile_options(kore_signal PRIVATE -Wall -Wextra)
    # NOTE: no `target_link_libraries(... c++)`. That is an NDK/libc++ flag;
    # MSVC links its runtime automatically and would fail looking for a
    # library literally named "c++".
    if(ANDROID)
        target_link_libraries(kore_signal PRIVATE c++)
    endif()
endif()
