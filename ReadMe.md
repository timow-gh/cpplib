[![Ubuntu Build](https://github.com/timow-gh/cpplib/actions/workflows/ubuntu-build.yml/badge.svg?branch=main)](https://github.com/timow-gh/cpplib/actions/workflows/ubuntu-build.yml)
[![Windows Build](https://github.com/timow-gh/cpplib/actions/workflows/windows-build.yml/badge.svg)](https://github.com/timow-gh/cpplib/actions/workflows/windows-build.yml)

# cpplib

cpplib is a template for a native C++ project. A single CMake build compiles a
library (`cpplib`), an application (`cpplib_app`) and the tests from source. CPack
then ships the application as a native package: a TGZ or DEB on Linux, a ZIP or MSI
on Windows.

The template takes care of the parts that are tedious to get right: third-party
dependencies, symbol export, the MSVC runtime, RPATHs, install rules, packaging
and CI. You can replace the example code and keep the setup. This README explains
how the setup works and why each decision was made.

## Quick start

Prerequisites:
- CMake 3.28 or newer
- Ninja on Linux, Visual Studio 2022 on Windows
- GCC, Clang or MSVC with C++23 support
- [vcpkg](https://vcpkg.io) with the `VCPKG_ROOT` environment variable set

```sh
cmake --workflow --preset workflow-test-gcc-release   # or -clang- / -msvc-
./out/build/conf-gcc-release/app/cpplib_app           # Windows: out\build\conf-msvc-release\bin\Release\cpplib_app.exe
```

## Project layout

| Path | Content |
|---|---|
| `src/` | The library `cpplib` (exported as `cpplib::cpplib`), public headers in `src/include/cpplib/` |
| `app/` | The application `cpplib_app` |
| `test/` | Unit tests (GoogleTest), the delivery check and the SDK install test |
| `cmake/` | Helper modules: warnings, static analysis, packaging, WiX installer files |
| `dependencies/` | Test-only dependencies fetched with [CPM](https://github.com/cpm-cmake/CPM.cmake) (GoogleTest) |
| `vcpkg.json` | Third-party dependencies of the library and the application (`fmt`) |
| `CMakePresets.json` | All configure, build, test, package and workflow presets |

Every target is part of the same build. The application links the library through
its alias target (`target_link_libraries(cpplib_app PRIVATE cpplib::cpplib)`). Nothing
has to be installed before you can build, run or test anything. Installing and
packaging only happen when the result is delivered.

## Design decisions

### 1. Third-party dependencies are static and build-only

```cmake
target_link_libraries(cpplib PRIVATE $<BUILD_LOCAL_INTERFACE:fmt::fmt>)
```

- **Static:** vcpkg builds `fmt` as a static library. The default Linux triplet is
  static, and on Windows the presets pick a `*-static*` triplet (see 3). fmt's code
  is linked into whatever links cpplib, so no `fmt.dll` / `libfmt.so` is ever shipped.
- **`PRIVATE`:** fmt is an implementation detail. It never shows up in cpplib's public
  headers or in the usage requirements of targets that link cpplib.
- **`$<BUILD_LOCAL_INTERFACE:...>`:** fmt is used inside this build but is not written
  into the installed CMake package. `cpplibConfig.cmake` therefore has no
  `find_dependency()`. A project that uses the installed cpplib needs nothing but
  cpplib.

Every new third-party dependency should follow the same pattern: add it to
`vcpkg.json`, then `find_package()` it and link it
`PRIVATE $<BUILD_LOCAL_INTERFACE:...>`.

Libraries that are only available as DLLs are deliberately not covered. How such a
library has to be located, redistributed and loaded depends entirely on its vendor,
so no general template solution exists. If you need one, add explicit install rules
for exactly those files.

### 2. The delivery mode is chosen by the preset, not by a second application

There is one application, and it can be delivered in two ways:

| Delivery mode | Presets | `BUILD_SHARED_LIBS` | What ships |
|---|---|---|---|
| **shared** (default) | `conf-<compiler>-<config>` | `ON` | `cpplib_app` + `cpplib.dll` / `libcpplib.so.0` (+ MSVC runtime DLLs), and the library SDK |
| **standalone** | `conf-<compiler>-release-standalone` | `OFF` | only the `cpplib_app` executable |

- **shared:** the application is the executable plus the project's *own* DLL. All
  third-party code is inside `cpplib.dll`. You can update the library without
  relinking the application, and other programs can use the SDK.
- **standalone:** cpplib and fmt are linked statically into the executable. A single
  file is all you ship.

The mode is a per-configure setting because the vcpkg triplet, and with it the
MSVC runtime of every third-party library, is chosen once per configure. One
build directory can't link the same `fmt` with two different runtimes.

### 3. MSVC runtime: `/MT` for standalone, `/MD` + app-local DLLs for shared

Every module in a process (the exe and each DLL) and every library linked into it
must use the same MSVC runtime (CRT). If they don't, linking fails with `LNK2038`.
The root `CMakeLists.txt` sets `CMAKE_MSVC_RUNTIME_LIBRARY` from the triplet that the
preset selects:

| Mode | vcpkg triplet | Third-party libs | CRT |
|---|---|---|---|
| standalone | `x64-windows-static` | static | static (`/MT`) |
| shared | `x64-windows-static-md` | static | dynamic (`/MD`) |

Why the static CRT for the standalone exe:
- It is a single module, so nothing else shares its runtime state.
- No Visual C++ Redistributable is needed. The `.exe` is the whole application.

Why the dynamic CRT for the exe + DLL mode:
- **One shared heap.** With `/MT`, every DLL gets its own copy of the CRT: its own
  heap, `errno`, locale, and `FILE*` table. Memory allocated in `cpplib.dll` would
  have to be freed in `cpplib.dll`. Passing a `std::string` or `std::vector` across
  the DLL boundary, which is natural for a C++ API, can then corrupt the heap. With
  `/MD`, all modules share one CRT and such APIs are safe (with the same toolset).
- **Servicing.** The Universal CRT is part of Windows 10 and later and is updated by
  Windows Update, not frozen into your binaries.
- **Compatibility.** `/MD` is the default of virtually all third-party binaries.
- **The cost:** `vcruntime140.dll`, `msvcp140.dll`, … must be shipped.
  `app/CMakeLists.txt` uses CMake's `InstallRequiredSystemLibraries` to install them
  next to the executable (app-local deployment, which Microsoft supports). The user
  doesn't have to install the Visual C++ Redistributable.

This is why most Windows applications ship the MSVC runtime. A single-file tool is
the case where `/MT` is the better choice.

### 4. The library SDK is installed from shared builds only

In shared builds, `cmake --install` installs the library SDK. It is used by other
projects through `find_package(cpplib)`. In static builds the SDK is not installed:
a static `cpplib` archive does not contain fmt, and fmt is deliberately not part of
the exported package (see 1). Static builds deliver the standalone application
instead.

### 5. Explicit install rules

Every installed file comes from an explicit `install()` rule in this project:
- the application (`app/CMakeLists.txt`);
- the library, its headers and its CMake package (`src/CMakeLists.txt`);
- the MSVC runtime (`InstallRequiredSystemLibraries`);
- the License.

The template does not use `install(RUNTIME_DEPENDENCY_SET)` to scan binaries and
copy whatever they happen to load. A package contains exactly what the project
declares. The delivery check (see 8) verifies that this list is complete.

### 6. Relocatable Linux installs

`cmake/project_preamble.cmake` sets the install RPATH to `$ORIGIN:$ORIGIN/../lib`.
The installed `bin/cpplib_app` finds `lib/libcpplib.so.0` relative to itself,
wherever the archive is extracted. No `LD_LIBRARY_PATH` is needed. On Windows,
executables and DLLs share one output and install directory (`bin`).

### 7. Hidden symbols and a generated export header

Symbols are hidden by default (`CMAKE_CXX_VISIBILITY_PRESET hidden`). Only functions
marked `CPPLIB_EXPORT`, from the generated `cpplib/cpplib_export.h`, form the ABI of
the shared library. This keeps the DLL interface small and gives GCC/Clang and MSVC
the same behavior.

### 8. Delivery is tested, not assumed

| Test | What it checks |
|---|---|
| `TestcpplibDelivery` (`test/test_delivery/`) | Installs the application's components into a temporary prefix. Checks that the installed files match the expected list for the delivery mode, runs the installed app, and checks with `file(GET_RUNTIME_DEPENDENCIES)` that it only depends on system libraries, cpplib and the MSVC runtime. A third-party DLL fails the test. |
| `TestcpplibInstall` (`test/test_install/`, shared only) | Installs the SDK. Builds a separate consumer project against it **without vcpkg**, and runs it. |
| Release `verify-packages` job | Installs the real DEBs in a clean `ubuntu:24.04` container and the MSI silently on Windows, runs the app from the TGZ and ZIP, and builds against the `-dev` DEB. A release is only published when this job passes. |

## Building and testing

Preset names follow `<step>-<compiler>-<config>[-<variant>]`:
- **steps:** `conf`, `build`, `test`, `package`, `workflow`
- **compilers:** `gcc`, `clang`, `msvc`
- **configs:** `debug`, `release`, `relwithdebinfo`, `minsizerel`
- **variants:**
  - `-standalone`: the standalone delivery mode, release only
  - `-asan`, `-tsan`, `-ubsan`: sanitizers, Linux only
  - `-coverage`

```sh
cmake --list-presets=all                               # everything available on this host
cmake --workflow --preset workflow-test-clang-debug    # configure + build + test
cmake --workflow --preset workflow-test-gcc-release-standalone
cmake --workflow --preset workflow-test-gcc-debug-asan
```

Options (default ON when cpplib is the top-level project):

| Option | Meaning |
|---|---|
| `cpplib_APP` | Build `cpplib_app` |
| `cpplib_TESTS` | Build the tests |
| `cpplib_TEST_INSTALL` | Register `TestcpplibInstall` (OFF in coverage builds) |
| `cpplib_INSTALL` | Generate install rules |
| `cpplib_PACK` | Configure CPack |
| `cpplib_USE_WARNINGS`, `cpplib_WARNINGS_AS_ERRORS` | Compiler warnings, as errors |
| `cpplib_STATIC_ANALYSIS` | clang-tidy (Clang) / MSVC code analysis |
| `cpplib_USE_SCCACHE`, `cpplib_USE_CPPCHECK`, `cpplib_BUILD_DOCUMENTATION` | Optional tooling (OFF by default) |

## Shipping the application

```sh
cmake --workflow --preset workflow-package-gcc-shared       # or -clang- / -msvc-
cmake --workflow --preset workflow-package-gcc-standalone
```

Packages land in `out/packages/package-<compiler>-release-<mode>/`, each with a
`.sha256` checksum.

| | shared | standalone |
|---|---|---|
| Linux TGZ | `cpplib-<ver>-linux-x86_64.tar.gz`: app, `libcpplib.so.0`, SDK | `cpplib-standalone-<ver>-linux-x86_64.tar.gz`: app |
| Linux DEB | `cpplib-app` → depends on `libcpplib0`; `libcpplib-dev` (SDK) | `cpplib-app-standalone` |
| Windows ZIP | `cpplib-<ver>-windows-x64.zip`: app, `cpplib.dll`, MSVC runtime, SDK | `cpplib-standalone-<ver>-windows-x64.zip`: app |
| Windows MSI | one installer: Application, Runtime Libraries, Development Files | one installer: Application |

The packages are assembled from three CPack components:

| Component | Content | Present in |
|---|---|---|
| `app` | `cpplib_app`; app-local MSVC runtime DLLs (Windows, shared); License (standalone) | both modes |
| `runtime` | `cpplib.dll` / `libcpplib.so.0*`, License | shared |
| `dev` | headers, import library / `libcpplib.so` link, CMake package | shared |

How each generator uses them:
- **TGZ and ZIP** contain all components of the build, ready to run.
- **DEB** creates one package per component, with `Depends:` between them.
- **The MSI** shows one feature per component. It uses the WixUI_Advanced dialogs
  (per-user or per-machine install) and adds `bin` to `PATH`.

The shared and standalone MSIs share one upgrade GUID, so installing one replaces
the other. The two app DEBs conflict with each other for the same reason: both
install `cpplib_app`.

## Using the library from another project

The shared packages contain the SDK (`libcpplib-dev`, or the `include`/`lib`
directories of the archives):

```cmake
find_package(cpplib 0 CONFIG REQUIRED)   # -DCMAKE_PREFIX_PATH=<extracted archive> when not installed to /usr
target_link_libraries(your_app PRIVATE cpplib::cpplib)
```

No vcpkg and no fmt are needed on the consumer side. To ship such an application,
install the cpplib runtime next to it:

```cmake
install(IMPORTED_RUNTIME_ARTIFACTS cpplib::cpplib RUNTIME DESTINATION bin LIBRARY DESTINATION lib)
```

`test/test_install/cpplib_install_test_template/` is a complete example.

## Making it your own

1. Rename the project:
   - `project(cpplib ...)` in `CMakeLists.txt` and `name` in `vcpkg.json`;
   - the `cpplib` namespace, the `src/include/cpplib/` directory, the `CPPLIB_EXPORT`
     macro and the `cpplib_app` target;
   - the `cpplib_*` options in the presets.
2. Replace the code in `src/` and `app/`, and add your tests under `test/`.
3. Add third-party libraries to `vcpkg.json` and link them
   `PRIVATE $<BUILD_LOCAL_INTERFACE:...>` (see design decision 1).
4. Update the package metadata in `cmake/packaging.cmake`: vendor, contact,
   description, homepage, package names.
5. Generate a new `CPACK_WIX_UPGRADE_GUID` (and new component GUIDs in
   `cmake/wix_patch.xml`). After the first release, never change the upgrade GUID
   again.
6. Replace `License` and `cmake/License.rtf`.
7. Bump the version in `CMakeLists.txt` and `vcpkg.json` together, then push a tag
   `vX.Y.Z` to release (see below).

## Releases and CI

| Workflow | Purpose |
|---|---|
| `ubuntu-build.yml`, `windows-build.yml` | Build and test on every push and pull request: debug and release in shared mode, plus release in standalone mode |
| `ubuntu-sanitizers.yml`, `ubuntu-coverage.yml`, `ubuntu-static-analysis.yml` | ASan/TSan/UBSan, coverage report, clang-tidy |
| `release.yml` | On a `v*` tag: checks that the tag, `CMakeLists.txt` and `vcpkg.json` versions match, builds the shared and standalone packages for Linux and Windows, verifies them (`verify-packages`) and publishes a GitHub Release with notes generated by git-cliff |
| `commit-messages.yml` | Enforces Conventional Commits |

See [CONTRIBUTING.md](CONTRIBUTING.md) for commit conventions, the local commit hook
and the release procedure. This project is public domain, see [License](License).
