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
        VERSION 0.0.0
        LANGUAGES CXX)

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
    option(${PROJECT_NAME}_PACK "Create release packages" ON)
else ()
    option(${PROJECT_NAME}_USE_SCCACHE "Use sccache" OFF)
    option(${PROJECT_NAME}_USE_WARNINGS "Compile using warnings." OFF)
    option(${PROJECT_NAME}_WARNINGS_AS_ERRORS "Treat compiler warnings as errors" OFF)
    option(${PROJECT_NAME}_STATIC_ANALYSIS "" OFF)
    option(${PROJECT_NAME}_USE_CPPCHECK "" OFF)
    option(${PROJECT_NAME}_TESTS "" OFF)
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

# The MSVC presets use the x64-windows-static vcpkg triplet, which builds
# dependencies (e.g. fmt) against the static CRT. Match that here so cpplib and
# its dependencies agree on the runtime library and link cleanly. Must be set
# before any targets are created.
if (MSVC AND VCPKG_TARGET_TRIPLET MATCHES "-static")
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif ()

add_subdirectory(dependencies)

add_subdirectory(src)

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
    if (${PROJECT_NAME}_PACK)
        include(cmake/packaging.cmake)
    endif ()
endif()
