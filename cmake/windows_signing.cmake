# Authenticode signing of the Windows packages. Run by cpack (see the WiX section of
# cmake/packaging.cmake) twice per generator:
#   - as CPACK_PRE_BUILD_SCRIPTS: signs the staged .exe and .dll files, before they
#     are packed into the ZIP / MSI;
#   - as CPACK_POST_BUILD_SCRIPTS: signs the produced .msi files, before cpack
#     copies them to the package directory and writes their .sha256 checksums.
#
# Inactive until a signing service is connected ("Signing" in ReadMe.md). It is
# configured through environment variables at packaging time, so no secret ever
# enters the repository or the build tree:
#   WINDOWS_SIGNTOOL_ARGS     signtool arguments between "sign" and the file, e.g.
#                             for Azure Trusted Signing:
#                             /fd SHA256 /tr http://timestamp.acs.microsoft.com /td SHA256
#                             /dlib <dir>\Azure.CodeSigning.Dlib.dll /dmdf <dir>\metadata.json
#   WINDOWS_SIGNTOOL          optional: path of signtool.exe (default: found in the
#                             Windows SDK or on PATH)
#   WINDOWS_SIGNING_REQUIRED  optional: ON fails packaging when signing is not
#                             configured, so an unsigned release can't slip out
#
# Files that already carry a valid signature (e.g. the Microsoft-signed MSVC runtime
# DLLs) are left untouched.

set(signtool_args "$ENV{WINDOWS_SIGNTOOL_ARGS}")
set(signing_required "$ENV{WINDOWS_SIGNING_REQUIRED}")
if (signtool_args STREQUAL "")
    if (signing_required)
        message(FATAL_ERROR "Windows signing: WINDOWS_SIGNING_REQUIRED is set, but WINDOWS_SIGNTOOL_ARGS is not.")
    endif ()
    if (NOT CPACK_PACKAGE_FILES)
        message(STATUS "Windows signing: not configured (WINDOWS_SIGNTOOL_ARGS is empty), packages stay unsigned.")
    endif ()
    return()
endif ()
separate_arguments(signtool_args WINDOWS_COMMAND "${signtool_args}")

set(signtool "$ENV{WINDOWS_SIGNTOOL}")
if (signtool STREQUAL "")
    # Newest Windows SDK first, then PATH.
    set(program_files_x86 "ProgramFiles(x86)")
    file(TO_CMAKE_PATH "$ENV{${program_files_x86}}" program_files_x86)
    file(GLOB sdk_signtools "${program_files_x86}/Windows Kits/10/bin/*/x64/signtool.exe")
    list(SORT sdk_signtools COMPARE NATURAL ORDER DESCENDING)
    if (sdk_signtools)
        list(GET sdk_signtools 0 signtool)
    else ()
        find_program(signtool NAMES signtool)
    endif ()
endif ()
if (NOT signtool OR NOT EXISTS "${signtool}")
    message(FATAL_ERROR "Windows signing: signtool.exe not found. Install the Windows SDK or set WINDOWS_SIGNTOOL.")
endif ()

if (CPACK_PACKAGE_FILES)
    # Post-build: the finished packages. Only MSIs can carry a signature.
    set(files ${CPACK_PACKAGE_FILES})
    list(FILTER files INCLUDE REGEX "\\.msi$")
else ()
    # Pre-build: the staged binaries.
    file(GLOB_RECURSE files "${CPACK_TEMPORARY_DIRECTORY}/*.exe" "${CPACK_TEMPORARY_DIRECTORY}/*.dll")
endif ()

foreach (file IN LISTS files)
    execute_process(COMMAND "${signtool}" verify /pa /q "${file}"
                    RESULT_VARIABLE already_signed OUTPUT_QUIET ERROR_QUIET)
    if (already_signed EQUAL 0)
        message(STATUS "Windows signing: already signed, skipped: ${file}")
        continue()
    endif ()
    execute_process(COMMAND "${signtool}" sign ${signtool_args} "${file}" RESULT_VARIABLE result)
    if (NOT result EQUAL 0)
        message(FATAL_ERROR "Windows signing: signing failed: ${file}")
    endif ()
    message(STATUS "Windows signing: signed ${file}")
endforeach ()
