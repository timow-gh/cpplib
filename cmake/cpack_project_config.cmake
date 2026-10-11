# Included by cpack at packaging time (CPACK_PROJECT_CONFIG_FILE), when the
# package directory chosen by the package preset is known.

# DEB, shared delivery mode: dpkg-shlibdeps must resolve libcpplib.so.0, which
# cpplib_app links but which is not installed on the packaging machine. Point it
# at the staged files of the runtime package; the dependency on that package is
# declared through CPACK_COMPONENT_APP_DEPENDS instead.
list(FIND CPACK_COMPONENTS_ALL runtime _cpplib_runtime_index)
if (CPACK_GENERATOR STREQUAL "DEB" AND _cpplib_runtime_index GREATER_EQUAL 0)
    # The DEB generator installs into /usr unless CPACK_PACKAGING_INSTALL_PREFIX is
    # set; that default is applied after this file is read.
    set(_cpplib_deb_prefix "${CPACK_PACKAGING_INSTALL_PREFIX}")
    if (NOT _cpplib_deb_prefix)
        set(_cpplib_deb_prefix "/usr")
    endif ()
    set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS_PRIVATE_DIRS
        "${CPACK_PACKAGE_DIRECTORY}/_CPack_Packages/${CPACK_SYSTEM_NAME}/DEB/${CPACK_PACKAGE_FILE_NAME}/runtime${_cpplib_deb_prefix}/@CMAKE_INSTALL_LIBDIR@")
endif ()
