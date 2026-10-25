# Uploads the Linux packages into the draft Forgejo release of the tag; the Linux counterpart of
# release-publish.ps1. release-finalize.ps1 publishes the draft once the Windows packages are
# there too.

. "$(dirname "${BASH_SOURCE[0]}")/ci-common.sh"

assert_prerequisites --require curl jq forgejo-token forgejo-api

tag=${CI_COMMIT_TAG:-}
if [[ ${CI_PIPELINE_EVENT:-} != tag || -z $tag ]]; then
    fail 'Releases are only published for tag events'
fi
read_project_info

get_or_create_draft_release "$tag" "$PROJECT_VERSION"
mapfile -t assets < <(find out/packages/package-gcc-release-shared out/packages/package-gcc-release-standalone \
    -maxdepth 1 -type f | sort)
if ((${#assets[@]} == 0)); then
    fail 'No Linux packages in out/packages; the package steps create them'
fi
for asset in "${assets[@]}"; do
    publish_release_asset "$asset"
done
