cmake_minimum_required(VERSION 3.28)

project(use_installdir_proj
        VERSION 0.0.0
        LANGUAGES CXX)

include(GNUInstallDirs)

list(APPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_LIST_DIR}/cmake)
include(${PROJECT_SOURCE_DIR}/cmake/project_preamble.cmake)
project_preamble()

# Find the installed package. It has no third-party dependencies to re-find.
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

# Bundle the cpplib shared library next to the executable (Windows: bin/, Linux:
# lib/ plus the SONAME symlink, found through the RPATH $ORIGIN/../lib). The
# imported target names the file explicitly; no dependency scanning is involved.
install(IMPORTED_RUNTIME_ARTIFACTS cpplib::cpplib
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
        LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR})
