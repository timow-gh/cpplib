# Shared helpers for the Linux Woodpecker scripts; the bash counterpart of ci-common.ps1, with the
# same tagged log lines. Source it first: . "$(dirname "${BASH_SOURCE[0]}")/ci-common.sh"
#
# Helpers that can fail are never called inside $(...): a failure there would only end the
# subshell. They report through global variables instead, so that their exit ends the script.

set -Eeuo pipefail

# The agent's start script exports its own path, so fix hints can name the file to edit.
AGENT_SCRIPT=${WOODPECKER_AGENT_SCRIPT:-'the agent start script (run-agent.sh)'}
RESTART_HINT='then restart the agent (environment changes reach the steps only through the agent process)'

# A command that fails outside of run_native gets one readable line with its location, instead
# of bash ending the script silently.
trap 'printf "\n[error] %s exited with %s (%s:%s)\n" "$BASH_COMMAND" "$?" "${BASH_SOURCE[0]:-$0}" "$LINENO"' ERR

# Prints one `[error]` line and ends the script with exit code 1.
#
# Inside with_retry the message is printed without the tag: the attempt is retried, and only
# the final failure counts as an error for whoever greps the log.
fail() {
    if [[ -n ${CI_RETRYING:-} ]]; then
        printf '%s\n' "$*"
    else
        printf '\n[error] %s\n' "$*"
    fi
    exit 1
}

# Runs a command, streams its output and fails with `[command-failed]` on a non-zero exit code.
run_native() {
    local step=$1
    shift
    printf '> %s\n' "$*"
    local status=0
    "$@" || status=$?
    if ((status != 0)); then
        fail "[command-failed] $* exited with $status ($step)"
    fi
}

# Like run_native, but stores stdout in CAPTURED instead of logging it; stderr still goes to the
# log.
run_capture() {
    local step=$1
    shift
    local status=0
    CAPTURED=$("$@") || status=$?
    if ((status != 0)); then
        fail "[command-failed] $* exited with $status ($step)"
    fi
}

with_retry() {
    local description=$1 attempts=$2 backoff_seconds=$3
    shift 3
    local attempt status delay
    for ((attempt = 1; attempt < attempts; attempt++)); do
        status=0
        # A subshell, so that fail() ends only this attempt.
        (CI_RETRYING=1 && "$@") || status=$?
        if ((status == 0)); then
            return 0
        fi
        delay=$((attempt * backoff_seconds))
        printf '[retry] %s failed (attempt %s of %s)\n' "$description" "$attempt" "$attempts"
        printf '[retry] retrying in %s s\n' "$delay"
        sleep "$delay"
    done
    "$@"
}

# Absolute path, so the scripts can change directories without losing track of the workspace.
workspace_path() {
    WORKSPACE_PATH="$(pwd)/$1"
}

# --- Project ---------------------------------------------------------------------------------

# Sets PROJECT_NAME and PROJECT_VERSION from the root CMakeLists.txt, with the same rules as
# Get-ProjectInfo in ci-common.ps1, and PACKAGE_NAME, the lower-case name CPack uses for the
# packages (cmake/packaging.cmake).
read_project_info() {
    local cmake_lists
    cmake_lists=$(<CMakeLists.txt)
    local project_pattern=$'(^|\n)[[:space:]]*project[[:space:]]*\\([[:space:]]*([A-Za-z0-9_]+)([^)]*)\\)'
    if [[ ! $cmake_lists =~ $project_pattern ]]; then
        fail 'Could not find the project() call in CMakeLists.txt'
    fi
    PROJECT_NAME=${BASH_REMATCH[2]}
    local body=${BASH_REMATCH[3]}
    local version_pattern='(^|[^A-Za-z0-9_])VERSION[[:space:]]+([^[:space:]]+)'
    if [[ ! $body =~ $version_pattern ]]; then
        fail 'Could not read the CMake project version from CMakeLists.txt'
    fi
    PROJECT_VERSION=${BASH_REMATCH[2]}
    PACKAGE_NAME=${PROJECT_NAME,,}
}

# --- Forgejo API -----------------------------------------------------------------------------

# Base URL of Forgejo as seen from this agent.
#
# CI_FORGE_URL is the URL the Woodpecker server uses. When the server reaches Forgejo through a
# container-internal name the agent cannot resolve, FORGEJO_URL in the agent environment
# overrides it.
forgejo_base_url() {
    FORGEJO_BASE_URL=${FORGEJO_URL:-${CI_FORGE_URL:-}}
    if [[ -z $FORGEJO_BASE_URL ]]; then
        fail 'Neither FORGEJO_URL nor CI_FORGE_URL is set; cannot reach Forgejo'
    fi
    FORGEJO_BASE_URL=${FORGEJO_BASE_URL%/}
}

# Sends one request to Forgejo and stores the HTTP status in FORGEJO_STATUS and the response body
# in FORGEJO_RESPONSE. Fails unless the status is 2xx or one of the accepted statuses.
#
#   forgejo_request <method> <url> <token> <accepted statuses, e.g. "404 409" or ""> [curl args...]
#
# The token is the value of the Authorization header; an empty token sends an anonymous request.
forgejo_request() {
    local method=$1 url=$2 token=$3 accepted=$4
    shift 4
    local response_file
    response_file=$(mktemp)
    local -a auth=()
    if [[ -n $token ]]; then
        auth=(-H "Authorization: token $token")
    fi
    local status=0
    FORGEJO_STATUS=$(curl -sS --max-time 300 -o "$response_file" -w '%{http_code}' -X "$method" \
        -H 'Accept: application/json' "${auth[@]}" "$@" "$url") || status=$?
    FORGEJO_RESPONSE=$(<"$response_file")
    rm -f "$response_file"
    if ((status != 0)); then
        fail "[forgejo-api-failed] $method $url: curl exited with $status"
    fi
    if [[ $FORGEJO_STATUS == 2?? || " $accepted " == *" $FORGEJO_STATUS "* ]]; then
        return 0
    fi
    fail "[forgejo-api-failed] $method $url returned HTTP $FORGEJO_STATUS: $FORGEJO_RESPONSE"
}

# Calls the Forgejo REST API (/api/v1) with FORGEJO_TOKEN; see forgejo_request.
#
#   forgejo_api <method> <path> [<accepted statuses> [<JSON body>]]
forgejo_api() {
    local method=$1 path=$2 accepted=${3:-} body=${4:-}
    forgejo_base_url
    local -a data=()
    if [[ -n $body ]]; then
        data=(-H 'Content-Type: application/json' --data-binary "$body")
    fi
    forgejo_request "$method" "$FORGEJO_BASE_URL/api/v1/$path" "${FORGEJO_TOKEN:-}" "$accepted" "${data[@]}"
}

# --- Releases --------------------------------------------------------------------------------

# Sets RELEASE_JSON to the release of a tag, drafts included, or to an empty string.
#
# Lists the releases instead of asking for releases/tags/<tag>, which may not return drafts.
find_release() {
    local tag=$1 page
    RELEASE_JSON=''
    for ((page = 1; ; page++)); do
        forgejo_api GET "repos/$CI_REPO/releases?limit=50&page=$page"
        if [[ $(jq 'length' <<<"$FORGEJO_RESPONSE") == 0 ]]; then
            return 0
        fi
        RELEASE_JSON=$(jq -c --arg tag "$tag" 'map(select(.tag_name == $tag)) | first // empty' <<<"$FORGEJO_RESPONSE")
        if [[ -n $RELEASE_JSON ]]; then
            return 0
        fi
    done
}

# Sets RELEASE_JSON to the release of a tag, creating it as a draft if it does not exist yet.
#
# The Windows and the Linux release workflows run at the same time, and both may try to create
# the release; the one that loses gets 409 Conflict and reads the other's release.
# release-finalize.ps1 publishes the draft once both have uploaded their packages.
get_or_create_draft_release() {
    local tag=$1 version=$2
    find_release "$tag"
    if [[ -n $RELEASE_JSON ]]; then
        printf 'Reusing the existing release %s\n' "$(jq -r '.html_url' <<<"$RELEASE_JSON")"
        return 0
    fi
    local body
    body=$(jq -n --arg tag "$tag" --arg name "Release $version" \
        '{tag_name: $tag, name: $name, body: "", draft: true, prerelease: false}')
    forgejo_api POST "repos/$CI_REPO/releases" '409' "$body"
    if [[ $FORGEJO_STATUS == 409 ]]; then
        find_release "$tag"
        if [[ -z $RELEASE_JSON ]]; then
            fail "[forgejo-api-failed] creating the release for $tag returned 409, but no release for $tag exists"
        fi
        printf 'Reusing the release created by the other release workflow\n'
        return 0
    fi
    RELEASE_JSON=$FORGEJO_RESPONSE
    printf 'Created the draft release %s\n' "$(jq -r '.html_url' <<<"$RELEASE_JSON")"
}

# Uploads one file as a release asset, replacing an asset with the same name.
publish_release_asset() {
    local path=$1 name release_id existing_id
    name=$(basename "$path")
    release_id=$(jq -r '.id' <<<"$RELEASE_JSON")
    existing_id=$(jq -r --arg name "$name" '(.assets // []) | map(select(.name == $name)) | first | .id // empty' <<<"$RELEASE_JSON")
    if [[ -n $existing_id ]]; then
        forgejo_api DELETE "repos/$CI_REPO/releases/$release_id/assets/$existing_id"
        printf 'Replacing %s\n' "$name"
    fi
    forgejo_base_url
    forgejo_request POST "$FORGEJO_BASE_URL/api/v1/repos/$CI_REPO/releases/$release_id/assets?name=$(jq -rn --arg name "$name" '$name | @uri')" \
        "$FORGEJO_TOKEN" '' -F "attachment=@$path"
    printf 'Uploaded %s\n' "$name"
}

# --- Prerequisites ---------------------------------------------------------------------------

# Each check_<id> function (hyphens in the id become underscores) calls check_passed or
# check_failed as its last command. The problem and fix text is the only
# documentation of a prerequisite, so it has to be self-contained.
check_passed() {
    CHECK_DETAIL=$1
}

check_failed() {
    CHECK_PROBLEM=$1
    CHECK_CHECKED=$2
    CHECK_FIX=$3
    return 1
}

APT_HINT="install it on the agent machine (sudo apt-get install"

check_git() {
    command -v git >/dev/null || {
        check_failed 'git is not on the PATH of the agent process' 'command -v git' "$APT_HINT git)"
        return
    }
    check_passed "$(git --version) ($(command -v git))"
}

check_cmake() {
    command -v cmake >/dev/null || {
        check_failed 'cmake is not on the PATH of the agent process' 'command -v cmake' \
            "$APT_HINT cmake; Ubuntu 24.04 ships 3.28)"
        return
    }
    local version
    version=$(cmake --version | sed -n '1s/[^0-9]*\([0-9][0-9.]*\).*/\1/p')
    if [[ $(printf '%s\n' 3.28.0 "$version" | sort -V | head -n 1) != 3.28.0 ]]; then
        check_failed "CMake is too old: $version ($(command -v cmake)), CMakePresets.json requires >= 3.28" 'cmake --version' \
            "install CMake >= 3.28 (Ubuntu 24.04: sudo apt-get install cmake) and make sure it comes first on PATH in $AGENT_SCRIPT, $RESTART_HINT"
        return
    fi
    check_passed "cmake $version (>= 3.28) ($(command -v cmake))"
}

check_ninja() {
    command -v ninja >/dev/null || {
        check_failed 'ninja is not on the PATH of the agent process; the gcc and clang presets use the Ninja generator' \
            'command -v ninja' "$APT_HINT ninja-build)"
        return
    }
    check_passed "ninja $(ninja --version) ($(command -v ninja))"
}

# Prints the version of the compiler that a plain name (as the presets use it) resolves to.
compiler_detail() {
    printf '%s -> %s (%s)' "$1" "$(readlink -f "$(command -v "$1")")" "$("$1" --version | head -n 1)"
}

check_gcc() {
    local tool
    for tool in gcc g++; do
        command -v "$tool" >/dev/null || {
            check_failed "$tool is not on the PATH of the agent process" "command -v $tool" \
                "$APT_HINT gcc-14 g++-14) and link gcc/g++ to gcc-14/g++-14 in the pin directory on PATH in $AGENT_SCRIPT, $RESTART_HINT"
            return
        }
    done
    check_passed "$(compiler_detail gcc), $(compiler_detail g++)"
}

check_clang() {
    local tool
    for tool in clang clang++; do
        command -v "$tool" >/dev/null || {
            check_failed "$tool is not on the PATH of the agent process" "command -v $tool" \
                "$APT_HINT clang-20) and link clang/clang++ to clang-20/clang++-20 in the pin directory on PATH in $AGENT_SCRIPT, $RESTART_HINT"
            return
        }
    done
    check_passed "$(compiler_detail clang), $(compiler_detail clang++)"
}

# The sanitizer presets link the clang runtime, which is a separate package.
check_clang_rt() {
    local directory
    directory=$(mktemp -d)
    if ! printf 'int main() { return 0; }\n' | clang -x c -fsanitize=address,undefined -o "$directory/probe" - >/dev/null 2>&1 ||
        ! printf 'int main() { return 0; }\n' | clang -x c -fsanitize=thread -o "$directory/probe" - >/dev/null 2>&1; then
        rm -rf "$directory"
        check_failed 'clang cannot link a sanitizer program; the clang sanitizer runtime is missing' \
            'clang -fsanitize=address,undefined / -fsanitize=thread on an empty program' \
            "$APT_HINT libclang-rt-20-dev, matching the clang version)"
        return
    fi
    rm -rf "$directory"
    check_passed 'clang links ASan, UBSan and TSan programs'
}

# cmake/static_analysis.cmake looks for clang-tidy-<clang major> first, then clang-tidy, and
# fails the configure step if neither exists. Every clang build runs it.
check_clang_tidy() {
    local major tidy
    major=$(clang -dumpversion 2>/dev/null | cut -d. -f1) || major=''
    # Without clang the hint would name "clang-tidy-"; the pinned version is what the setup installs.
    major=${major:-20}
    tidy=$(command -v "clang-tidy-$major" 2>/dev/null || command -v clang-tidy 2>/dev/null) || {
        check_failed "Neither clang-tidy-$major nor clang-tidy is on the PATH; every clang build runs clang-tidy (cpplib_STATIC_ANALYSIS)" \
            "command -v clang-tidy-$major clang-tidy" "$APT_HINT clang-tidy-$major)"
        return
    }
    check_passed "$("$tidy" --version | grep -m 1 -i 'version' | sed 's/^ *//') ($tidy)"
}

check_vcpkg_root() {
    local fix="git clone https://github.com/microsoft/vcpkg ~/vcpkg (on the Linux filesystem; in WSL not below /mnt/c), run ~/vcpkg/bootstrap-vcpkg.sh, add export VCPKG_ROOT=~/vcpkg to $AGENT_SCRIPT, $RESTART_HINT"
    if [[ -z ${VCPKG_ROOT:-} ]]; then
        check_failed 'VCPKG_ROOT is not set in the agent environment' '$VCPKG_ROOT' "$fix"
        return
    fi
    if [[ ! -f $VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake ]]; then
        check_failed "VCPKG_ROOT='$VCPKG_ROOT' does not contain a vcpkg checkout" "test -f $VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" "$fix"
        return
    fi
    if [[ ! -x $VCPKG_ROOT/vcpkg ]]; then
        check_failed "vcpkg in '$VCPKG_ROOT' is not bootstrapped (vcpkg missing)" "test -x $VCPKG_ROOT/vcpkg" \
            "run $VCPKG_ROOT/bootstrap-vcpkg.sh once"
        return
    fi
    check_passed "vcpkg at $VCPKG_ROOT"
}

# conf-gcc-coverage compiles with gcc-14, and lcov needs the gcov of exactly that version.
check_gcov() {
    local tool
    for tool in gcc-14 g++-14 gcov-14; do
        command -v "$tool" >/dev/null || {
            check_failed "$tool is not on the PATH; the coverage preset compiles with gcc-14 and lcov needs the matching gcov-14" \
                "command -v $tool" "$APT_HINT gcc-14 g++-14)"
            return
        }
    done
    check_passed "$(gcov-14 --version | head -n 1) ($(command -v gcov-14))"
}

check_lcov() {
    local tool
    for tool in lcov genhtml; do
        command -v "$tool" >/dev/null || {
            check_failed "$tool is not on the PATH; cmake/coverage.cmake needs it" "command -v $tool" "$APT_HINT lcov)"
            return
        }
    done
    check_passed "$(lcov --version | head -n 1) ($(command -v lcov))"
}

check_python3() {
    command -v python3 >/dev/null || {
        check_failed 'python3 is not on the PATH; it writes the coverage report' 'command -v python3' "$APT_HINT python3)"
        return
    }
    check_passed "$(python3 --version) ($(command -v python3))"
}

check_curl() {
    command -v curl >/dev/null || {
        check_failed 'curl is not on the PATH; it talks to the Forgejo API' 'command -v curl' "$APT_HINT curl)"
        return
    }
    check_passed "$(curl --version | head -n 1)"
}

check_jq() {
    command -v jq >/dev/null || {
        check_failed 'jq is not on the PATH; it reads the Forgejo API responses' 'command -v jq' "$APT_HINT jq)"
        return
    }
    check_passed "$(jq --version) ($(command -v jq))"
}

# CPack computes the Depends of the DEB packages with dpkg-shlibdeps (CPACK_DEBIAN_PACKAGE_SHLIBDEPS);
# the verification unpacks them with dpkg-deb and simulates their installation with apt-get.
check_dpkg() {
    local tool
    for tool in dpkg-deb dpkg-shlibdeps apt-get; do
        command -v "$tool" >/dev/null || {
            check_failed "$tool is not on the PATH; the DEB packages are built and checked with it" "command -v $tool" \
                "$APT_HINT dpkg-dev); the agent must run in a Debian or Ubuntu distribution"
            return
        }
    done
    check_passed "$(dpkg-deb --version | head -n 1)"
}

check_coverage_dir() {
    local fix="add export COVERAGE_REPORT_DIR=~/woodpecker-agent/coverage to $AGENT_SCRIPT, $RESTART_HINT"
    if [[ -z ${COVERAGE_REPORT_DIR:-} ]]; then
        check_failed 'COVERAGE_REPORT_DIR is not set; the coverage reports are not kept on the agent host' '$COVERAGE_REPORT_DIR' "$fix"
        return
    fi
    if ! mkdir -p "$COVERAGE_REPORT_DIR" 2>/dev/null || [[ ! -w $COVERAGE_REPORT_DIR ]]; then
        check_failed "COVERAGE_REPORT_DIR='$COVERAGE_REPORT_DIR' is not writable by the agent user" "mkdir -p $COVERAGE_REPORT_DIR" "$fix"
        return
    fi
    check_passed "coverage reports in $COVERAGE_REPORT_DIR"
}

check_forgejo_token() {
    if [[ -z ${FORGEJO_TOKEN:-} ]]; then
        check_failed 'FORGEJO_TOKEN is empty' '$FORGEJO_TOKEN (Woodpecker secret forgejo_token)' \
            'create a Forgejo access token and add it in Woodpecker as the repository secret forgejo_token; its scopes and events are listed in .woodpecker/README.md#secrets'
        return
    fi
    check_passed 'FORGEJO_TOKEN is set'
}

check_forgejo_package_token() {
    if [[ -z ${FORGEJO_PACKAGE_TOKEN:-} ]]; then
        check_failed 'FORGEJO_PACKAGE_TOKEN is empty' '$FORGEJO_PACKAGE_TOKEN (Woodpecker secret forgejo_package_token)' \
            'create a Forgejo access token and add it in Woodpecker as the repository secret forgejo_package_token; its scope and events are listed in .woodpecker/README.md#secrets'
        return
    fi
    check_passed 'FORGEJO_PACKAGE_TOKEN is set'
}

check_forgejo_comment_token() {
    if [[ -z ${FORGEJO_COMMENT_TOKEN:-} ]]; then
        check_failed 'FORGEJO_COMMENT_TOKEN is empty' '$FORGEJO_COMMENT_TOKEN (Woodpecker secret forgejo_comment_token)' \
            'create a token of the CI bot account and add it in Woodpecker as the repository secret forgejo_comment_token; its scope and events are listed in .woodpecker/README.md#secrets'
        return
    fi
    check_passed 'FORGEJO_COMMENT_TOKEN is set'
}

check_forgejo_api() {
    local fix="make sure this machine can reach Forgejo; if CI_FORGE_URL ('${CI_FORGE_URL:-}') is an address only the Woodpecker server can resolve, set export FORGEJO_URL=http://<nas-ip>:<port> in $AGENT_SCRIPT, $RESTART_HINT"
    local base=${FORGEJO_URL:-${CI_FORGE_URL:-}}
    if [[ -z $base ]]; then
        check_failed 'Neither FORGEJO_URL nor CI_FORGE_URL is set' '$FORGEJO_URL, $CI_FORGE_URL' "$fix"
        return
    fi
    local url="${base%/}/api/v1/version" version
    version=$(curl -sS --max-time 30 -f "$url" 2>&1 | jq -r '.version' 2>/dev/null) || version=''
    if [[ -z $version || $version == null ]]; then
        check_failed "The Forgejo API is not reachable from this agent" "GET $url" "$fix"
        return
    fi
    check_passed "Forgejo $version at ${base%/}/api/v1"
}

# Checks what a script needs from the agent before it does any work.
#
#   assert_prerequisites --require <id>... [--warn <id>...]
#
# Runs every requested check instead of stopping at the first failure, so one run lists
# everything that is missing. Each failure is printed as a `[prerequisite-missing] id=<id>`
# block with problem, what was checked, and a concrete fix, the same format as
# Assert-Prerequisites in ci-common.ps1. Exits with code 2 if a required check fails; checks
# passed after --warn are reported the same way but never fail the step.
assert_prerequisites() {
    local required=true required_count=0 failed_count=0 id check label
    for id in "$@"; do
        case $id in
        --require)
            required=true
            continue
            ;;
        --warn)
            required=false
            continue
            ;;
        esac
        check="check_${id//-/_}"
        if ! declare -F "$check" >/dev/null; then
            fail "Unknown prerequisite id '$id'"
        fi
        if [[ $required == true ]]; then
            required_count=$((required_count + 1))
        fi
        if "$check"; then
            printf '[prerequisite-ok] %s: %s\n' "$id" "$CHECK_DETAIL"
            continue
        fi
        if [[ $required == true ]]; then
            label=prerequisite-missing
            failed_count=$((failed_count + 1))
        else
            label=prerequisite-warning
        fi
        printf '[%s] id=%s\n' "$label" "$id"
        printf '  problem:  %s\n' "$CHECK_PROBLEM"
        printf '  checked:  %s\n' "$CHECK_CHECKED"
        printf '  fix:      %s\n' "$CHECK_FIX"
    done
    if ((failed_count > 0)); then
        printf "[prerequisites] %s of %s required checks failed - the agent '%s' is not set up for this workflow\n" \
            "$failed_count" "$required_count" "${CI_MACHINE:-$(hostname)}"
        exit 2
    fi
}
