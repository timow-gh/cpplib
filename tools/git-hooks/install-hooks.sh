#!/usr/bin/env sh

set -eu

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

chmod +x .githooks/commit-msg tools/git-hooks/check-conventional-commit.sh
git config core.hooksPath .githooks

echo "Configured Git hooks from .githooks"
