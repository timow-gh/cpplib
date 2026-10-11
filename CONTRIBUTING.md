# Contributing

## Commit Messages

This repository uses Conventional Commits so release notes can be generated from
Git history when a `v*` tag is pushed.

Use this subject format:

```text
type[(scope)][!]: short imperative summary
```

Allowed types:

```text
feat, fix, perf, docs, refactor, test, build, ci, chore, revert
```

Recommended scopes for this repository:

```text
api, core, app, cmake, package, ci, docs, tests
```

Examples:

```text
feat(api): add camera auto-fit option
fix(opengl): restore transparency sorting
ci(release): generate release notes from commits
feat(api)!: rename public camera enum
```

Use `!` after the type or scope for breaking changes. You can also add a
`BREAKING CHANGE:` footer in the commit body.

## Local Commit Hook

Git validates final commit messages with the `commit-msg` hook. This is the
right hook for commit-message validation because `pre-commit` runs before Git
has the final message.

Install the tracked hooks:

```sh
tools/git-hooks/install-hooks.sh
```

On Windows PowerShell:

```powershell
tools/git-hooks/install-hooks.ps1
```

The installer runs:

```sh
git config core.hooksPath .githooks
```

To transfer this approach to another repository, copy these paths:

```text
.githooks/commit-msg
tools/git-hooks/check-conventional-commit.sh
tools/git-hooks/install-hooks.sh
tools/git-hooks/install-hooks.ps1
.github/workflows/commit-messages.yml
cliff.toml
```

Then adjust the allowed scopes and release workflow names for that repository.

## Releases

Releases are created by pushing tags that start with `v`, for example:

```sh
git tag v0.1.0
git push origin v0.1.0
```

The release workflow verifies that the tag version matches
`project(cpplib VERSION ...)` in `CMakeLists.txt` and the `version` in
`vcpkg.json`, builds the shared and standalone packages, installs and runs them
(`verify-packages`), generates the GitHub Release body with `git-cliff`, and
uploads the package artifacts. It refuses to publish a release whose product
identity (project name, MSI upgrade code) differs from the last release, see
"Product identity and the MSI upgrade code" in the README.

Create `v0.1.0` as the baseline tag for the current history. After that,
release notes are generated from Conventional Commits since the previous `v*`
tag.
