#!/usr/bin/env sh

set -eu

# Publishes the private Forgejo main branch to the public GitHub mirror, one way and fast-forward
# only, so that a commit has the same hash on both and dependency pins by hash work on either.
# Both hosts are found from the URLs of the clone's remotes, because remote names differ between
# clones. The Forgejo address is deliberately not written here: this file is public.

# Git for Windows' sh rewrites arguments of the form a/b:c/d as Windows path lists, which breaks
# refspecs.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

# In a UTF-8 locale, grep would treat an author name in another encoding as binary data.
export LC_ALL=C

BRANCH="main"
SOURCE=""
TARGET=""
TAGS=""
PUSH=0

GITHUB_OWNER="timow-gh"

# An identity cannot be taken back once it is public, so a commit or tag with any other one is
# refused instead of only being listed. One "Name <address>" per line; the second is the committer
# Forgejo records for a squash merge.
ALLOWED_IDENTITIES="timow-gh <39085531+timow-gh@users.noreply.github.com>
timo <timo@noreply.localhost>"

usage() {
    cat <<EOF
Usage:
  sync-to-github.sh [--push] [--tag <tag>]... [--allow-identity <identity>]...
                    [--source <remote-or-url>] [--target <remote-or-url>]

Shows what would be published from the $BRANCH branch of Forgejo to the one of GitHub. Publishes it
with --push. Works from any clone: Forgejo is the clone's only remote that is not on GitHub, and
the GitHub repository of $GITHUB_OWNER with the same name is the target, even without a remote for it.

  --push             push instead of only showing what would be published
  --tag <tag>        also publish this tag of the source; repeatable. A v* tag starts the release
                     workflow on GitHub, so tags are never published unless named here
  --allow-identity <identity>
                     also accept this "Name <address>" for this run, such as an outside
                     contributor's; repeatable
  --source <remote-or-url>
                     where to publish from, if it cannot be found from the remotes
  --target <remote-or-url>
                     where to publish to, instead of the GitHub repository
EOF
}

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

is_github_url() {
    case "$1" in
        *github.com[:/]*) return 0 ;;
        *) return 1 ;;
    esac
}

is_owner_github_url() {
    case "$1" in
        # The ":/" form is what some clones of these repositories have.
        *github.com[:/]"$GITHUB_OWNER"/*|*github.com:/"$GITHUB_OWNER"/*) return 0 ;;
        *) return 1 ;;
    esac
}

url_of() {
    git remote get-url "$1" 2>/dev/null || printf '%s\n' "$1"
}

find_source_url() {
    candidates=""
    for remote in $(git remote); do
        is_github_url "$(url_of "$remote")" || candidates="$candidates $remote"
    done
    # Remote names contain no whitespace, so splitting the list is safe.
    # shellcheck disable=SC2086
    set -- $candidates
    [ "$#" -gt 0 ] || fail "this clone has no remote outside GitHub to publish from; add the Forgejo remote or pass --source"
    [ "$#" -eq 1 ] || fail "cannot tell which remote is Forgejo:$candidates; pass --source"
    url_of "$1"
}

repository_name() {
    name="${1%/}"
    name="${name%.git}"
    printf '%s\n' "${name##*[/:]}"
}

# Prefers a remote the clone already has, because that URL is the one with working credentials.
find_github_push_url() {
    for remote in $(git remote); do
        url="$(url_of "$remote")"
        if is_owner_github_url "$url" && [ "$(repository_name "$url")" = "$1" ]; then
            git remote get-url --push "$remote"
            return 0
        fi
    done
    printf 'git@github.com:%s/%s.git\n' "$GITHUB_OWNER" "$1"
}

# --no-tags and --no-prune keep fetch.pruneTags from deleting local tags that exist only on the
# other host.
fetch_tip() {
    git fetch --quiet --no-tags --no-prune "$1" "refs/heads/$BRANCH" || return 1
    git rev-parse "FETCH_HEAD^{commit}"
}

remote_tag_object() {
    git ls-remote --refs "$1" "refs/tags/$2" | cut -f1
}

# Prints the tag's object name on the source, so that an annotated tag is published as it is.
fetch_source_tag() {
    git fetch --quiet --no-tags --no-prune "$SOURCE_URL" "refs/tags/$1" ||
        fail "tag '$1' does not exist on the source; push it there first"
    git rev-parse FETCH_HEAD
}

# log.showSignature would otherwise add verification output to --format.
git_log() {
    git --no-pager -c log.showSignature=false log "$@"
}

# Arguments: the range of commits to publish, then the objects of the tags to publish.
published_identities() {
    git_log --format='%an <%ae>%n%cn <%ce>' "$1"
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

git rev-parse --git-dir >/dev/null 2>&1 || fail "run this inside a clone of the repository"

# A shallow history makes a real ancestor look like a split between the two hosts.
[ "$(git rev-parse --is-shallow-repository)" != "true" ] ||
    fail "this clone is shallow, so the histories cannot be compared; run git fetch --unshallow first"

if [ -n "$SOURCE" ]; then
    SOURCE_URL="$(url_of "$SOURCE")"
else
    SOURCE_URL="$(find_source_url)"
fi

if [ -n "$TARGET" ]; then
    TARGET_READ_URL="$(url_of "$TARGET")"
    TARGET_PUSH_URL="$TARGET_READ_URL"
else
    repository="$(repository_name "$SOURCE_URL")"
    # The mirror is public, so showing what would be published needs no GitHub credentials.
    TARGET_READ_URL="https://github.com/$GITHUB_OWNER/$repository.git"
    TARGET_PUSH_URL="$(find_github_push_url "$repository")"
fi

[ "$SOURCE_URL" != "$TARGET_READ_URL" ] || fail "source and target are both $SOURCE_URL"

echo "Source: $SOURCE_URL"
echo "Target: $TARGET_PUSH_URL"

source_tip="$(fetch_tip "$SOURCE_URL")" ||
    fail "could not read $BRANCH from $SOURCE_URL; this machine must reach Forgejo, or pass --source <remote-or-url>"
target_tip="$(fetch_tip "$TARGET_READ_URL")" ||
    fail "could not read $BRANCH from $TARGET_READ_URL; pass --target <remote-or-url> to use another one"

if ! git merge-base --is-ancestor "$target_tip" "$source_tip"; then
    printf 'Only on the target:\n' >&2
    git_log --format='  %h %s' "$source_tip..$target_tip" >&2
    fail "the target has commits that the source lacks. The sync is one way: bring them to the source first, nothing was pushed"
fi

# Refspecs are collected in the positional parameters so that the push is a single atomic one.
set --
new_tags=""
new_tag_objects=""
for tag in $TAGS; do
    tag_object="$(fetch_source_tag "$tag")"
    git merge-base --is-ancestor "$tag_object^{commit}" "$source_tip" ||
        fail "tag '$tag' is not on the source's $BRANCH, so it would publish unmerged commits"

    published_object="$(remote_tag_object "$TARGET_READ_URL" "$tag")"
    if [ "$published_object" = "$tag_object" ]; then
        continue
    fi
    [ -z "$published_object" ] || fail "tag '$tag' differs on the target; a published tag never moves"

    new_tags="$new_tags $tag"
    new_tag_objects="$new_tag_objects $tag_object"
    set -- "$@" "$tag_object:refs/tags/$tag"
done

if [ "$source_tip" != "$target_tip" ]; then
    set -- "$source_tip:refs/heads/$BRANCH" "$@"
fi

if [ "$#" -eq 0 ]; then
    echo "The target is up to date with the source"
    exit 0
fi

echo "Commits to publish to $BRANCH: $(git rev-list --count "$target_tip..$source_tip")"
git_log --format='  %h %s' "$target_tip..$source_tip"
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
    fail "these identities would become public permanently, nothing was pushed. Rewrite them on the source, or pass --allow-identity for one that is meant to be public"
fi

if [ "$PUSH" -eq 0 ]; then
    echo "Dry run, nothing was pushed. Publish with --push."
    exit 0
fi

# Deliberately not forced: the target itself rejects anything but a fast-forward.
git push --atomic "$TARGET_PUSH_URL" "$@" ||
    fail "could not push to $TARGET_PUSH_URL; this machine needs write access to it, or pass --target <remote-or-url>"
