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
        # In the install tree the SONAME entry (TARGET_SONAME_FILE) is a *symlink*
        # to the real, fully versioned file (TARGET_FILE, e.g. libcpplib.so.0.0.0).
        # install(FILES) copies a symlink argument verbatim as a symlink, so
        # installing only TARGET_SONAME_FILE leaves a dangling link and the loader
        # fails with "cannot open shared object file". Install the real file *and*
        # recreate the SONAME symlink next to it so RPATH ($ORIGIN/../lib) resolves
        # to an actual ELF at runtime.
        install(FILES $<TARGET_FILE:cpplib::cpplib>
                DESTINATION ${CMAKE_INSTALL_LIBDIR})

        # Recreate the SONAME -> real-file symlink in the install tree, but only
        # when they differ (they are identical for an unversioned library).
        install(CODE "
            set(_real \"$<TARGET_FILE_NAME:cpplib::cpplib>\")
            set(_soname \"$<TARGET_SONAME_FILE_NAME:cpplib::cpplib>\")
            if(NOT _real STREQUAL _soname)
                file(CREATE_LINK \"\${_real}\" \"\${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_LIBDIR}/\${_soname}\" SYMBOLIC)
            endif()
        ")
    endif()
endif()
# For a static cpplib there is no runtime library to bundle; nothing to do.