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
    # NOTE: nothing links the C++ runtime by name here. Naming it `c++`
    # resolves to whatever ANDROID_STL selects, which under NDK 28's default
    # is the *shared* runtime - and `libc++_shared.so` is not packaged into
    # the APK, so the library built, shipped, and then failed `dlopen` at
    # every launch. The runtime is chosen once, in
    # `android/app/build.gradle.kts`, as `c++_static`; the NDK toolchain links
    # it from there and this file stays out of it. MSVC links its own runtime
    # automatically and would fail looking for a library literally named
    # "c++", which is why this was never in the MSVC branch.
endif()
