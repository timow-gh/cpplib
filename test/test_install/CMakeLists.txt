# Installs the library SDK (components runtime + dev) into a temporary prefix and
# builds a separate consumer project (consumer/) against it with find_package().
#
# The consumer is configured WITHOUT vcpkg and without the presets: it proves
# that the installed package is self-contained (no find_dependency(fmt), no
# third-party DLLs). Compiler, flags and CRT are forwarded from this build so the
# consumer matches it (e.g. sanitizer flags, -stdlib, /MD vs /MT).
set(test_target ${${PROJECT_NAME}_LIBRARY_TARGET})
set(install_dir "${CMAKE_CURRENT_BINARY_DIR}/install_dir")
set(consumer_dir "${CMAKE_CURRENT_BINARY_DIR}/consumer")
set(template_dir "${CMAKE_CURRENT_LIST_DIR}/consumer")

set(consumer_configure_args
        -S "${template_dir}"
        -B "${consumer_dir}/build"
        -G "${CMAKE_GENERATOR}"
        "-DPACKAGE_NAME=${PROJECT_NAME}"
        "-DCMAKE_PREFIX_PATH=${install_dir}"
        "-DCMAKE_BUILD_TYPE=$<CONFIG>"
        "-DCMAKE_CXX_COMPILER=${CMAKE_CXX_COMPILER}"
        "-DCMAKE_CXX_FLAGS=${CMAKE_CXX_FLAGS}"
        "-DCMAKE_EXE_LINKER_FLAGS=${CMAKE_EXE_LINKER_FLAGS}")
if (CMAKE_GENERATOR_PLATFORM)
    list(APPEND consumer_configure_args -A "${CMAKE_GENERATOR_PLATFORM}")
endif ()
if (CMAKE_GENERATOR_TOOLSET)
    list(APPEND consumer_configure_args -T "${CMAKE_GENERATOR_TOOLSET}")
endif ()
if (CMAKE_MAKE_PROGRAM)
    list(APPEND consumer_configure_args "-DCMAKE_MAKE_PROGRAM=${CMAKE_MAKE_PROGRAM}")
endif ()
if (MSVC)
    list(APPEND consumer_configure_args "-DCMAKE_MSVC_RUNTIME_LIBRARY=${CMAKE_MSVC_RUNTIME_LIBRARY}")
endif ()

add_custom_target(test_install
        DEPENDS ${test_target}
        COMMAND ${CMAKE_COMMAND} -E rm -rf "${install_dir}"
        COMMAND ${CMAKE_COMMAND} --install "${PROJECT_BINARY_DIR}" --config $<CONFIG> --prefix "${install_dir}" --component runtime
        COMMAND ${CMAKE_COMMAND} --install "${PROJECT_BINARY_DIR}" --config $<CONFIG> --prefix "${install_dir}" --component dev

        COMMAND ${CMAKE_COMMAND} ${consumer_configure_args}
        COMMAND ${CMAKE_COMMAND} --build "${consumer_dir}/build" --config $<CONFIG> --parallel
        COMMAND ${CMAKE_COMMAND} --install "${consumer_dir}/build" --config $<CONFIG> --prefix "${consumer_dir}/install"

        COMMAND ${CMAKE_COMMAND} -E echo "Running the installed consumer executable..."
        # add_custom_target fails if any command returns a non-zero exit code.
        COMMAND "${consumer_dir}/install/${CMAKE_INSTALL_BINDIR}/consumer$<$<CONFIG:Debug>:d>${CMAKE_EXECUTABLE_SUFFIX}"
        COMMAND ${CMAKE_COMMAND} -E echo "Installation test PASSED: Executable ran successfully"
        VERBATIM
)

add_custom_target(test_install_clean
        COMMAND ${CMAKE_COMMAND} -E rm -rf "${install_dir}" "${consumer_dir}"
        VERBATIM
)

add_test(NAME Test${PROJECT_NAME}Install
        COMMAND ${CMAKE_COMMAND} --build "${CMAKE_BINARY_DIR}" --target test_install --config $<CONFIG>)

# Guardrail: this test drives a nested configure/build. If it stalls, fail
# deterministically instead of hanging the whole CI job until the runner-level timeout.
set_tests_properties(Test${PROJECT_NAME}Install PROPERTIES TIMEOUT 600)
