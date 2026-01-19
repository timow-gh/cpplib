cmake_minimum_required(VERSION 3.28)

project(use_installdir_proj
        VERSION 0.0.0
        LANGUAGES CXX)

include(GNUInstallDirs)

list(APPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_LIST_DIR}/cmake)
include(${PROJECT_SOURCE_DIR}/cmake/project_preamble.cmake)
project_preamble()

# Find the installed package
find_package(cpplib CONFIG REQUIRED)

# Create executable
add_executable(use_installdir main.cpp)
target_link_libraries(use_installdir PRIVATE cpplib::cpplib)

set_target_properties(use_installdir
        PROPERTIES
        DEBUG_POSTFIX d
        CXX_STANDARD 20
        CXX_STANDARD_REQUIRED ON
        CXX_EXTENSIONS OFF)

# Install executable
install(TARGETS use_installdir
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

# Install the cpplib shared library that the executable depends on
file(GLOB CPPLIB_LIBS "${CMAKE_PREFIX_PATH}/lib/libcpplib*.so*")
if(CPPLIB_LIBS)
    install(FILES ${CPPLIB_LIBS}
            DESTINATION ${CMAKE_INSTALL_LIBDIR})
endif()