# Uploads the coverage report of a push to main to the Forgejo generic package registry, as
# package <name>-coverage in the versions <commit> (history) and main-latest (the baseline that
# pull requests compare with).
#
# Uses the secret forgejo_package_token (scope write:package only), never the release token:
# Woodpecker filters secrets by event, not by branch, so any push pipeline could request it.

. "$(dirname "${BASH_SOURCE[0]}")/ci-common.sh"

readonly OUTPUT_DIRECTORY='out/coverage'
readonly FILES=(coverage.json coverage-summary.md coverage-html.tar.gz)

assert_prerequisites --require curl forgejo-package-token

if [[ ${CI_PIPELINE_EVENT:-} != push || ${CI_COMMIT_BRANCH:-} != main ]]; then
    fail 'The coverage report is only uploaded for pushes to main'
fi
for file in "${FILES[@]}"; do
    if [[ ! -f $OUTPUT_DIRECTORY/$file ]]; then
        fail "$OUTPUT_DIRECTORY/$file is missing; the coverage step writes it"
    fi
done

read_project_info
forgejo_base_url
package_url="$FORGEJO_BASE_URL/api/packages/$CI_REPO_OWNER/generic/$PACKAGE_NAME-coverage"

for version in "$CI_COMMIT_SHA" main-latest; do
    # Files of a generic package cannot be overwritten, so a version is replaced as a whole.
    forgejo_request DELETE "$package_url/$version" "$FORGEJO_PACKAGE_TOKEN" '404'
    for file in "${FILES[@]}"; do
        forgejo_request PUT "$package_url/$version/$file" "$FORGEJO_PACKAGE_TOKEN" '' \
            --upload-file "$OUTPUT_DIRECTORY/$file"
    done
    printf 'Uploaded the coverage report as %s %s\n' "$PACKAGE_NAME-coverage" "$version"
done
