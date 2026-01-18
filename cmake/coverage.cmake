# Coverage report generation using lcov/genhtml
# This module creates a 'coverage-report' target when coverage is enabled

find_program(LCOV_PATH lcov)
find_program(GENHTML_PATH genhtml)

if(NOT LCOV_PATH)
    message(FATAL_ERROR "Coverage enabled but 'lcov' not found!\n"
            "  Install with: sudo apt install lcov\n"
            "  Or use a non-coverage preset.")
    return()
endif()

if(NOT GENHTML_PATH)
    message(FATAL_ERROR "Coverage enabled but 'genhtml' not found!\n"
            "  Install with: sudo apt install lcov\n"
            "  Or use a non-coverage preset.")
    return()
endif()

message(STATUS "Coverage report generation enabled")
message(STATUS "  lcov: ${LCOV_PATH}")
message(STATUS "  genhtml: ${GENHTML_PATH}")

set(COVERAGE_OUTPUT_DIR "${CMAKE_BINARY_DIR}/coverage_html")
set(COVERAGE_INFO_FILE "${CMAKE_BINARY_DIR}/coverage.info")
set(COVERAGE_INFO_FILTERED "${CMAKE_BINARY_DIR}/coverage_filtered.info")

# Get all registered test targets
# The coverage expects that all relevant tests are part of the list named: <PROJECT_NAME>_COVERAGE_TESTS
# This ensures that the coverage-report target depends on them and they are build and run before generating the report.
get_property(COVERAGE_TEST_TARGETS GLOBAL PROPERTY ${PROJECT_NAME}_COVERAGE_TESTS)

# Create coverage-report target
add_custom_target(coverage-report
    DEPENDS ${COVERAGE_TEST_TARGETS}
    COMMENT "Generating code coverage report..."
    
    # Remove old coverage data
    COMMAND ${CMAKE_COMMAND} -E remove_directory ${COVERAGE_OUTPUT_DIR}
    COMMAND ${CMAKE_COMMAND} -E remove -f ${COVERAGE_INFO_FILE} ${COVERAGE_INFO_FILTERED}
    
    # Reset coverage counters to zero
    COMMAND ${LCOV_PATH}
        --zerocounters
        --directory ${CMAKE_BINARY_DIR}
    
    # Capture baseline coverage (before running tests)
    COMMAND ${LCOV_PATH}
        --capture
        --initial
        --directory ${CMAKE_BINARY_DIR}
        --output-file ${CMAKE_BINARY_DIR}/coverage_base.info
        --rc lcov_branch_coverage=1
        --ignore-errors mismatch
    
    # Run tests to generate coverage data
    COMMAND ${CMAKE_CTEST_COMMAND}
        --output-on-failure
        --no-tests=error
    
    # Capture coverage data (after running tests)
    COMMAND ${LCOV_PATH}
        --capture
        --directory ${CMAKE_BINARY_DIR}
        --output-file ${CMAKE_BINARY_DIR}/coverage_test.info
        --rc lcov_branch_coverage=1
        --ignore-errors mismatch
    
    # Combine baseline and test coverage to include zero-coverage files
    COMMAND ${LCOV_PATH}
        --add-tracefile ${CMAKE_BINARY_DIR}/coverage_base.info
        --add-tracefile ${CMAKE_BINARY_DIR}/coverage_test.info
        --output-file ${COVERAGE_INFO_FILE}
        --rc lcov_branch_coverage=1
        --ignore-errors empty,mismatch
    
    # Filter to keep only project source files (positive filtering)
    COMMAND ${LCOV_PATH}
        --extract ${COVERAGE_INFO_FILE}
        ${CMAKE_SOURCE_DIR}/src/source/*
        ${CMAKE_SOURCE_DIR}/src/include/*
        --output-file ${COVERAGE_INFO_FILTERED}
        --rc lcov_branch_coverage=1
        --ignore-errors empty,unused
    
    # Generate HTML report
    COMMAND ${GENHTML_PATH}
        ${COVERAGE_INFO_FILTERED}
        --output-directory ${COVERAGE_OUTPUT_DIR}
        --title "${PROJECT_NAME} Coverage Report"
        --num-spaces 4
        --legend
        --demangle-cpp
        --rc genhtml_branch_coverage=1
    
    # Display coverage summary in terminal
    COMMAND ${CMAKE_COMMAND} -E echo ""
    COMMAND ${CMAKE_COMMAND} -E echo "======================================"
    COMMAND ${CMAKE_COMMAND} -E echo "Coverage Summary:"
    COMMAND ${CMAKE_COMMAND} -E echo "======================================"
    COMMAND ${LCOV_PATH}
        --summary ${COVERAGE_INFO_FILTERED}
        --rc lcov_branch_coverage=1
    
    # Print summary
    COMMAND ${CMAKE_COMMAND} -E echo ""
    COMMAND ${CMAKE_COMMAND} -E echo "======================================"
    COMMAND ${CMAKE_COMMAND} -E echo "Coverage report generated successfully"
    COMMAND ${CMAKE_COMMAND} -E echo "======================================"
    COMMAND ${CMAKE_COMMAND} -E echo "Report location: ${COVERAGE_OUTPUT_DIR}/index.html"
    COMMAND ${CMAKE_COMMAND} -E echo ""
    COMMAND ${CMAKE_COMMAND} -E echo "To view the report, run:"
    COMMAND ${CMAKE_COMMAND} -E echo "  xdg-open ${COVERAGE_OUTPUT_DIR}/index.html"
    COMMAND ${CMAKE_COMMAND} -E echo ""
    
    WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
    VERBATIM
)
