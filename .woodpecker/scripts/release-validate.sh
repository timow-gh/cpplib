# Checks that the tag, CMakeLists.txt and vcpkg.json versions agree, with the rules and messages
# of Assert-ReleaseVersion in release-validate.ps1. The product identity is checked once, by the
# Windows release workflow; a release it refuses is never finalized.

. "$(dirname "${BASH_SOURCE[0]}")/ci-common.sh"

assert_prerequisites --require git jq

read_project_info
run_capture 'read the vcpkg.json version' jq -r '.version' vcpkg.json
manifest_version=$CAPTURED
if [[ $manifest_version != "$PROJECT_VERSION" ]]; then
    fail "vcpkg.json version $manifest_version does not match CMake version $PROJECT_VERSION"
fi

if [[ ${CI_PIPELINE_EVENT:-} == tag ]]; then
    tag=${CI_COMMIT_TAG:-}
    if [[ ! $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        fail "Release tags must use vMAJOR.MINOR.PATCH, got '$tag'"
    fi
    if [[ ${tag#v} != "$PROJECT_VERSION" ]]; then
        fail "Tag version ${tag#v} does not match CMake version $PROJECT_VERSION"
    fi
fi
printf 'Release version %s of %s\n' "$PROJECT_VERSION" "$PROJECT_NAME"
