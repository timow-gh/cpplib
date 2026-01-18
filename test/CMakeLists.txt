# Skip install test when coverage is enabled (coverage-instrumented libraries
# can't be linked by non-coverage builds, causing undefined gcov symbols)
if(NOT CMAKE_CXX_FLAGS MATCHES "--coverage")
    add_subdirectory(test_install)
endif()

add_subdirectory(using_google_test)
