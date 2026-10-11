# The application is an ordinary target of this project: it links cpplib through
# its alias target, and nothing has to be installed to build or run it.
#
# How it ships depends on the configure preset:
#   *-standalone (BUILD_SHARED_LIBS=OFF): cpplib and fmt are linked statically,
#       the package contains only the executable.
#   *-shared     (BUILD_SHARED_LIBS=ON):  the package contains the executable,
#       cpplib.dll / libcpplib.so (component "runtime", installed by
#       src/CMakeLists.txt) and, on Windows, the app-local MSVC runtime DLLs.
set(TARGET_NAME ${${PROJECT_NAME}_APP_TARGET})

add_executable(${TARGET_NAME} main.cpp)

target_link_libraries(${TARGET_NAME} PRIVATE ${PROJECT_NAME}::${${PROJECT_NAME}_LIBRARY_TARGET})

target_compile_features(${TARGET_NAME} PRIVATE cxx_std_23)

if (DEFINED ${PROJECT_NAME}_USE_WARNINGS AND ${PROJECT_NAME}_USE_WARNINGS)
    add_warnings_and_compile_options(${TARGET_NAME} "${${PROJECT_NAME}_WARNINGS_AS_ERRORS}")
endif ()

if (DEFINED ${PROJECT_NAME}_STATIC_ANALYSIS AND ${PROJECT_NAME}_STATIC_ANALYSIS)
    enable_static_analysis(${TARGET_NAME} "${${PROJECT_NAME}_WARNINGS_AS_ERRORS}")
endif ()

# Running from the build tree needs no extra steps: on Windows project_preamble()
# puts executables and DLLs into the same output directory, on Linux the build
# RPATH points at libcpplib.so. The install RPATH ($ORIGIN/../lib) is set by
# project_preamble() as well.

if (${PROJECT_NAME}_INSTALL)
    install(TARGETS ${TARGET_NAME}
            RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
            COMPONENT app)

    # Dynamic MSVC runtime (/MD, x64-windows-static-md triplet): ship
    # vcruntime140.dll, msvcp140.dll, ... next to the executable (app-local
    # deployment), so no Visual C++ Redistributable has to be installed. The UCRT
    # is part of Windows 10 and later and is not shipped.
    if (MSVC AND CMAKE_MSVC_RUNTIME_LIBRARY MATCHES "DLL$")
        set(CMAKE_INSTALL_SYSTEM_RUNTIME_DESTINATION ${CMAKE_INSTALL_BINDIR})
        set(CMAKE_INSTALL_SYSTEM_RUNTIME_COMPONENT app)
        include(InstallRequiredSystemLibraries)
    endif ()
endif ()
