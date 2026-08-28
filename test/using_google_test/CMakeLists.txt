function(create_test testName)
    add_executable(${testName} ${testName}.cpp)
    target_link_libraries(${testName} PRIVATE gtest_main ${PROJECT_NAME}::cpplib)
    add_test(NAME cpplib.${testName} COMMAND ${testName})
    set_tests_properties(cpplib.${testName} PROPERTIES TIMEOUT 120)

    # Register for coverage dependencies
    set_property(GLOBAL APPEND PROPERTY ${PROJECT_NAME}_COVERAGE_TESTS ${testName})
endfunction()

create_test(google_test_usage)
