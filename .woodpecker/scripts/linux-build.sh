# Configures, builds and tests one gcc or clang preset; the Woodpecker counterpart of
# .github/actions/ubuntu-build-steps. Arguments after the preset suffix go to the native build
# tool, e.g. `-k 0` so that ninja keeps going and clang-tidy reports as many issues as possible.
#
#   bash .woodpecker/scripts/linux-build.sh <preset suffix, e.g. gcc-debug> [ninja args...]

. "$(dirname "${BASH_SOURCE[0]}")/ci-common.sh"

suffix=${1:-}
shift || true

case $suffix in
gcc-*)
    prerequisites=(gcc)
    ;;
clang-*)
    # Every clang build runs clang-tidy (cpplib_STATIC_ANALYSIS is on by default).
    prerequisites=(clang clang-tidy)
    ;;
*)
    fail "Usage: linux-build.sh <gcc-*|clang-*> [ninja args...], got '$suffix'"
    ;;
esac
if [[ $suffix == *san ]]; then
    prerequisites+=(clang-rt)
fi
assert_prerequisites --require git cmake ninja vcpkg-root "${prerequisites[@]}"

# vcpkg may download source archives while configuring. The download hosts occasionally return
# transient errors, so retry the configure step with backoff.
with_retry 'configure' 5 30 run_native 'configure step' cmake --preset "conf-$suffix"
if (($# > 0)); then
    run_native 'build step' cmake --build --preset "build-$suffix" -- "$@"
else
    run_native 'build step' cmake --build --preset "build-$suffix"
fi
run_native 'test step' ctest --preset "test-$suffix"
