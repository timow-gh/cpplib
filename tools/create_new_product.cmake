# Creates a NEW PRODUCT from this template.
#
#   cmake -DNAME=<name> [-DVENDOR=<vendor>] [-DCONTACT="<name> <email>"]
#         [-DHOMEPAGE=<url>] [-DDESCRIPTION=<text>] [-DFORCE=ON]
#         -P tools/create_new_product.cmake
#
# What it does:
#   - Renames the project: every occurrence of the current project name (lower and
#     upper case) in the tracked files, and every file or directory named after it.
#     This covers the C++ namespace, the header directory, the export macro, the
#     vcpkg manifest and .clang-format; everything else derives from project().
#   - Sets vendor, contact, homepage and description (project() and
#     cmake/product_identity.cmake).
#   - Generates a NEW random MSI upgrade code (cmake/product_identity.cmake).
#
# Consequence: the result is a different product. Its installers do not upgrade
# installations of the current product, and its packages have different names.
# That is what you want when you start a new product from the template, and what
# you never want for a product that has already been released. Therefore the
# script refuses to run when the repository has release tags (v*), unless FORCE
# is set.
cmake_minimum_required(VERSION 3.28)

get_filename_component(root "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)

# --- Validate the arguments --------------------------------------------------
if (NOT NAME)
    message(FATAL_ERROR "Usage: cmake -DNAME=<name> [-DVENDOR=...] [-DCONTACT=...] [-DHOMEPAGE=...] "
            "[-DDESCRIPTION=...] [-DFORCE=ON] -P tools/create_new_product.cmake")
endif ()
if (NOT NAME MATCHES "^[a-z][a-z0-9_]*$")
    message(FATAL_ERROR "NAME must be a lower-case identifier ([a-z][a-z0-9_]*), it is used for targets, "
            "the C++ namespace and package names: '${NAME}'")
endif ()

file(READ "${root}/CMakeLists.txt" root_cmakelists)
if (NOT root_cmakelists MATCHES "project\\(([A-Za-z0-9_]+)")
    message(FATAL_ERROR "Could not find the project() call in ${root}/CMakeLists.txt")
endif ()
set(old_name "${CMAKE_MATCH_1}")
if (old_name STREQUAL NAME)
    message(FATAL_ERROR "The project is already called '${NAME}'")
endif ()
string(REGEX MATCH "HOMEPAGE_URL \"([^\"]*)\"" _ "${root_cmakelists}")
set(old_homepage "${CMAKE_MATCH_1}")

# --- Refuse to turn a released product into a new one ------------------------
find_package(Git QUIET)
if (GIT_FOUND)
    execute_process(COMMAND "${GIT_EXECUTABLE}" -C "${root}" tag --list "v*"
                    OUTPUT_VARIABLE release_tags OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
    if (release_tags AND NOT FORCE)
        string(REPLACE "\n" ", " release_tags "${release_tags}")
        message(FATAL_ERROR "This repository has release tags (${release_tags}).\n"
                "Creating a new product generates a new MSI upgrade code and new package names: the next "
                "release could not upgrade the installations of '${old_name}' that are out there.\n"
                "If you really are starting a new product in this repository, run again with -DFORCE=ON.")
    endif ()
endif ()

# --- Collect the files -------------------------------------------------------
set(files "")
if (GIT_FOUND)
    execute_process(COMMAND "${GIT_EXECUTABLE}" -C "${root}" ls-files
                    OUTPUT_VARIABLE files RESULT_VARIABLE result OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
    if (result EQUAL 0)
        string(REPLACE "\n" ";" files "${files}")
    else ()
        set(files "")
    endif ()
endif ()
if (NOT files)
    file(GLOB_RECURSE files LIST_DIRECTORIES false RELATIVE "${root}" "${root}/*")
    list(FILTER files EXCLUDE REGEX "^(\\.git|out|build)/")
endif ()
list(REMOVE_ITEM files "tools/create_new_product.cmake")

# --- Replace the name in the file contents -----------------------------------
string(TOUPPER "${old_name}" old_upper)
string(TOUPPER "${NAME}" new_upper)
set(changed_files "")
foreach (file IN LISTS files)
    if (NOT EXISTS "${root}/${file}" OR file MATCHES "\\.(png|ico|bmp|jpg|jpeg|gif|zip|gz)$")
        continue()
    endif ()
    file(READ "${root}/${file}" content)
    set(original "${content}")
    if (HOMEPAGE AND old_homepage)
        string(REPLACE "${old_homepage}" "${HOMEPAGE}" content "${content}")
    endif ()
    string(REPLACE "${old_upper}" "${new_upper}" content "${content}")
    string(REPLACE "${old_name}" "${NAME}" content "${content}")
    if (NOT content STREQUAL original)
        file(WRITE "${root}/${file}" "${content}")
        list(APPEND changed_files "${file}")
    endif ()
endforeach ()

# --- Rename files and directories named after the project --------------------
set(renamed "")
foreach (file IN LISTS files)
    string(REPLACE "${old_name}" "${NAME}" new_file "${file}")
    if (NOT new_file STREQUAL file AND EXISTS "${root}/${file}")
        get_filename_component(new_dir "${root}/${new_file}" DIRECTORY)
        file(MAKE_DIRECTORY "${new_dir}")
        file(RENAME "${root}/${file}" "${root}/${new_file}")
        list(APPEND renamed "${file} -> ${new_file}")
        # Remove directories that became empty.
        get_filename_component(dir "${root}/${file}" DIRECTORY)
        while (NOT dir STREQUAL root)
            file(GLOB left "${dir}/*")
            if (left)
                break()
            endif ()
            file(REMOVE_RECURSE "${dir}")
            get_filename_component(dir "${dir}" DIRECTORY)
        endwhile ()
    endif ()
endforeach ()

# --- Product metadata ----------------------------------------------------------
function(replace_in file regex replacement)
    file(READ "${root}/${file}" content)
    string(REGEX REPLACE "${regex}" "${replacement}" content "${content}")
    file(WRITE "${root}/${file}" "${content}")
endfunction()

if (DESCRIPTION)
    replace_in("CMakeLists.txt" "DESCRIPTION \"[^\"]*\"" "DESCRIPTION \"${DESCRIPTION}\"")
endif ()
if (HOMEPAGE)
    replace_in("CMakeLists.txt" "HOMEPAGE_URL \"[^\"]*\"" "HOMEPAGE_URL \"${HOMEPAGE}\"")
endif ()
if (VENDOR)
    replace_in("cmake/product_identity.cmake" "set\\(PRODUCT_VENDOR \"[^\"]*\"\\)" "set(PRODUCT_VENDOR \"${VENDOR}\")")
endif ()
if (CONTACT)
    replace_in("cmake/product_identity.cmake" "set\\(PRODUCT_CONTACT \"[^\"]*\"\\)" "set(PRODUCT_CONTACT \"${CONTACT}\")")
endif ()

# A random UUID: CMake has no random UUID generator, so hash random data (random
# string, time in microseconds, host name, product name) into a UUID.
string(RANDOM LENGTH 32 ALPHABET "0123456789abcdef" random_data)
string(TIMESTAMP now "%Y%m%d%H%M%S%f" UTC)
cmake_host_system_information(RESULT host QUERY HOSTNAME)
string(UUID upgrade_guid NAMESPACE "6ba7b811-9dad-11d1-80b4-00c04fd430c8"
       NAME "${random_data}-${now}-${host}-${NAME}" TYPE SHA1 UPPER)
replace_in("cmake/product_identity.cmake" "set\\(PRODUCT_WIX_UPGRADE_GUID \"[^\"]*\"\\)"
           "set(PRODUCT_WIX_UPGRADE_GUID \"${upgrade_guid}\")")

# --- Summary -----------------------------------------------------------------
list(LENGTH changed_files changed_count)
string(REPLACE ";" "\n    " renamed_text "${renamed}")
message("Created the new product '${NAME}' from '${old_name}'.\n"
        "  Updated ${changed_count} files.\n"
        "  Renamed:\n    ${renamed_text}\n"
        "  New MSI upgrade code: ${upgrade_guid} (cmake/product_identity.cmake)\n"
        "    Commit it now and never change it after the first release: it is how Windows\n"
        "    recognizes new versions of '${NAME}' as upgrades.\n"
        "Next steps:\n"
        "  - Review the changes (git status, git diff), including vendor/contact in\n"
        "    cmake/product_identity.cmake and DESCRIPTION/HOMEPAGE_URL in CMakeLists.txt.\n"
        "  - Replace License and cmake/License.rtf, and adapt ReadMe.md.\n"
        "  - Delete the build directories (out/) before configuring again.")
