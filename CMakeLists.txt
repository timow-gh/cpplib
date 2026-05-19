cmake_minimum_required(VERSION 3.28)

list(APPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_LIST_DIR}/cmake)

include(cmake/CPM.cmake)
if (NOT CPM_SOURCE_CACHE AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/CPMSourceVariable.cmake")
    include(CPMSourceVariable.cmake)
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

if (PROJECT_IS_TOP_LEVEL)
    option(${PROJECT_NAME}_USE_WARNINGS "Compile using warnings." ON)
    option(${PROJECT_NAME}_WARNINGS_AS_ERRORS "Treat compiler warnings as errors " ON)
    option(${PROJECT_NAME}_STATIC_ANALYSIS "" ON)
    option(${PROJECT_NAME}_USE_CPPCHECK "" OFF)
    option(${PROJECT_NAME}_TESTS "" ON)
else ()
    option(${PROJECT_NAME}_USE_WARNINGS "Compile using warnings." OFF)
    option(${PROJECT_NAME}_WARNINGS_AS_ERRORS "Treat compiler warnings as errors" OFF)
    option(${PROJECT_NAME}_STATIC_ANALYSIS "" OFF)
    option(${PROJECT_NAME}_USE_CPPCHECK "" OFF)
    option(${PROJECT_NAME}_TESTS "" OFF)
endif ()

if (PROJECT_IS_TOP_LEVEL)
    set(${PROJECT_NAME}_INSTALL_DEFAULT ON)
else ()
    set(${PROJECT_NAME}_INSTALL_DEFAULT OFF)
endif ()
option(${PROJECT_NAME}_INSTALL "Install project targets" ${${PROJECT_NAME}_INSTALL_DEFAULT})

if (${PROJECT_NAME}_USE_CPPCHECK)
    include(cppcheck)
    create_cppcheck_target(${TARGET_NAME})
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
    include(cmake/packaging.cmake)
endif()
