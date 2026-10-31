#!/usr/bin/env sh

set -eu

# The commit message rules of this repository. They are written only here: the local commit-msg
# hook and the commit message checks of both CI systems run this script, and it prints the rules
# on --help and with every rejection.

VALID_TYPES="feat|fix|perf|docs|refactor|test|build|ci|chore|revert"
COMMIT_RE="^(${VALID_TYPES})(\([a-z0-9][a-z0-9._-]*\))?!?: .+"

print_rules() {
    cat <<EOF
Use Conventional Commits:
  type[(scope)][!]: short imperative summary

Allowed types:
  $(printf '%s' "$VALID_TYPES" | sed 's/|/, /g')

Recommended scopes (not enforced):
  api, core, app, cmake, package, ci, docs, tests

Breaking changes: put ! after the type or scope, or add a "BREAKING CHANGE:" footer.

Examples:
  feat(api): add an overload taking a string
  fix(package): ship the license in the standalone DEB
  ci(release): generate release notes from commits
  feat(api)!: rename libraryFunction
EOF
}

usage() {
    cat <<'EOF'
Usage:
  check-conventional-commit.sh --message-file <path>
  check-conventional-commit.sh --message <subject>
  check-conventional-commit.sh --range <git-range>

EOF
    print_rules
}

first_subject_from_file() {
    sed -n '/^[[:space:]]*#/d; /^[[:space:]]*$/d; s/^[[:space:]]*//; s/[[:space:]]*$//; p; q' "$1"
}

is_merge_subject() {
    case "$1" in
        Merge\ *|merge\ *)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

validate_subject() {
    subject="$1"

    if [ -z "$subject" ]; then
        echo "Commit message subject is empty." >&2
        return 1
    fi

    if is_merge_subject "$subject"; then
        return 0
    fi

    if printf '%s\n' "$subject" | grep -Eq "$COMMIT_RE"; then
        return 0
    fi

    {
        printf 'Invalid commit message:\n  %s\n\n' "$subject"
        print_rules
    } >&2
    return 1
}

validate_range() {
    range="$1"
    failed=0

    git log --format=%s "$range" | while IFS= read -r subject; do
        validate_subject "$subject" || failed=1
        if [ "$failed" -ne 0 ]; then
            exit "$failed"
        fi
    done
}

case "${1:-}" in
    --message-file)
        if [ $# -ne 2 ]; then
            usage >&2
            exit 2
        fi
        validate_subject "$(first_subject_from_file "$2")"
        ;;
    --message)
        if [ $# -ne 2 ]; then
            usage >&2
            exit 2
        fi
        validate_subject "$2"
        ;;
    --range)
        if [ $# -ne 2 ]; then
            usage >&2
            exit 2
        fi
        validate_range "$2"
        ;;
    -h|--help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
