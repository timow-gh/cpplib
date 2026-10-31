# Checks everything the Woodpecker workflows of this repository need from the Linux agent, in one
# run. Run it after setting up or changing the agent; the individual workflows check only what
# they use.

. "$(dirname "${BASH_SOURCE[0]}")/ci-common.sh"

# HOME is where the local backend points it for the steps; no cache may depend on it.
printf 'Agent: %s on %s, %s, bash %s, HOME=%s\n' "${CI_MACHINE:-}" "$(hostname)" \
    "$(. /etc/os-release && printf '%s' "$PRETTY_NAME")" "$BASH_VERSION" "$HOME"
# The tokens are Woodpecker secrets of the repository, not part of the agent, so the workflows
# that need them check them themselves.
assert_prerequisites --require git cmake ninja vcpkg-root gcc clang clang-rt clang-tidy gcov lcov \
    python3 curl jq dpkg forgejo-api --warn coverage-dir
