#!/usr/bin/env sh

set -eu

# Publishes the private Forgejo main branch to the public GitHub mirror, one way and fast-forward
# only, so that a commit has the same hash on both and dependency pins by hash work on either.
# Nothing here names a repository: per-repository differences belong in the options.

# Git for Windows' sh rewrites arguments of the form a/b:c/d as Windows path lists, which breaks
# refspecs.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

BRANCH="main"
SOURCE="jatinas"
TARGET="origin"
TAGS=""
PUSH=0

# An identity cannot be taken back once it is public, so a commit or tag with any other one is
# refused instead of only being listed. One "Name <address>" per line; the second is the committer
# Forgejo records for a squash merge.
ALLOWED_IDENTITIES="timow-gh <39085531+timow-gh@users.noreply.github.com>
timo <timo@noreply.localhost>"

usage() {
    cat <<EOF
Usage:
  sync-to-github.sh [--push] [--tag <tag>]... [--allow-identity <identity>]...
                    [--source <remote>] [--target <remote>]

Shows what would be published from <source>/$BRANCH to <target>/$BRANCH. Publishes it with --push.

  --push             push instead of only showing what would be published
  --tag <tag>        also publish this tag of <source>; repeatable. A v* tag starts the release
                     workflow on GitHub, so tags are never published unless named here
  --allow-identity <identity>
                     also accept this "Name <address>" for this run, such as an outside
                     contributor's; repeatable
  --source <remote>  remote that is the source of truth (default: $SOURCE)
  --target <remote>  remote to publish to (default: $TARGET)
EOF
}

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

require_remote() {
    git remote get-url "$1" >/dev/null 2>&1 || fail "there is no remote named '$1'; see --help"
}

# Explicit refspecs and --no-tags keep fetch.pruneTags from deleting local tags that exist only on
# the other remote.
fetch_branch() {
    git fetch --quiet --no-tags --no-prune "$1" "+refs/heads/$BRANCH:refs/remotes/$1/$BRANCH" ||
        fail "could not fetch $BRANCH from '$1'"
}

remote_tag_object() {
    git ls-remote --refs "$1" "refs/tags/$2" | cut -f1
}

# Prints the tag's object name on the source, so that an annotated tag is published as it is.
fetch_source_tag() {
    git fetch --quiet --no-tags --no-prune "$SOURCE" "refs/tags/$1" ||
        fail "tag '$1' does not exist on '$SOURCE'; push it there first"
    git rev-parse FETCH_HEAD
}

# Arguments: the range of commits to publish, then the objects of the tags to publish.
published_identities() {
    git --no-pager log --format='%an <%ae>%n%cn <%ce>' "$1"
    shift
    for object in "$@"; do
        [ "$(git cat-file -t "$object")" = "tag" ] || continue
        git cat-file tag "$object" | sed -n 's/^tagger \(.*>\) [0-9].*$/\1/p; /^$/q'
    done
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --push)
            PUSH=1
            ;;
        --tag|--allow-identity|--source|--target)
            [ "$#" -ge 2 ] || fail "$1 needs a value"
            case "$1" in
                --tag)
                    git check-ref-format "refs/tags/$2" || fail "'$2' is not a valid tag name"
                    TAGS="$TAGS $2"
                    ;;
                --allow-identity)
                    ALLOWED_IDENTITIES="$ALLOWED_IDENTITIES
$2"
                    ;;
                --source) SOURCE="$2" ;;
                --target) TARGET="$2" ;;
            esac
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            fail "unknown argument: $1"
            ;;
    esac
    shift
done

[ "$SOURCE" != "$TARGET" ] || fail "source and target are both '$SOURCE'"
require_remote "$SOURCE"
require_remote "$TARGET"

fetch_branch "$SOURCE"
fetch_branch "$TARGET"
source_tip="$(git rev-parse "refs/remotes/$SOURCE/$BRANCH^{commit}")"
target_tip="$(git rev-parse "refs/remotes/$TARGET/$BRANCH^{commit}")"

if ! git merge-base --is-ancestor "$target_tip" "$source_tip"; then
    printf 'Only on %s/%s:\n' "$TARGET" "$BRANCH" >&2
    git --no-pager log --format='  %h %s' "$source_tip..$target_tip" >&2
    fail "$TARGET/$BRANCH has commits that $SOURCE/$BRANCH lacks. The sync is one way: bring them to $SOURCE first, nothing was pushed"
fi

# Refspecs are collected in the positional parameters so that the push is a single atomic one.
set --
new_tags=""
new_tag_objects=""
for tag in $TAGS; do
    tag_object="$(fetch_source_tag "$tag")"
    git merge-base --is-ancestor "$tag_object^{commit}" "$source_tip" ||
        fail "tag '$tag' is not on $SOURCE/$BRANCH, so it would publish unmerged commits"

    published_object="$(remote_tag_object "$TARGET" "$tag")"
    if [ "$published_object" = "$tag_object" ]; then
        continue
    fi
    [ -z "$published_object" ] || fail "tag '$tag' differs on '$TARGET'; a published tag never moves"

    new_tags="$new_tags $tag"
    new_tag_objects="$new_tag_objects $tag_object"
    set -- "$@" "$tag_object:refs/tags/$tag"
done

if [ "$source_tip" != "$target_tip" ]; then
    set -- "$source_tip:refs/heads/$BRANCH" "$@"
fi

if [ "$#" -eq 0 ]; then
    echo "$TARGET is up to date with $SOURCE/$BRANCH"
    exit 0
fi

echo "Commits to publish to $TARGET/$BRANCH: $(git rev-list --count "$target_tip..$source_tip")"
git --no-pager log --format='  %h %s' "$target_tip..$source_tip"
echo "Tags to publish:${new_tags:- none}"

# Object names contain no whitespace, so splitting the list is safe.
# shellcheck disable=SC2086
identities="$(published_identities "$target_tip..$source_tip" $new_tag_objects | sort -u)"
echo "Identities that become public with them:"
printf '%s\n' "$identities" | sed 's/^/  /'

rejected="$(printf '%s\n' "$identities" | grep -Fxv -e "$ALLOWED_IDENTITIES" || true)"
if [ -n "$rejected" ]; then
    printf 'Not allowed:\n' >&2
    printf '%s\n' "$rejected" | sed 's/^/  /' >&2
    fail "these identities would become public permanently, nothing was pushed. Rewrite them on $SOURCE, or pass --allow-identity for one that is meant to be public"
fi

if [ "$PUSH" -eq 0 ]; then
    echo "Dry run, nothing was pushed. Publish with --push."
    exit 0
fi

# Deliberately not forced: the target itself rejects anything but a fast-forward.
git push --atomic "$TARGET" "$@"
