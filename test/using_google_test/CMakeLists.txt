function(create_test testName)
    add_executable(${testName} ${testName}.cpp)
    target_link_libraries(${testName} PRIVATE gtest_main ${PROJECT_NAME}::${${PROJECT_NAME}_LIBRARY_TARGET})
    add_test(NAME ${PROJECT_NAME}.${testName} COMMAND ${testName})
    set_tests_properties(${PROJECT_NAME}.${testName} PROPERTIES TIMEOUT 120)

    # Register for coverage dependencies
    set_property(GLOBAL APPEND PROPERTY ${PROJECT_NAME}_COVERAGE_TESTS ${testName})
endfunction()

create_test(google_test_usage)
