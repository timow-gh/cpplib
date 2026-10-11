# Included by cpack at packaging time (CPACK_PROJECT_CONFIG_FILE), once per
# generator, when the package directory chosen by the package preset is known.

if (CPACK_GENERATOR STREQUAL "DEB")
    # Debian packages install below /usr: programs to /usr/bin, libraries to
    # /usr/lib, headers to /usr/include. This is the standard location for .deb
    # packages; the app is on PATH and find_package(cpplib) needs no hints.
    # Override it for a self-contained package, e.g.
    #   cpack --preset package-gcc-release-shared -G DEB -D CPACK_PACKAGING_INSTALL_PREFIX=/opt/cpplib
    # (-G DEB: a -D on the command line applies to every generator, the archives too).
    # This default only applies to DEB: TGZ/ZIP archives stay relocatable, the MSI lets the
    # user choose the folder.
    if (NOT CPACK_PACKAGING_INSTALL_PREFIX)
        set(CPACK_PACKAGING_INSTALL_PREFIX "/usr")
    endif ()

    # Shared delivery mode: CPack computes each package's "Depends:" line with
    # dpkg-shlibdeps, which maps every library a binary needs to the installed
    # Debian package that provides it. libcpplib.so.0, needed by cpplib_app, is
    # not installed on the packaging machine; it is packaged (libcpplib0) in this
    # very cpack run. Pass the staged libcpplib0 files as a private library
    # directory, so dpkg-shlibdeps finds the library and skips it. The dependency
    # cpplib-app -> libcpplib0 is declared through CPACK_COMPONENT_APP_DEPENDS.
    list(FIND CPACK_COMPONENTS_ALL runtime _cpplib_runtime_index)
    if (_cpplib_runtime_index GREATER_EQUAL 0)
        set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS_PRIVATE_DIRS
            "${CPACK_PACKAGE_DIRECTORY}/_CPack_Packages/${CPACK_SYSTEM_NAME}/DEB/${CPACK_PACKAGE_FILE_NAME}/runtime${CPACK_PACKAGING_INSTALL_PREFIX}/@CMAKE_INSTALL_LIBDIR@")
    endif ()
endif ()
