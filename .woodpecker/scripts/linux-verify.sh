# Checks the packages of one Linux delivery mode the way a user would use them; the Linux half of
# the verify-packages job of .github/workflows/release.yml.
#
# Unlike a GitHub runner, the agent is a machine someone works on, and the agent user has no root
# rights. So nothing is installed into the system: apt only simulates the installation of the DEB
# packages (dependencies, conflicts), and the app and the SDK are used from the unpacked DEB files
# instead of /usr.
#
#   bash .woodpecker/scripts/linux-verify.sh <shared|standalone>

. "$(dirname "${BASH_SOURCE[0]}")/ci-common.sh"

# Sets SINGLE_PACKAGE to the one file in a directory that matches a glob.
find_single_package() {
    local directory=$1 pattern=$2
    local -a files
    mapfile -t files < <(find "$directory" -maxdepth 1 -type f -name "$pattern")
    if ((${#files[@]} != 1)); then
        fail "Expected exactly one $pattern in $directory, found ${#files[@]}"
    fi
    SINGLE_PACKAGE=${files[0]}
}

test_tgz_package() {
    local package_directory=$1 work_directory=$2
    find_single_package "$package_directory" '*.tar.gz'
    local archive_directory="$work_directory/tgz"
    mkdir -p "$archive_directory"
    run_native 'unpack the TGZ' tar xzf "$SINGLE_PACKAGE" -C "$archive_directory" --strip-components=1
    run_native 'run the app from the TGZ' "$archive_directory/bin/${PROJECT_NAME}_app"
}

test_deb_packages() {
    local package_directory=$1 work_directory=$2
    local -a debs
    mapfile -t debs < <(find "$package_directory" -maxdepth 1 -type f -name '*.deb' | sort)
    if ((${#debs[@]} == 0)); then
        fail "No DEB packages in $package_directory"
    fi
    local deb
    for deb in "${debs[@]}"; do
        run_native 'show the DEB metadata' dpkg-deb --info "$deb"
        run_native 'list the DEB contents' dpkg-deb --contents "$deb"
    done

    # Resolves Depends and Conflicts against this machine's package database without changing it.
    # apt only treats an argument as a file if it contains a slash.
    local -a deb_paths=()
    for deb in "${debs[@]}"; do
        deb_paths+=("$(realpath "$deb")")
    done
    run_native 'simulate installing the DEB packages' apt-get install --simulate --no-install-recommends "${deb_paths[@]}"

    local deb_root="$work_directory/deb-root"
    mkdir -p "$deb_root"
    for deb in "${debs[@]}"; do
        run_native 'unpack the DEB' dpkg-deb --extract "$deb" "$deb_root"
    done
    # The app finds libcpplib through its RPATH ($ORIGIN/../lib), so it runs from the unpacked tree.
    run_native 'run the app from the DEB' "$deb_root/usr/bin/${PROJECT_NAME}_app"
}

# Builds test/test_install/consumer against the unpacked SDK DEB, without vcpkg: the SDK must be
# self-contained. GitHub installs the DEB into /usr instead and needs no CMAKE_PREFIX_PATH.
test_sdk_package() {
    local work_directory=$1
    local deb_root="$work_directory/deb-root"
    local consumer_build="$work_directory/consumer-build"
    run_native 'configure the SDK consumer' cmake -S test/test_install/consumer -B "$consumer_build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release "-DPACKAGE_NAME=$PROJECT_NAME" "-DCMAKE_PREFIX_PATH=$deb_root/usr"
    run_native 'build the SDK consumer' cmake --build "$consumer_build"
    run_native 'run the SDK consumer' "$consumer_build/consumer"
}

mode=${1:-}
if [[ $mode != shared && $mode != standalone ]]; then
    fail "Usage: linux-verify.sh <shared|standalone>, got '$mode'"
fi

assert_prerequisites --require cmake ninja gcc dpkg

read_project_info
workspace_path "out/packages/package-gcc-release-$mode"
package_directory=$WORKSPACE_PATH
workspace_path "out/release/verify-$mode"
work_directory=$WORKSPACE_PATH
rm -rf "$work_directory"
mkdir -p "$work_directory"

test_tgz_package "$package_directory" "$work_directory"
test_deb_packages "$package_directory" "$work_directory"
if [[ $mode == shared ]]; then
    test_sdk_package "$work_directory"
fi
