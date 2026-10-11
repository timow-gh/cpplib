cmake_minimum_required(VERSION 3.28)

list(APPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_LIST_DIR}/cmake)

include(detect_ninja)

# No C++20/23 modules are used; disable scanning to avoid clang-scan-deps
# lookup during compiler detection (project()) and the GCC + CMake 3.28
# incompatibility where -MD and -fdeps-format=p1689r5 are passed together.
set(CMAKE_CXX_SCAN_FOR_MODULES OFF)

include(cmake/CPM.cmake)
if (NOT CPM_SOURCE_CACHE AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/CPMSourceVariable.cmake")
    include(CPMSourceVariable.cmake)
endif ()

if (NOT CPM_SOURCE_CACHE)
    message(AUTHOR_WARNING "CPM_SOURCE_CACHE not set. The source files are downloaded for every build. This is not recommended.
        Set the CPM_SOURCE_CACHE variable to a directory of your choice to cache the cloned git repositories.
        Set the CPM_SOURCE_CACHE variable in CPMSourceVariable.cmake to keep your paths private.")
endif ()

project(cpplib
        VERSION 0.1.0
        DESCRIPTION "A C++ library and application template"
        HOMEPAGE_URL "https://github.com/timow-gh/cpplib"
        LANGUAGES CXX)

# Every name of this project is derived from the project name: targets, CMake
# package, export macro, test names, package names, installer folder.
set(${PROJECT_NAME}_LIBRARY_TARGET ${PROJECT_NAME})
set(${PROJECT_NAME}_APP_TARGET ${PROJECT_NAME}_app)

include(warnings)
include(static_analysis)

# Set common properties for cross platform builds when this is the root project.
if (PROJECT_IS_TOP_LEVEL)
    include(project_preamble)
    project_preamble()
endif ()

include(GNUInstallDirs)

if (PROJECT_IS_TOP_LEVEL)
    option(${PROJECT_NAME}_USE_SCCACHE "Use sccache" OFF)
    option(${PROJECT_NAME}_USE_WARNINGS "Compile using warnings." ON)
    option(${PROJECT_NAME}_WARNINGS_AS_ERRORS "Treat compiler warnings as errors " ON)
    option(${PROJECT_NAME}_STATIC_ANALYSIS "" ON)
    option(${PROJECT_NAME}_USE_CPPCHECK "" OFF)
    option(${PROJECT_NAME}_TESTS "" ON)
    option(${PROJECT_NAME}_APP "Build the ${PROJECT_NAME}_app application" ON)
    option(${PROJECT_NAME}_PACK "Create release packages" ON)
else ()
    option(${PROJECT_NAME}_USE_SCCACHE "Use sccache" OFF)
    option(${PROJECT_NAME}_USE_WARNINGS "Compile using warnings." OFF)
    option(${PROJECT_NAME}_WARNINGS_AS_ERRORS "Treat compiler warnings as errors" OFF)
    option(${PROJECT_NAME}_STATIC_ANALYSIS "" OFF)
    option(${PROJECT_NAME}_USE_CPPCHECK "" OFF)
    option(${PROJECT_NAME}_TESTS "" OFF)
    option(${PROJECT_NAME}_APP "Build the ${PROJECT_NAME}_app application" OFF)
    option(${PROJECT_NAME}_PACK "Create release packages" OFF)
endif ()

if (PROJECT_IS_TOP_LEVEL)
    set(${PROJECT_NAME}_INSTALL_DEFAULT ON)
else ()
    set(${PROJECT_NAME}_INSTALL_DEFAULT OFF)
endif ()
option(${PROJECT_NAME}_INSTALL "Install project targets" ${${PROJECT_NAME}_INSTALL_DEFAULT})
option(${PROJECT_NAME}_BUILD_DOCUMENTATION "Build API documentation with Doxygen" OFF)

if (${PROJECT_NAME}_USE_SCCACHE)
    include(setup_sccache)
    enable_sccache()
endif ()

if (${PROJECT_NAME}_USE_CPPCHECK)
    include(cppcheck)
    create_cppcheck_target(${TARGET_NAME})
endif ()

if (${PROJECT_NAME}_BUILD_DOCUMENTATION)
    include(setup_doxygen)
    enable_doxygen()
endif ()

# MSVC runtime library (CRT). Every target and every vcpkg dependency must use the
# same CRT, otherwise linking fails with LNK2038. The vcpkg triplet chosen by the
# preset decides:
#   x64-windows-static    -> static CRT  (/MT): standalone builds, one .exe
#   x64-windows-static-md -> dynamic CRT (/MD): shared builds, .exe + library DLL
#                            + app-local vcruntime140/msvcp140 (see app/CMakeLists.txt)
# Both triplets build the third-party libraries themselves as static libraries.
# Must be set before any targets are created.
if (MSVC AND NOT DEFINED CMAKE_MSVC_RUNTIME_LIBRARY)
    if (VCPKG_TARGET_TRIPLET MATCHES "-static$")
        set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
        if (BUILD_SHARED_LIBS)
            message(AUTHOR_WARNING "Shared build with the static CRT (${VCPKG_TARGET_TRIPLET}): every DLL gets its own "
                    "CRT heap. Use the x64-windows-static-md triplet (the *-shared presets) for shared builds.")
        endif ()
    else ()
        set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")
    endif ()
endif ()

add_subdirectory(dependencies)

add_subdirectory(src)

if (${PROJECT_NAME}_APP)
    add_subdirectory(app)
endif ()

if (${PROJECT_NAME}_TESTS)
    include(CTest)
    enable_testing()
    add_subdirectory(test)

    # Include coverage report generation if coverage flags are enabled
    if(CMAKE_CXX_FLAGS MATCHES "--coverage")
        message(STATUS "Coverage enabled - adding coverage-report target")
        include(${PROJECT_SOURCE_DIR}/cmake/coverage.cmake)
    endif()
endif ()

if (${PROJECT_NAME}_INSTALL)
    # The license ships with everything this project delivers. In static builds the
    # library SDK is not installed, so it goes with the application component.
    if (BUILD_SHARED_LIBS)
        set(_license_component runtime)
    else ()
        set(_license_component app)
    endif ()
    install(FILES "${PROJECT_SOURCE_DIR}/License"
            DESTINATION "${CMAKE_INSTALL_DOCDIR}"
            COMPONENT ${_license_component})

    if (${PROJECT_NAME}_PACK)
        include(cmake/packaging.cmake)
    endif ()
endif()
