# A separate project that uses the installed library SDK, the way any other
# project would. It doubles as the example in ReadMe.md ("Using the library from
# another project"). The package name is passed in by test/test_install, so this
# file does not repeat it.
cmake_minimum_required(VERSION 3.28)

project(consumer LANGUAGES CXX)

if (NOT PACKAGE_NAME)
    message(FATAL_ERROR "Pass the name of the installed package: -DPACKAGE_NAME=<name>")
endif ()

include(GNUInstallDirs)

# Find the installed package. It has no third-party dependencies to re-find.
find_package(${PACKAGE_NAME} CONFIG REQUIRED)

add_executable(consumer main.cpp)
target_link_libraries(consumer PRIVATE ${PACKAGE_NAME}::${PACKAGE_NAME})
target_compile_features(consumer PRIVATE cxx_std_23)
set_target_properties(consumer PROPERTIES
        DEBUG_POSTFIX d
        # Linux: find the bundled shared library relative to the executable.
        INSTALL_RPATH "$ORIGIN/../${CMAKE_INSTALL_LIBDIR}")

install(TARGETS consumer
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

# Bundle the shared library next to the executable (Windows: bin/, Linux: lib/
# plus the SONAME symlink). The imported target names the file explicitly; no
# dependency scanning is involved.
install(IMPORTED_RUNTIME_ARTIFACTS ${PACKAGE_NAME}::${PACKAGE_NAME}
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
        LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR})
