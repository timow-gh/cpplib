# Posts the coverage report of a pull request pipeline as a new comment on the pull request, with
# the run's files (coverage.json, coverage-summary.md, coverage-html.tar.gz) attached to that
# comment. Every run adds its own comment, so the pull request keeps the history of its runs and
# each comment links the files of exactly that run.
#
# Uses the secret forgejo_comment_token: a token of the CI bot account with the scope write:issue
# only. Pull request pipelines run the pull request's code, which can read the token; see
# .woodpecker/README.md#secrets. Runs after linux-coverage.sh in the same workspace.

. "$(dirname "${BASH_SOURCE[0]}")/ci-common.sh"

readonly OUTPUT_DIRECTORY='out/coverage'
readonly FILES=(coverage-summary.md coverage.json coverage-html.tar.gz)
# Lets tools and people find the coverage comments among the others.
readonly MARKER='<!-- coverage-report -->'

assert_prerequisites --require curl jq forgejo-comment-token

if [[ ${CI_PIPELINE_EVENT:-} != pull_request ]]; then
    fail 'The coverage comment is only posted for pull request pipelines'
fi
if [[ -z ${CI_COMMIT_PULL_REQUEST:-} ]]; then
    fail 'CI_COMMIT_PULL_REQUEST is not set for a pull request pipeline'
fi
for file in "${FILES[@]}"; do
    if [[ ! -f $OUTPUT_DIRECTORY/$file ]]; then
        fail "$OUTPUT_DIRECTORY/$file is missing; the coverage step writes it"
    fi
done

forgejo_base_url
readonly REPO_API="$FORGEJO_BASE_URL/api/v1/repos/$CI_REPO_OWNER/$CI_REPO_NAME"

# Sets COMMENT_BODY: the summary, then which run it belongs to, then the downloads (a list of
# links, or a placeholder until the files are attached).
compose_body() {
    local downloads=$1 commit=${CI_COMMIT_SHA:-unknown} run
    run="pipeline #${CI_PIPELINE_NUMBER:-?}"
    if [[ -n ${CI_PIPELINE_URL:-} ]]; then
        run="[$run]($CI_PIPELINE_URL)"
    fi
    COMMENT_BODY="$MARKER
$(<"$OUTPUT_DIRECTORY/coverage-summary.md")

Commit \`${commit:0:12}\`, $run.

**Files of this run:** $downloads"
}

# Sets REQUEST_FILE to a JSON file {"body": COMMENT_BODY}; jq does the escaping.
write_body_request() {
    REQUEST_FILE="$OUTPUT_DIRECTORY/comment-request.json"
    printf '%s' "$COMMENT_BODY" | jq -Rs '{body: .}' >"$REQUEST_FILE"
}

compose_body '_being attached…_'
write_body_request
forgejo_request POST "$REPO_API/issues/$CI_COMMIT_PULL_REQUEST/comments" "$FORGEJO_COMMENT_TOKEN" '' \
    -H 'Content-Type: application/json' --data-binary "@$REQUEST_FILE"
comment_id=$(jq -r '.id' <<<"$FORGEJO_RESPONSE")
comment_url=$(jq -r '.html_url' <<<"$FORGEJO_RESPONSE")
printf 'Posted the coverage comment: %s\n' "$comment_url"

links=''
for file in "${FILES[@]}"; do
    # 400/413/422 come back for a file type or size the instance does not accept.
    forgejo_request POST "$REPO_API/issues/comments/$comment_id/assets?name=$file" "$FORGEJO_COMMENT_TOKEN" \
        '400 413 422' -F "attachment=@$OUTPUT_DIRECTORY/$file"
    if [[ $FORGEJO_STATUS != 2?? ]]; then
        fail "[forgejo-api-failed] Forgejo refused the attachment $file (HTTP $FORGEJO_STATUS: $FORGEJO_RESPONSE); allow .md, .json and .gz and a large enough size in the [attachment] section (ALLOWED_TYPES, MAX_SIZE) of Forgejo's app.ini"
    fi
    download_url=$(jq -r '.browser_download_url' <<<"$FORGEJO_RESPONSE")
    links+="${links:+ · }[$file]($download_url)"
    printf 'Attached %s\n' "$file"
done

compose_body "$links"
write_body_request
forgejo_request PATCH "$REPO_API/issues/comments/$comment_id" "$FORGEJO_COMMENT_TOKEN" '' \
    -H 'Content-Type: application/json' --data-binary "@$REQUEST_FILE"
printf 'Linked the files in the coverage comment: %s\n' "$comment_url"
