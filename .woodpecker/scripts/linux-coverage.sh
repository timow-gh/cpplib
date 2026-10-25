# Builds and tests the coverage preset and writes the coverage report; the Woodpecker counterpart
# of .github/workflows/ubuntu-coverage.yml.
#
# Runs without a token, also for pull requests. The outputs land in out/coverage/
# (coverage.json, coverage-summary.md, coverage-html.tar.gz) and, if COVERAGE_REPORT_DIR is set,
# in <COVERAGE_REPORT_DIR>/<pr-N|branch>/<commit>/ on the agent host. coverage-publish.sh uploads
# them for pushes to main. A pull request is compared with the last upload of main, which it
# downloads anonymously.

. "$(dirname "${BASH_SOURCE[0]}")/ci-common.sh"

readonly BUILD_DIRECTORY='out/build/conf-gcc-coverage'
readonly OUTPUT_DIRECTORY='out/coverage'

# Writes the files the pull request changes against its target branch, one path per line.
write_changed_files() {
    local output_file=$1 target=${CI_COMMIT_TARGET_BRANCH:-}
    if [[ -z $target ]]; then
        fail 'CI_COMMIT_TARGET_BRANCH is not set for a pull request pipeline'
    fi
    # The clone may be shallow, but the diff starts at the merge base with the target branch.
    run_capture 'detect shallow clone' git rev-parse --is-shallow-repository
    if [[ $CAPTURED == true ]]; then
        run_native 'fetch full history' git fetch --unshallow --no-tags origin
    fi
    run_native 'fetch target branch' git fetch --no-tags origin "+refs/heads/$target:refs/remotes/origin/$target"
    run_capture 'find merge base' git merge-base "origin/$target" HEAD
    local merge_base=$CAPTURED
    run_capture 'list changed files' git diff --name-only "$merge_base" HEAD
    printf '%s\n' "$CAPTURED" >"$output_file"
}

# Downloads coverage.json of the last push to main. A missing baseline only costs the
# comparison, so it is a warning: coverage is informational, as on GitHub.
download_baseline() {
    local output_file=$1
    forgejo_base_url
    local url="$FORGEJO_BASE_URL/api/packages/$CI_REPO_OWNER/generic/$PACKAGE_NAME-coverage/main-latest/coverage.json"
    if curl -sSf --max-time 60 -o "$output_file" "$url"; then
        printf 'Baseline: %s\n' "$url"
        return 0
    fi
    rm -f "$output_file"
    printf '[warning] No coverage baseline of main at %s; the report shows no comparison. The package is uploaded by the first push to main, and must be readable without login.\n' "$url"
}

# Keeps the report on the agent host, the replacement for GitHub's workflow artifact.
copy_to_report_directory() {
    local key
    if [[ ${CI_PIPELINE_EVENT:-} == pull_request ]]; then
        key="pr-${CI_COMMIT_PULL_REQUEST:-unknown}"
    else
        key=${CI_COMMIT_BRANCH:-unknown}
    fi
    local destination="$COVERAGE_REPORT_DIR/$key/${CI_COMMIT_SHA:-unknown}"
    rm -rf "$destination"
    mkdir -p "$destination"
    cp "$OUTPUT_DIRECTORY/coverage.json" "$OUTPUT_DIRECTORY/coverage-summary.md" "$destination/"
    cp -r "$BUILD_DIRECTORY/coverage_html" "$destination/html"
    printf 'Report on the agent host: %s/html/index.html\n' "$destination"
}

assert_prerequisites --require git cmake ninja vcpkg-root gcc gcov lcov python3 curl --warn coverage-dir

# conf-gcc-coverage compiles with gcc-14; a gcov of another version makes lcov fail with "stamp
# mismatch". cmake/coverage.cmake takes an absolute GCOV as is, without a cached find_program().
GCOV=$(command -v gcov-14)
export GCOV
printf 'Using gcov: %s\n' "$GCOV"

with_retry 'configure' 5 30 run_native 'configure step' cmake --preset conf-gcc-coverage
run_native 'build step' cmake --build --preset build-gcc-coverage
run_native 'test step' ctest --preset test-gcc-coverage
run_native 'coverage report' cmake --build --preset build-gcc-coverage-report

read_project_info
rm -rf "$OUTPUT_DIRECTORY"
mkdir -p "$OUTPUT_DIRECTORY"
report_args=(
    --info "$BUILD_DIRECTORY/coverage_filtered.info"
    --source-root "$(pwd)"
    --output-directory "$OUTPUT_DIRECTORY"
    --commit "${CI_COMMIT_SHA:-}"
)
if [[ ${CI_PIPELINE_EVENT:-} == pull_request ]]; then
    write_changed_files "$OUTPUT_DIRECTORY/changed-files.txt"
    download_baseline "$OUTPUT_DIRECTORY/baseline.json"
    report_args+=(--pull-request "${CI_COMMIT_PULL_REQUEST:-}" --changed-files "$OUTPUT_DIRECTORY/changed-files.txt")
    if [[ -f $OUTPUT_DIRECTORY/baseline.json ]]; then
        report_args+=(--baseline "$OUTPUT_DIRECTORY/baseline.json")
    fi
fi
# -I: no user site packages and no imports from the workspace.
run_native 'write coverage report' python3 -I .woodpecker/scripts/coverage-report.py "${report_args[@]}"
run_native 'pack HTML report' tar czf "$OUTPUT_DIRECTORY/coverage-html.tar.gz" -C "$BUILD_DIRECTORY" coverage_html

if [[ -n ${COVERAGE_REPORT_DIR:-} ]]; then
    copy_to_report_directory
fi
