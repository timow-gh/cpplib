# Coverage report generation using lcov/genhtml
# This module creates a 'coverage-report' target when coverage is enabled

find_program(LCOV_PATH lcov)
find_program(GENHTML_PATH genhtml)
set(GCOV_TOOL "")

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

# Resolve the gcov tool. Prefer an explicit GCOV env var, then a version-matched
# gcov-<major> for GNU builds, then a generic gcov. Mismatched gcov/gcc versions
# are a common cause of "stamp mismatch" errors in lcov, so this matters on CI.
if(DEFINED ENV{GCOV} AND NOT "$ENV{GCOV}" STREQUAL "")
    if(IS_ABSOLUTE "$ENV{GCOV}" AND EXISTS "$ENV{GCOV}")
        set(GCOV_TOOL "$ENV{GCOV}")
    else()
        find_program(GCOV_TOOL NAMES "$ENV{GCOV}")
    endif()
endif()

if(NOT GCOV_TOOL AND CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
    string(REGEX MATCH "^[0-9]+" GCC_MAJOR_VERSION "${CMAKE_CXX_COMPILER_VERSION}")
    if(GCC_MAJOR_VERSION)
        find_program(GCOV_TOOL NAMES gcov-${GCC_MAJOR_VERSION} gcov)
    endif()
endif()

if(NOT GCOV_TOOL)
    find_program(GCOV_TOOL NAMES gcov)
endif()

if(NOT GCOV_TOOL)
    message(FATAL_ERROR "Coverage enabled but 'gcov' not found!\n"
            "  Coverage compiler: ${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION}\n"
            "  Searched for: gcov-${GCC_MAJOR_VERSION}, gcov (and the GCOV env var)\n"
            "  Install the gcov version matching the coverage compiler, or set the GCOV\n"
            "  environment variable to its name/path (e.g. GCOV=gcov-14).")
    return()
endif()

message(STATUS "Coverage report generation enabled")
message(STATUS "  lcov: ${LCOV_PATH}")
message(STATUS "  genhtml: ${GENHTML_PATH}")
message(STATUS "  gcov: ${GCOV_TOOL}")

set(COVERAGE_OUTPUT_DIR "${CMAKE_BINARY_DIR}/coverage_html")
set(COVERAGE_INFO_FILE "${CMAKE_BINARY_DIR}/coverage.info")
set(COVERAGE_INFO_FILTERED "${CMAKE_BINARY_DIR}/coverage_filtered.info")
set(COVERAGE_SOURCE_PATTERNS
    "${PROJECT_SOURCE_DIR}/src/source/*"
    "${PROJECT_SOURCE_DIR}/src/include/*")

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
        --gcov-tool ${GCOV_TOOL}
        --initial
        --directory ${CMAKE_BINARY_DIR}
        --output-file ${CMAKE_BINARY_DIR}/coverage_base.info
        --rc branch_coverage=1
        --ignore-errors mismatch

    # Run tests to generate coverage data
    COMMAND ${CMAKE_CTEST_COMMAND}
        --output-on-failure
        --no-tests=error

    # Capture coverage data (after running tests)
    COMMAND ${LCOV_PATH}
        --capture
        --gcov-tool ${GCOV_TOOL}
        --directory ${CMAKE_BINARY_DIR}
        --output-file ${CMAKE_BINARY_DIR}/coverage_test.info
        --rc branch_coverage=1
        --ignore-errors mismatch

    # Combine baseline and test coverage to include zero-coverage files
    COMMAND ${LCOV_PATH}
        --add-tracefile ${CMAKE_BINARY_DIR}/coverage_base.info
        --add-tracefile ${CMAKE_BINARY_DIR}/coverage_test.info
        --output-file ${COVERAGE_INFO_FILE}
        --rc branch_coverage=1
        --ignore-errors empty,mismatch

    # Filter to keep only project source files (positive filtering)
    COMMAND ${LCOV_PATH}
        --extract ${COVERAGE_INFO_FILE}
        ${COVERAGE_SOURCE_PATTERNS}
        --output-file ${COVERAGE_INFO_FILTERED}
        --rc branch_coverage=1
        --ignore-errors empty,unused

    # Generate HTML report
    COMMAND ${GENHTML_PATH}
        ${COVERAGE_INFO_FILTERED}
        --output-directory ${COVERAGE_OUTPUT_DIR}
        --title "${PROJECT_NAME} Coverage Report"
        --num-spaces 4
        --legend
        --demangle-cpp
        --rc branch_coverage=1

    # Display coverage summary in terminal
    COMMAND ${CMAKE_COMMAND} -E echo ""
    COMMAND ${CMAKE_COMMAND} -E echo "======================================"
    COMMAND ${CMAKE_COMMAND} -E echo "Coverage Summary:"
    COMMAND ${CMAKE_COMMAND} -E echo "======================================"
    COMMAND ${LCOV_PATH}
        --summary ${COVERAGE_INFO_FILTERED}
        --rc branch_coverage=1

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
