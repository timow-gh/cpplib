# Delivery guardrail: installs exactly what the application package contains and
# checks that
#   - the installed file set is the expected one for the delivery mode,
#   - the installed application runs,
#   - the application (and the library in shared mode) depend on nothing but
#     system libraries, the library itself and, for /MD builds, the app-local
#     MSVC runtime.
# It fails as soon as a third-party library (e.g. fmt) would have to be shipped.
set(app_target ${${PROJECT_NAME}_APP_TARGET})
set(lib_target ${${PROJECT_NAME}_LIBRARY_TARGET})

set(expected_files
        "${CMAKE_INSTALL_BINDIR}/$<TARGET_FILE_NAME:${app_target}>"
        "${CMAKE_INSTALL_DOCDIR}/License")
set(components app)
set(check_files "${CMAKE_INSTALL_BINDIR}/$<TARGET_FILE_NAME:${app_target}>")
set(allowed_regex "")

if (BUILD_SHARED_LIBS)
    list(APPEND components runtime)
    if (WIN32)
        list(APPEND expected_files "${CMAKE_INSTALL_BINDIR}/$<TARGET_FILE_NAME:${lib_target}>")
        list(APPEND check_files "${CMAKE_INSTALL_BINDIR}/$<TARGET_FILE_NAME:${lib_target}>")
    else ()
        list(APPEND expected_files
                "${CMAKE_INSTALL_LIBDIR}/$<TARGET_FILE_NAME:${lib_target}>"
                "${CMAKE_INSTALL_LIBDIR}/$<TARGET_SONAME_FILE_NAME:${lib_target}>")
        list(APPEND check_files "${CMAKE_INSTALL_LIBDIR}/$<TARGET_FILE_NAME:${lib_target}>")
    endif ()
endif ()

if (MSVC AND CMAKE_MSVC_RUNTIME_LIBRARY MATCHES "DLL$")
    # App-local MSVC runtime installed by InstallRequiredSystemLibraries.
    set(allowed_regex "^${CMAKE_INSTALL_BINDIR}/(vcruntime|msvcp|concrt|vccorlib|vcomp)[0-9a-z_]*\\.dll$")
endif ()

# Lists are passed with '|' as separator to survive the add_test() command line.
string(REPLACE ";" "|" components_arg "${components}")
string(REPLACE ";" "|" expected_files_arg "${expected_files}")
string(REPLACE ";" "|" check_files_arg "${check_files}")

add_test(NAME Test${PROJECT_NAME}Delivery
        COMMAND ${CMAKE_COMMAND}
        "-DBUILD_DIR=${PROJECT_BINARY_DIR}"
        "-DCONFIG=$<CONFIG>"
        "-DPREFIX=${CMAKE_CURRENT_BINARY_DIR}/delivery"
        "-DCOMPONENTS=${components_arg}"
        "-DEXPECTED_FILES=${expected_files_arg}"
        "-DALLOWED_REGEX=${allowed_regex}"
        "-DCHECK_FILES=${check_files_arg}"
        "-DAPP=${CMAKE_INSTALL_BINDIR}/$<TARGET_FILE_NAME:${app_target}>"
        -P "${CMAKE_CURRENT_LIST_DIR}/check_delivery.cmake")

set_tests_properties(Test${PROJECT_NAME}Delivery PROPERTIES TIMEOUT 300)
