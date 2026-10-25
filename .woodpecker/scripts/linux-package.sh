# Builds, tests and packages one Linux delivery mode (TGZ + DEB); the Linux half of the
# build-packages job of .github/workflows/release.yml.
#
#   bash .woodpecker/scripts/linux-package.sh <shared|standalone>

. "$(dirname "${BASH_SOURCE[0]}")/ci-common.sh"

mode=${1:-}
if [[ $mode != shared && $mode != standalone ]]; then
    fail "Usage: linux-package.sh <shared|standalone>, got '$mode'"
fi

assert_prerequisites --require git cmake ninja vcpkg-root gcc dpkg

run_native 'package workflow' cmake --workflow --preset "workflow-package-gcc-$mode"

package_directory="out/packages/package-gcc-release-$mode"
printf 'Packages in %s:\n' "$package_directory"
find "$package_directory" -maxdepth 1 -type f -printf '  %f (%s bytes)\n' | sort
