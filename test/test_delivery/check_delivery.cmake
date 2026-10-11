# Script mode (cmake -P), see CMakeLists.txt in this directory for the arguments.
cmake_minimum_required(VERSION 3.28)

foreach (var BUILD_DIR CONFIG PREFIX COMPONENTS EXPECTED_FILES CHECK_FILES APP)
    if (NOT DEFINED ${var} OR "${${var}}" STREQUAL "")
        message(FATAL_ERROR "check_delivery.cmake: ${var} is not set")
    endif ()
endforeach ()
string(REPLACE "|" ";" COMPONENTS "${COMPONENTS}")
string(REPLACE "|" ";" EXPECTED_FILES "${EXPECTED_FILES}")
string(REPLACE "|" ";" CHECK_FILES "${CHECK_FILES}")

# 1. Install the components the application package consists of.
file(REMOVE_RECURSE "${PREFIX}")
foreach (component IN LISTS COMPONENTS)
    execute_process(
            COMMAND "${CMAKE_COMMAND}" --install "${BUILD_DIR}" --config "${CONFIG}"
                    --prefix "${PREFIX}" --component "${component}"
            RESULT_VARIABLE result)
    if (NOT result EQUAL 0)
        message(FATAL_ERROR "Installing component '${component}' failed")
    endif ()
endforeach ()

# 2. The installed file set must match exactly (plus explicitly allowed extras).
file(GLOB_RECURSE installed LIST_DIRECTORIES false RELATIVE "${PREFIX}" "${PREFIX}/*")
list(SORT installed)
set(errors "")
foreach (file IN LISTS installed)
    if (file IN_LIST EXPECTED_FILES)
        continue()
    endif ()
    if (NOT "${ALLOWED_REGEX}" STREQUAL "" AND file MATCHES "${ALLOWED_REGEX}")
        continue()
    endif ()
    list(APPEND errors "unexpected file: ${file}")
endforeach ()
foreach (file IN LISTS EXPECTED_FILES)
    if (NOT file IN_LIST installed)
        list(APPEND errors "missing file: ${file}")
    endif ()
endforeach ()

# 3. The installed application has to run.
execute_process(COMMAND "${PREFIX}/${APP}" RESULT_VARIABLE result OUTPUT_VARIABLE output ERROR_VARIABLE output)
if (NOT result EQUAL 0)
    list(APPEND errors "running ${APP} failed (${result}): ${output}")
endif ()

# 4. Runtime dependencies: only system libraries and files shipped in the prefix.
set(executables "")
set(libraries "")
foreach (file IN LISTS CHECK_FILES)
    if (file MATCHES "\\.(so|dll)(\\.[0-9]+)*$")
        list(APPEND libraries "${PREFIX}/${file}")
    else ()
        list(APPEND executables "${PREFIX}/${file}")
    endif ()
endforeach ()

set(extra_args "")
if (WIN32)
    file(TO_CMAKE_PATH "$ENV{SystemRoot}" system_root)
    set(system_dirs "${system_root}/System32")
    set(system_regex "^${system_root}/")
    # API sets are virtual DLL names that the loader maps to system DLLs.
    set(pre_exclude "^api-ms-" "^ext-ms-")
    # Exclude system DLLs once resolved, so they are not analyzed: their imports reach deep into
    # Windows internals and include components that are not installed on every
    # machine (e.g. AzureAttestManager.dll, wtdccm.dll on CI runners), which would
    # show up as unresolved. Only the files shipped in the package are analyzed
    # recursively. The pattern is case-insensitive, like Windows paths.
    set(system_regex_ci "")
    string(LENGTH "${system_regex}" length)
    math(EXPR last "${length} - 1")
    foreach (i RANGE ${last})
        string(SUBSTRING "${system_regex}" ${i} 1 c)
        string(TOUPPER "${c}" upper)
        string(TOLOWER "${c}" lower)
        if (upper STREQUAL lower)
            string(APPEND system_regex_ci "${c}")
        else ()
            string(APPEND system_regex_ci "[${upper}${lower}]")
        endif ()
    endforeach ()
    list(APPEND extra_args POST_EXCLUDE_REGEXES "${system_regex_ci}")
else ()
    set(system_dirs "")
    set(system_regex "^/(usr/)?lib(64|32|x32)?/")
    set(pre_exclude "^ld-linux" "^linux-vdso")
endif ()

file(GET_RUNTIME_DEPENDENCIES
        EXECUTABLES ${executables}
        LIBRARIES ${libraries}
        RESOLVED_DEPENDENCIES_VAR resolved
        UNRESOLVED_DEPENDENCIES_VAR unresolved
        DIRECTORIES "${PREFIX}/bin" "${PREFIX}/lib" ${system_dirs}
        PRE_EXCLUDE_REGEXES ${pre_exclude}
        ${extra_args})

file(REAL_PATH "${PREFIX}" prefix_real)
if (WIN32)
    # Windows paths are case-insensitive.
    string(TOLOWER "${prefix_real}" prefix_real)
    string(TOLOWER "${system_regex}" system_regex)
endif ()
foreach (dep IN LISTS resolved)
    file(TO_CMAKE_PATH "${dep}" dep)
    file(REAL_PATH "${dep}" dep_real)
    if (WIN32)
        string(TOLOWER "${dep}" dep)
        string(TOLOWER "${dep_real}" dep_real)
    endif ()
    string(FIND "${dep_real}" "${prefix_real}/" in_prefix)
    if (in_prefix EQUAL 0)
        message(STATUS "shipped dependency: ${dep}")
    elseif (dep MATCHES "${system_regex}")
        message(STATUS "system dependency:  ${dep}")
    else ()
        list(APPEND errors "dependency outside of the package and the system: ${dep}")
    endif ()
endforeach ()
foreach (dep IN LISTS unresolved)
    list(APPEND errors "unresolved dependency: ${dep}")
endforeach ()

if (errors)
    list(JOIN errors "\n  " errors)
    message(FATAL_ERROR "Delivery check failed for ${PREFIX}:\n  ${errors}\nInstalled files: ${installed}")
endif ()
message(STATUS "Delivery check passed: ${installed}")
