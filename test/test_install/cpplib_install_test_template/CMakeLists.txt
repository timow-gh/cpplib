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
        CXX_STANDARD 23
        CXX_STANDARD_REQUIRED ON
        CXX_EXTENSIONS OFF)

# Install executable
install(TARGETS use_installdir
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

# Bundle the cpplib shared library the executable depends on, so the installed
# consumer is runnable via its RPATH ($ORIGIN/../lib). Resolve the ACTUAL file
# from the imported target instead of globbing CMAKE_PREFIX_PATH, which is
# unreliable when the vcpkg toolchain adds extra prefix-path entries.
get_target_property(_cpplib_type cpplib::cpplib TYPE)

if(_cpplib_type STREQUAL "SHARED_LIBRARY")
    if(MSVC)
        # On Windows the runtime artifact is the DLL, resolved from the imported target.
        install(FILES $<TARGET_FILE:cpplib::cpplib>
                DESTINATION ${CMAKE_INSTALL_BINDIR})
    else()
        # On ELF/Mach-O the loader looks up the SONAME (e.g. libcpplib.so.0).
        # TARGET_SONAME_FILE resolves to exactly that name; install(FILES) follows
        # the symlink and writes a real file under the SONAME basename, which is
        # what the RPATH ($ORIGIN/../lib) needs at runtime.
        install(FILES $<TARGET_SONAME_FILE:cpplib::cpplib>
                DESTINATION ${CMAKE_INSTALL_LIBDIR})
    endif()
endif()
# For a static cpplib there is no runtime library to bundle; nothing to do.