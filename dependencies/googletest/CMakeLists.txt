# googletest is a test-only dependency: it is never installed (INSTALL_GTEST OFF)
# and never shipped, so it must not inherit the project's BUILD_SHARED_LIBS. Build
# it static regardless. On Windows the MSVC presets force the static CRT
# (CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded[Debug], see the root CMakeLists.txt),
# so gtest_force_shared_crt stays OFF to match. Building gtest as DLLs against the
# static CRT gives each module its own CRT global state, which deadlocks gtest at
# startup on the shared Windows CI build (BUILD_SHARED_LIBS=ON) and hangs the test.
CPMAddPackage(
        NAME googletest
        GITHUB_REPOSITORY google/googletest
        GIT_TAG release-1.12.1
        GIT_SHALLOW TRUE
        OPTIONS
            "INSTALL_GTEST OFF"
            "BUILD_SHARED_LIBS OFF"
            "gtest_force_shared_crt OFF"
)

if(googletest_ADDED)
    if ("${CMAKE_CXX_COMPILER_ID}" STREQUAL "Clang")
        target_compile_options(gtest_main INTERFACE
                "-Wno-weak-vtables"
                )
    endif ()
endif()