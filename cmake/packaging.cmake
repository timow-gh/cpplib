include_guard(GLOBAL)

# CPack configuration. The delivery mode is decided by BUILD_SHARED_LIBS, which the
# configure preset sets (see "Shipping the application" in ReadMe.md):
#
#   shared     (*-shared presets)     components: app, runtime, dev
#       app     - cpplib_app (+ app-local MSVC runtime DLLs on Windows)
#       runtime - cpplib.dll / libcpplib.so.* and the License
#       dev     - headers, import library, CMake package files (the library SDK)
#   standalone (*-standalone presets) components: app
#       app     - the self-contained cpplib_app executable and the License
#
# Component layout per generator:
#   TGZ / ZIP - one archive with every component (ready to run, and the SDK)
#   DEB       - one package per component, with Depends between them
#   WIX       - one MSI with one feature per component

string(TOLOWER "${PROJECT_NAME}" PKG_NAME)

# Package metadata
set(CPACK_PACKAGE_VENDOR "${PROJECT_NAME}")
set(CPACK_PACKAGE_CONTACT "cpplib maintainers <39085531+timow-gh@users.noreply.github.com>")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "A C++ library and application template")
set(CPACK_PACKAGE_HOMEPAGE_URL "https://github.com/timow-gh/cpplib")
set(CPACK_PACKAGE_VERSION_MAJOR "${PROJECT_VERSION_MAJOR}")
set(CPACK_PACKAGE_VERSION_MINOR "${PROJECT_VERSION_MINOR}")
set(CPACK_PACKAGE_VERSION_PATCH "${PROJECT_VERSION_PATCH}")
set(CPACK_PACKAGE_CHECKSUM SHA256)
set(CPACK_RESOURCE_FILE_LICENSE "${PROJECT_SOURCE_DIR}/License")

# Warn if packaging debug builds
if(CMAKE_BUILD_TYPE MATCHES "Debug" OR CMAKE_BUILD_TYPE MATCHES "RelWithDebInfo")
    message(WARNING "Creating packages from ${CMAKE_BUILD_TYPE} build. ")
endif()

if(BUILD_SHARED_LIBS)
    set(PKG_VARIANT "")
    set(CPACK_COMPONENTS_ALL app runtime dev)
else()
    # Distinct names keep the standalone release assets from colliding with the
    # shared ones.
    set(PKG_VARIANT "-standalone")
    set(CPACK_COMPONENTS_ALL app)
endif()
set(CPACK_PACKAGE_NAME "${PKG_NAME}${PKG_VARIANT}")

# Human-friendly archive names per platform (DEB keeps its own DEFAULT naming below)
if(WIN32)
    set(CPACK_PACKAGE_FILE_NAME "${CPACK_PACKAGE_NAME}-${PROJECT_VERSION}-windows-x64")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(CPACK_PACKAGE_FILE_NAME "${CPACK_PACKAGE_NAME}-${PROJECT_VERSION}-linux-${CMAKE_SYSTEM_PROCESSOR}")
else()
    set(CPACK_PACKAGE_FILE_NAME "${CPACK_PACKAGE_NAME}-${PROJECT_VERSION}-${CMAKE_SYSTEM_NAME}-${CMAKE_SYSTEM_PROCESSOR}")
endif()

# Components
set(CPACK_COMPONENT_APP_DISPLAY_NAME "Application")
set(CPACK_COMPONENT_APP_DESCRIPTION "The cpplib_app application")
set(CPACK_COMPONENT_RUNTIME_DISPLAY_NAME "Runtime Libraries")
set(CPACK_COMPONENT_RUNTIME_DESCRIPTION "The cpplib shared library")
set(CPACK_COMPONENT_DEV_DISPLAY_NAME "Development Files")
set(CPACK_COMPONENT_DEV_DESCRIPTION "Headers, import library and CMake package files to build against cpplib")
if(BUILD_SHARED_LIBS)
    set(CPACK_COMPONENT_APP_DEPENDS runtime)
    set(CPACK_COMPONENT_DEV_DEPENDS runtime)
endif()

# Archive generators (TGZ, ZIP): one archive containing all components.
set(CPACK_ARCHIVE_COMPONENT_INSTALL OFF)

# DEB (Debian/Ubuntu): one package per component, installed below /usr. The
# install prefix and the dpkg-shlibdeps setup live in cpack_project_config.cmake.
set(CPACK_DEB_COMPONENT_INSTALL ON)
set(CPACK_DEBIAN_FILE_NAME DEB-DEFAULT)  # Standard naming: name_version_arch.deb
set(CPACK_DEBIAN_PACKAGE_MAINTAINER "${CPACK_PACKAGE_CONTACT}")
set(CPACK_DEBIAN_PACKAGE_HOMEPAGE "${CPACK_PACKAGE_HOMEPAGE_URL}")
# Turn CPACK_COMPONENT_<C>_DEPENDS into "Depends:" between the generated packages.
set(CPACK_DEBIAN_ENABLE_COMPONENT_DEPENDS ON)
# Detect libc/libstdc++ dependencies with dpkg-shlibdeps.
set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS ON)

set(CPACK_DEBIAN_APP_PACKAGE_NAME "${PKG_NAME}-app${PKG_VARIANT}")
set(CPACK_DEBIAN_APP_PACKAGE_SECTION "utils")
if(BUILD_SHARED_LIBS)
    set(CPACK_DEBIAN_RUNTIME_PACKAGE_NAME "lib${PKG_NAME}${PROJECT_VERSION_MAJOR}")
    set(CPACK_DEBIAN_RUNTIME_PACKAGE_SECTION "libs")
    set(CPACK_DEBIAN_DEV_PACKAGE_NAME "lib${PKG_NAME}-dev")
    set(CPACK_DEBIAN_DEV_PACKAGE_SECTION "libdevel")
    # Both variants install /usr/bin/cpplib_app.
    set(CPACK_DEBIAN_APP_PACKAGE_CONFLICTS "${PKG_NAME}-app-standalone")
else()
    set(CPACK_DEBIAN_APP_PACKAGE_CONFLICTS "${PKG_NAME}-app")
endif()

# WiX (MSI) Configuration for Windows
if(WIN32)
    # WiX/MSI installer. The Windows Installer engine edits the PATH registry
    # value through the OS API (see cmake/wix_patch.xml), avoiding the 1024-char
    # string-buffer limit that made the old NSIS installer fail on machines with
    # a long system PATH.
    set(CPACK_PACKAGE_INSTALL_DIRECTORY "${PROJECT_NAME}")

    # Stable upgrade GUID. Windows Installer uses this to recognize that a new
    # package is an upgrade of a previously installed cpplib rather than a
    # separate product. It MUST NEVER CHANGE once released: changing it makes
    # future versions install side-by-side instead of upgrading in place.
    # The shared and the standalone MSI deliberately share it: both install the
    # same application into the same folder, so installing one replaces the other.
    # CPACK_WIX_PRODUCT_GUID is intentionally left unset so CPack regenerates it
    # per version, which together with the stable upgrade GUID gives clean
    # major-upgrade (uninstall-old-then-install-new) behavior.
    set(CPACK_WIX_UPGRADE_GUID "6E7C3F4B-9A21-4D8E-B5C6-2F0A1D3E4B7C")

    # Add/Remove Programs links.
    set(CPACK_WIX_PROPERTY_ARPHELPLINK "${CPACK_PACKAGE_HOMEPAGE_URL}")
    set(CPACK_WIX_PROPERTY_ARPURLINFOABOUT "${CPACK_PACKAGE_HOMEPAGE_URL}")

    # WiX requires the license shown in the installer UI to be real RTF with an
    # .rtf/.txt extension. The repo License is extensionless plain text (used by
    # every other generator via CPACK_RESOURCE_FILE_LICENSE), so point WiX at an
    # RTF rendering of the same Unlicense text instead.
    set(CPACK_WIX_LICENSE_RTF "${CMAKE_CURRENT_LIST_DIR}/License.rtf")

    # Custom WiX template using the WixUI_Advanced dialog set so the installer
    # offers a per-user vs all-users choice.
    set(CPACK_WIX_TEMPLATE "${CMAKE_CURRENT_LIST_DIR}/wix_template.wxs")
    set(CPACK_WIX_UI_REF "WixUI_Advanced")

    # Re-implement "add bin to PATH": CPack's WiX generator has no built-in
    # equivalent of CPACK_NSIS_MODIFY_PATH, so an <Environment> element is
    # injected via this patch fragment. It is attached to the "app" component,
    # which exists in both delivery modes.
    set(CPACK_WIX_PATCH_FILE "${CMAKE_CURRENT_LIST_DIR}/wix_patch.xml")
endif()

# Packaging-time settings that depend on the package directory (see the file).
configure_file("${CMAKE_CURRENT_LIST_DIR}/cpack_project_config.cmake"
               "${CMAKE_BINARY_DIR}/cpack_project_config.cmake" @ONLY)
set(CPACK_PROJECT_CONFIG_FILE "${CMAKE_BINARY_DIR}/cpack_project_config.cmake")

# Generator Selection
# Default to TGZ if no generator specified (works everywhere)
# CMake presets can override this via CPACK_GENERATOR cache variable
if(NOT CPACK_GENERATOR)
    set(CPACK_GENERATOR "TGZ")
endif()

# Load CPack module
include(CPack)

# Status Messages
message(STATUS "CPack: Packaging enabled for ${PROJECT_NAME} ${PROJECT_VERSION} (${CPACK_PACKAGE_NAME})")
message(STATUS "CPack: Components: ${CPACK_COMPONENTS_ALL}")
message(STATUS "CPack: Default generator: ${CPACK_GENERATOR}")
message(STATUS "CPack: Run 'cpack -G <generator>' or a package preset to create packages")
