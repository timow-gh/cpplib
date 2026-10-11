include(GNUInstallDirs)

# fmt is provided through vcpkg (see vcpkg.json) as a static library. It is an
# implementation detail of cpplib, see the target_link_libraries() call below.
find_package(fmt CONFIG REQUIRED)

set(TARGET_NAME ${${PROJECT_NAME}_LIBRARY_TARGET})
add_library(${TARGET_NAME})

target_sources(${TARGET_NAME}
        PRIVATE
        source/cpplib.cpp
        PUBLIC
        FILE_SET HEADERS
        BASE_DIRS include
        FILES include/cpplib/cpplib.hpp
)

set_target_properties(${TARGET_NAME}
        PROPERTIES
        DEBUG_POSTFIX d
        VERSION ${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}.${PROJECT_VERSION_PATCH}
        SOVERSION ${PROJECT_VERSION_MAJOR}
        OUTPUT_NAME "${TARGET_NAME}"
        EXPORT_NAME ${TARGET_NAME})

add_library(${PROJECT_NAME}::${TARGET_NAME} ALIAS ${TARGET_NAME})

# Third-party dependencies are static and build-only:
# - PRIVATE keeps fmt out of cpplib's public usage requirements.
# - $<BUILD_LOCAL_INTERFACE:...> keeps fmt out of the installed export set, so the
#   installed cpplib package has no find_dependency(fmt).
# Shared cpplib: the static fmt archive is linked into cpplib.dll / libcpplib.so.
# Static cpplib: every target of this build that links cpplib (e.g. cpplib_app)
# also links fmt, so the executable is self-contained. A static cpplib is never
# installed, because its export set would lack fmt (see the install block below).
target_link_libraries(${TARGET_NAME} PRIVATE $<BUILD_LOCAL_INTERFACE:fmt::fmt>)

include(GenerateExportHeader)
set(EXPORT_HEADER_BASE_NAME "${TARGET_NAME}")
set(GENERATED_TARGET_EXPORTS_FILE_NAME "${TARGET_NAME}_export.h")
generate_export_header(${TARGET_NAME}
    BASE_NAME ${EXPORT_HEADER_BASE_NAME}
    EXPORT_FILE_NAME "${CMAKE_CURRENT_BINARY_DIR}/export_header_includes/${TARGET_NAME}/${GENERATED_TARGET_EXPORTS_FILE_NAME}")

target_include_directories(${TARGET_NAME}
        PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_BINARY_DIR}/export_header_includes>
        $<BUILD_INTERFACE:${CMAKE_CURRENT_LIST_DIR}/include>
        $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>)

# Mark the generated export header as GENERATED so CMake doesn't check for its existence at configuration time
set_source_files_properties(
    ${CMAKE_CURRENT_BINARY_DIR}/export_header_includes/${TARGET_NAME}/${GENERATED_TARGET_EXPORTS_FILE_NAME}
    PROPERTIES GENERATED TRUE
)

target_sources(${TARGET_NAME}
    PUBLIC
    FILE_SET HEADERS
    BASE_DIRS ${CMAKE_CURRENT_BINARY_DIR}/export_header_includes
    FILES ${CMAKE_CURRENT_BINARY_DIR}/export_header_includes/${TARGET_NAME}/${GENERATED_TARGET_EXPORTS_FILE_NAME}
)

target_compile_features(${TARGET_NAME} PUBLIC cxx_std_23)

if (DEFINED ${PROJECT_NAME}_USE_WARNINGS AND ${PROJECT_NAME}_USE_WARNINGS)
    add_warnings_and_compile_options(${TARGET_NAME} "${${PROJECT_NAME}_WARNINGS_AS_ERRORS}")
endif ()

if (DEFINED ${PROJECT_NAME}_STATIC_ANALYSIS AND ${PROJECT_NAME}_STATIC_ANALYSIS)
    enable_static_analysis(${TARGET_NAME} "${${PROJECT_NAME}_WARNINGS_AS_ERRORS}")
endif ()

# The library SDK (runtime + dev components) is installed for shared builds only.
# A static cpplib would need its static third-party dependencies (fmt) installed
# and re-found as well; that is deliberately not supported. Static builds ship
# the standalone application instead (see app/CMakeLists.txt).
if (${PROJECT_NAME}_INSTALL AND NOT BUILD_SHARED_LIBS)
    message(STATUS "${TARGET_NAME}: static build, the library SDK is not installed (only the standalone application)")
endif ()

if (${PROJECT_NAME}_INSTALL AND BUILD_SHARED_LIBS)
    include(CMakePackageConfigHelpers)
    
    set(project_export_set_name "${PROJECT_NAME}TargetsExportSet")
    set(config_install_dir "${CMAKE_INSTALL_LIBDIR}/cmake/${PROJECT_NAME}")

    # Use a single install(TARGETS) command for all destination types to ensure proper CMake export generation.
    install(TARGETS
            ${TARGET_NAME}
            EXPORT ${project_export_set_name}
            RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
            COMPONENT runtime
            LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
            COMPONENT runtime
            # The unversioned libcpplib.so symlink is only needed to link against cpplib.
            NAMELINK_COMPONENT dev
            ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
            COMPONENT dev
            FILE_SET HEADERS
            DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
            COMPONENT dev)

    # Generate and install package config files
    write_basic_package_version_file(
            "${CMAKE_CURRENT_BINARY_DIR}/${PROJECT_NAME}ConfigVersion.cmake"
            VERSION ${PROJECT_VERSION}
            COMPATIBILITY SameMajorVersion)

    # project_name is referenced as @project_name@ inside Config.cmake.in
    set(project_name "${PROJECT_NAME}")
    configure_package_config_file(
            "${PROJECT_SOURCE_DIR}/cmake/Config.cmake.in"
            "${CMAKE_CURRENT_BINARY_DIR}/${PROJECT_NAME}Config.cmake"
            INSTALL_DESTINATION "${config_install_dir}")

    # Install export set (installed package targets)
    install(EXPORT ${project_export_set_name}
            NAMESPACE ${PROJECT_NAME}::
            FILE ${PROJECT_NAME}Targets.cmake
            DESTINATION "${config_install_dir}"
            COMPONENT dev)

    # Export targets for build tree (allows using without installation)
    export(EXPORT ${project_export_set_name}
            FILE "${CMAKE_CURRENT_BINARY_DIR}/${PROJECT_NAME}Targets.cmake"
            NAMESPACE ${PROJECT_NAME}::)

    # Install package config files
    install(FILES
            "${CMAKE_CURRENT_BINARY_DIR}/${PROJECT_NAME}Config.cmake"
            "${CMAKE_CURRENT_BINARY_DIR}/${PROJECT_NAME}ConfigVersion.cmake"
            DESTINATION "${config_install_dir}"
            COMPONENT dev)
endif ()