# test_install consumes the installed library SDK through find_package() from a
# separate project. The SDK is only installed in shared builds. Coverage builds
# skip it by default: coverage-instrumented libraries can't be linked by the
# non-coverage consumer build (undefined gcov symbols).
if (CMAKE_CXX_FLAGS MATCHES "--coverage")
    set(_test_install_default OFF)
else ()
    set(_test_install_default ON)
endif ()
option(${PROJECT_NAME}_TEST_INSTALL "Test consuming the installed cpplib package" ${_test_install_default})

if (${PROJECT_NAME}_TEST_INSTALL AND ${PROJECT_NAME}_INSTALL AND BUILD_SHARED_LIBS)
    add_subdirectory(test_install)
endif ()

# test_delivery checks what the application ships with in the current delivery
# mode (standalone or shared).
if (${PROJECT_NAME}_INSTALL AND ${PROJECT_NAME}_APP)
    add_subdirectory(test_delivery)
endif ()

add_subdirectory(using_google_test)
