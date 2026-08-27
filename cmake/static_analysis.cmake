include_guard()

# Enable static analysis for a target
#
# @param targetName Name of the target to enable static analysis for
# @param WARNINGS_AS_ERRORS Set to true, 1 or ON to enable warnings as errors
function(enable_static_analysis targetName WARNINGS_AS_ERRORS)
    if ("${CMAKE_CXX_COMPILER_ID}" STREQUAL "Clang")
        enable_clang_tidy(${targetName} "${WARNINGS_AS_ERRORS}")
    elseif (MSVC)
        enable_vs_analysis("" ${targetName})
    else ()
        message(AUTHOR_WARNING "No static analysis enabled for ${CMAKE_CXX_COMPILER_ID}")
    endif ()
endfunction()

# Enable clang-tidy static analysis for a target
function(enable_clang_tidy targetName WARNINGS_AS_ERRORS)
    if (CMAKE_CXX_COMPILER_VERSION)
        string(REGEX MATCH "^[0-9]+" CLANG_TIDY_VERSION "${CMAKE_CXX_COMPILER_VERSION}")
    endif ()

    set(CLANG_TIDY_NAMES clang-tidy)
    if (CLANG_TIDY_VERSION)
        list(PREPEND CLANG_TIDY_NAMES clang-tidy-${CLANG_TIDY_VERSION})
    endif ()

    find_program(CLANGTIDY NAMES ${CLANG_TIDY_NAMES})

    if (CLANGTIDY)
        set(CLANG_TIDY_COMMAND ${CLANGTIDY} -extra-arg=-Wno-unknown-warning-option)
        set(CLANG_TIDY_CONFIG_FILE "${PROJECT_SOURCE_DIR}/.clang-tidy")

        if (EXISTS "${CLANG_TIDY_CONFIG_FILE}")
            list(APPEND CLANG_TIDY_COMMAND --config-file=${CLANG_TIDY_CONFIG_FILE})
        endif ()
        
        # set warnings as errors
        if (WARNINGS_AS_ERRORS)
            list(APPEND CLANG_TIDY_COMMAND -warnings-as-errors=*)
        endif ()

        # set C++ standard
        if (NOT "${CMAKE_CXX_STANDARD}" STREQUAL "")
            if ("${CMAKE_CXX_CLANG_TIDY_DRIVER_MODE}" STREQUAL "cl")
                list(APPEND CLANG_TIDY_COMMAND -extra-arg=/std:c++${CMAKE_CXX_STANDARD})
            else ()
                list(APPEND CLANG_TIDY_COMMAND -extra-arg=-std=c++${CMAKE_CXX_STANDARD})
            endif ()
        endif ()

        set_target_properties(${targetName}
                PROPERTIES
                CXX_CLANG_TIDY "${CLANG_TIDY_COMMAND}")

    else ()
        message(FATAL_ERROR "clang-tidy requested but executable not found")
    endif ()

    message(STATUS "${targetName} CXX_CLANG_TIDY: ${CLANG_TIDY_COMMAND}")
endfunction()

# Enable static analysis inside Visual Studio IDE
function(enable_vs_analysis VS_ANALYSIS_RULESET target)
    if ("${VS_ANALYSIS_RULESET}" STREQUAL "")
        # See for other rulesets: C:\Program Files (x86)\Microsoft Visual Studio\20xx\xx\Team Tools\Static Analysis Tools\Rule Sets\
        set(VS_ANALYSIS_RULESET "AllRules.ruleset")
    endif ()
    if (NOT "${CMAKE_CXX_CLANG_TIDY}" STREQUAL "")
        set(_VS_CLANG_TIDY "true")
    else ()
        set(_VS_CLANG_TIDY "false")
    endif ()
    if (CMAKE_GENERATOR MATCHES "Visual Studio")
        set_target_properties(
                ${target}
                PROPERTIES
                VS_GLOBAL_EnableMicrosoftCodeAnalysis true
                VS_GLOBAL_CodeAnalysisRuleSet "${VS_ANALYSIS_RULESET}"
                VS_GLOBAL_EnableClangTidyCodeAnalysis "${_VS_CLANG_TIDY}"
                VS_GLOBAL_RunCodeAnalysis false
        )
    endif ()
endfunction()
