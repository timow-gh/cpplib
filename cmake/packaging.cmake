include_guard(GLOBAL)

# Base library name (derived from project name, lowercase for convention)
string(TOLOWER "${PROJECT_NAME}" PKG_LIB_NAME)

# Package naming based on library type (shared vs static)
# Different naming conventions avoid filename collisions when releasing both variants
if(BUILD_SHARED_LIBS)
    # Shared library packages (standard naming)
    set(PKG_DEB_RUNTIME_NAME "lib${PKG_LIB_NAME}${PROJECT_VERSION_MAJOR}")
    set(PKG_DEB_DEV_NAME "lib${PKG_LIB_NAME}-dev")
    set(PKG_RPM_RUNTIME_NAME "${PKG_LIB_NAME}-libs")
    set(PKG_RPM_DEV_NAME "${PKG_LIB_NAME}-devel")
    set(CPACK_PACKAGE_NAME "${PROJECT_NAME}")
else()
    # Static library packages (with -static suffix to differentiate)
    set(PKG_DEB_DEV_NAME "lib${PKG_LIB_NAME}-dev-static")
    set(PKG_RPM_DEV_NAME "${PKG_LIB_NAME}-static")
    set(CPACK_PACKAGE_NAME "${PROJECT_NAME}-static")
endif()

# Package metadata
set(PKG_VENDOR "${PROJECT_NAME}")
set(PKG_CONTACT "cpplib maintainers <39085531+timow-gh@users.noreply.github.com>")
set(PKG_DESCRIPTION "A C++ library providing core functionality")
set(PKG_LICENSE "Unlicense")
set(PKG_HOMEPAGE_URL "https://github.com/timow-gh/cpplib")

# Warn if packaging debug builds
if(CMAKE_BUILD_TYPE MATCHES "Debug" OR CMAKE_BUILD_TYPE MATCHES "RelWithDebInfo")
    message(WARNING "Creating packages from ${CMAKE_BUILD_TYPE} build. ")
endif()

set(CPACK_PACKAGE_VERSION_MAJOR "${PROJECT_VERSION_MAJOR}")
set(CPACK_PACKAGE_VERSION_MINOR "${PROJECT_VERSION_MINOR}")
set(CPACK_PACKAGE_VERSION_PATCH "${PROJECT_VERSION_PATCH}")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "${PKG_DESCRIPTION}")
set(CPACK_PACKAGE_VENDOR "${PKG_VENDOR}")
set(CPACK_PACKAGE_CONTACT "${PKG_CONTACT}")
set(CPACK_PACKAGE_HOMEPAGE_URL "${PKG_HOMEPAGE_URL}")
set(CPACK_PACKAGE_CHECKSUM SHA256)
set(CPACK_RESOURCE_FILE_LICENSE "${CMAKE_CURRENT_SOURCE_DIR}/License")

# Human-friendly archive names per platform (DEB/RPM keep their own DEFAULT naming below)
if(WIN32)
    set(CPACK_PACKAGE_FILE_NAME "${CPACK_PACKAGE_NAME}-${PROJECT_VERSION}-windows-x64")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(CPACK_PACKAGE_FILE_NAME "${CPACK_PACKAGE_NAME}-${PROJECT_VERSION}-linux-${CMAKE_SYSTEM_PROCESSOR}")
else()
    set(CPACK_PACKAGE_FILE_NAME "${CPACK_PACKAGE_NAME}-${PROJECT_VERSION}-${CMAKE_SYSTEM_NAME}-${CMAKE_SYSTEM_PROCESSOR}")
endif()

# Component configuration
# Only create runtime component when building shared libraries
if(BUILD_SHARED_LIBS)
    set(CPACK_COMPONENTS_ALL runtime dev)
    set(CPACK_COMPONENT_RUNTIME_DISPLAY_NAME "Runtime Libraries")
    set(CPACK_COMPONENT_RUNTIME_DESCRIPTION 
        "Shared libraries required to run applications using ${PROJECT_NAME}")
    set(CPACK_COMPONENT_DEV_DEPENDS runtime)
else()
    set(CPACK_COMPONENTS_ALL dev)
    message(STATUS "CPack: Building static library only - runtime component excluded")
endif()

set(CPACK_COMPONENT_DEV_DISPLAY_NAME "Development Files")
set(CPACK_COMPONENT_DEV_DESCRIPTION 
    "Header files, static libraries, and CMake configuration files for development")

# Archive generators (TGZ, TBZ2) - component-based
set(CPACK_ARCHIVE_COMPONENT_INSTALL ON)

# DEB (Debian/Ubuntu) Configuration
set(CPACK_DEB_COMPONENT_INSTALL ON)
set(CPACK_DEBIAN_PACKAGE_MAINTAINER "${CPACK_PACKAGE_CONTACT}")
set(CPACK_DEBIAN_FILE_NAME DEB-DEFAULT)  # Standard naming: name_version_arch.deb
set(CPACK_DEBIAN_PACKAGE_HOMEPAGE "${CPACK_PACKAGE_HOMEPAGE_URL}")

# Component-specific DEB settings
set(CPACK_DEBIAN_DEV_PACKAGE_NAME "${PKG_DEB_DEV_NAME}")
set(CPACK_DEBIAN_DEV_PACKAGE_SECTION "libdevel")

if(BUILD_SHARED_LIBS)
    set(CPACK_DEBIAN_RUNTIME_PACKAGE_NAME "${PKG_DEB_RUNTIME_NAME}")
    set(CPACK_DEBIAN_RUNTIME_PACKAGE_SECTION "libs")
    # Automatic shared library dependency detection for runtime package
    set(CPACK_DEBIAN_RUNTIME_PACKAGE_SHLIBDEPS ON)
    # Development package depends on runtime package
    set(CPACK_DEBIAN_DEV_PACKAGE_DEPENDS "${PKG_DEB_RUNTIME_NAME} (= ${PROJECT_VERSION})")
endif()

# RPM (RedHat/Fedora/SUSE) Configuration
set(CPACK_RPM_COMPONENT_INSTALL ON)
set(CPACK_RPM_PACKAGE_LICENSE "${PKG_LICENSE}")
set(CPACK_RPM_FILE_NAME RPM-DEFAULT)  # Standard naming: name-version-arch.rpm

# Component-specific RPM settings
if(BUILD_SHARED_LIBS)
    set(CPACK_RPM_RUNTIME_PACKAGE_NAME "${PKG_RPM_RUNTIME_NAME}")
endif()
set(CPACK_RPM_DEV_PACKAGE_NAME "${PKG_RPM_DEV_NAME}")
set(CPACK_RPM_DEV_PACKAGE_GROUP "Development/Libraries")

if(BUILD_SHARED_LIBS)
    set(CPACK_RPM_RUNTIME_PACKAGE_GROUP "System Environment/Libraries")
    # Automatic dependency detection for runtime package
    set(CPACK_RPM_RUNTIME_PACKAGE_AUTOREQPROV ON)
    # Development package depends on runtime package
    set(CPACK_RPM_DEV_PACKAGE_REQUIRES "${PKG_RPM_RUNTIME_NAME} = ${PROJECT_VERSION}")
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
    # injected via this patch fragment.
    set(CPACK_WIX_PATCH_FILE "${CMAKE_CURRENT_LIST_DIR}/wix_patch.xml")
endif()

# Generator Selection
# Default to TGZ if no generator specified (works everywhere)
# CMake presets can override this via CPACK_GENERATOR cache variable
if(NOT CPACK_GENERATOR)
    set(CPACK_GENERATOR "TGZ")
endif()

# Load CPack module
include(CPack)

# Status Messages
message(STATUS "CPack: Packaging enabled for ${PROJECT_NAME} ${PROJECT_VERSION}")
message(STATUS "CPack: Supported generators: DEB, RPM, TGZ, TBZ2, WIX (Windows)")
message(STATUS "CPack: Default generator: ${CPACK_GENERATOR}")
if(BUILD_SHARED_LIBS)
    message(STATUS "CPack: Components: runtime (shared libs), dev (headers, cmake configs)")
    message(STATUS "CPack: DEB packages: ${PKG_DEB_RUNTIME_NAME}, ${PKG_DEB_DEV_NAME}")
    message(STATUS "CPack: RPM packages: ${PKG_RPM_RUNTIME_NAME}, ${PKG_RPM_DEV_NAME}")
else()
    message(STATUS "CPack: Components: dev only (static lib, headers, cmake configs)")
    message(STATUS "CPack: DEB package: ${PKG_DEB_DEV_NAME}")
    message(STATUS "CPack: RPM package: ${PKG_RPM_DEV_NAME}")
endif()
message(STATUS "CPack: Run 'cpack -G <generator>' to create packages")
