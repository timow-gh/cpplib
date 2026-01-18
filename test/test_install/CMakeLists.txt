set(test_target "cpplib")
set(${test_target}_TEST_INSTALL_DIR "${CMAKE_CURRENT_BINARY_DIR}/${test_target}_install_dir")
set(${test_target}_TEST_SOURCE_DIR "${CMAKE_CURRENT_BINARY_DIR}/${test_target}_use_install_test")
set(${test_target}_TEMPLATE_PROJECT_DIR_NAME "${test_target}_install_test_template")

set(PRESET "")
if (MSVC)
    set(PRESET "conf-windows-msvc")
elseif ("${CMAKE_CXX_COMPILER_ID}" STREQUAL "Clang")
    set(PRESET "conf-unixlike-clang")
elseif ("${CMAKE_CXX_COMPILER_ID}" STREQUAL "GNU")
    set(PRESET "conf-unixlike-gcc")
else ()
    message(AUTHOR_WARNING "Unsupported compiler")
endif ()

string(TOLOWER "${CMAKE_BUILD_TYPE}" CONFIG_LOWER)
set(PRESET "${PRESET}-${CONFIG_LOWER}")

# Detect if sanitizers are enabled and adjust preset accordingly
if(CMAKE_CXX_FLAGS MATCHES "-fsanitize=address" OR CMAKE_EXE_LINKER_FLAGS MATCHES "-fsanitize=address")
    set(PRESET "${PRESET}-asan")
    message(STATUS "Detected AddressSanitizer, using preset: ${PRESET}")
elseif(CMAKE_CXX_FLAGS MATCHES "-fsanitize=thread" OR CMAKE_EXE_LINKER_FLAGS MATCHES "-fsanitize=thread")
    set(PRESET "${PRESET}-tsan")
    message(STATUS "Detected ThreadSanitizer, using preset: ${PRESET}")
elseif(CMAKE_CXX_FLAGS MATCHES "-fsanitize=undefined" OR CMAKE_EXE_LINKER_FLAGS MATCHES "-fsanitize=undefined")
    set(PRESET "${PRESET}-ubsan")
    message(STATUS "Detected UndefinedBehaviorSanitizer, using preset: ${PRESET}")
endif()

set(EXE_POSTFIX "")
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    set(EXE_POSTFIX "d")
endif()

message(STATUS "Using preset: ${PRESET}")

# Check if the test template project directory exists
if (NOT EXISTS "${CMAKE_CURRENT_LIST_DIR}/${${test_target}_TEMPLATE_PROJECT_DIR_NAME}/CMakeLists.txt")
    message(FATAL_ERROR "The test template project directory '${${test_target}_TEMPLATE_PROJECT_DIR_NAME}' does not exist or is missing a CMakeLists.txt file.")
    return()
endif ()

if(NOT CMAKE_BUILD_TYPE)
    message(FATAL_ERROR "CMAKE_BUILD_TYPE must be set for test_install target")
endif()

add_custom_target(test_install
        DEPENDS ${test_target}
        COMMAND ${CMAKE_COMMAND} --install ${PROJECT_BINARY_DIR} --config ${CMAKE_BUILD_TYPE} --prefix ${${test_target}_TEST_INSTALL_DIR}

        COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_LIST_DIR}/${${test_target}_TEMPLATE_PROJECT_DIR_NAME}"
        ${${test_target}_TEST_SOURCE_DIR}

        # Copy the main project's CMakePresets.json to ensure identical configuration
        COMMAND ${CMAKE_COMMAND} -E copy
        "${PROJECT_SOURCE_DIR}/CMakePresets.json"
        "${${test_target}_TEST_SOURCE_DIR}/CMakePresets.json"

        COMMAND ${CMAKE_COMMAND}
        -B ${${test_target}_TEST_SOURCE_DIR}/build
        -S ${${test_target}_TEST_SOURCE_DIR}
        --preset "${PRESET}"
        -DCMAKE_PREFIX_PATH=${${test_target}_TEST_INSTALL_DIR}

        COMMAND ${CMAKE_COMMAND}
        --build ${${test_target}_TEST_SOURCE_DIR}/build
        --config ${CMAKE_BUILD_TYPE}
        --parallel

        COMMAND ${CMAKE_COMMAND}
        --install ${${test_target}_TEST_SOURCE_DIR}/build
        --config ${CMAKE_BUILD_TYPE}
        --prefix ${${test_target}_TEST_SOURCE_DIR}/install

        COMMAND ${CMAKE_COMMAND}
        -E echo "Running the installed test executable..."

        COMMAND ${${test_target}_TEST_SOURCE_DIR}/install/bin/use_installdir${EXE_POSTFIX}
        
        # Check the return code of the executable is 1 as a proxy for success of using the installed project. 
        # add_custom_target will fail if any command returns a non-zero exit code.
        COMMAND ${CMAKE_COMMAND}
        -E echo "Installation test PASSED: Executable ran successfully"
)

add_custom_target(test_install_clean
        ${CMAKE_COMMAND} -E rm -Rf ${${test_target}_TEST_INSTALL_DIR}
        COMMAND ${CMAKE_COMMAND} -E rm -Rf ${${test_target}_TEST_SOURCE_DIR}
)

add_test(NAME TestcpplibInstall COMMAND ${CMAKE_COMMAND} --build . --target test_install)
