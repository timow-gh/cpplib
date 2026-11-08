# Contributing

These are the conventions of this repository, for people and coding agents alike (`CLAUDE.md`
imports this file).

## Repository layout: one folder per concern

A file lives in the folder of the concern it belongs to, not next to whoever calls it.

- `.github/` and `.woodpecker/` hold what each CI system runs, and only that.
- `tools/<concern>/` holds what people run: `new-product/`, `git-hooks/`, `clang-format/`,
  `github-sync/` and `woodpecker-agent/`.
- CI may call a tool (both commit message checks run `tools/git-hooks/`). A tool never depends on a
  CI folder.

## Documentation: every fact once

- **The code is the documentation of what it does:** names, `--help`, error and fix messages, and
  a header comment in the file a fact belongs to.
- **Prose documentation is only for:**
  - how to start (entry points),
  - rationale that spans several files (the design decisions in `ReadMe.md`),
  - steps outside the repository (Woodpecker and Forgejo settings, secrets, machine setup).
- **Link, don't restate.** Delete a paragraph that repeats the code or another document. A
  constraint on one file goes in that file's header; a constraint on a set of files goes in that
  folder's README.

## C++

- **West Const:** write `const` before the type (`const T&`), not East Const (`T const&`).
- **Using declarations:** alias long, nested or dependent type names with a local `using` at the
  top of a function, and use the aliases in the body.
- **Variable names ≥ 3 characters:** prefer descriptive names over abbreviations. Exceptions are
  loop counters (`i`/`j`/`k`) and coordinates (`x`/`y`/`z`).
- **Avoid unnecessary heap allocations:** prefer stack allocation, fixed-size containers and
  buffer reuse. Allocate on the heap only when it is genuinely the right choice.
- **Internal helpers in `namespace detail`:** implementation details go in `namespace detail`
  inside the project namespace, and call sites qualify them with `detail::`. Public functions stay
  directly in the project namespace.
- **Comments explain *why*, not *what*:** document rationale and non-obvious constraints. If the
  *what* is unclear, extract a well-named function instead of narrating steps. Document each
  function on itself, not in file-level or multi-function overview comments.
- **Doxygen format:**
  - `/** ... */` with a leading `*` per line for multi-line comments (not `///`); `//` for
    single-line ones.
  - Backslash commands (`\brief`, `\param`, `\return`, `\internal`), not `@`.
  - Focus the prose on why, when and how. Tag complexity briefly, e.g. `O(H)`.
- **Use C++ attributes** (`[[nodiscard]]`, `[[maybe_unused]]`, …) instead of comments or
  compiler-specific pragmas.
- **No C-style casts:** use `static_cast`, `reinterpret_cast`, `const_cast` or `dynamic_cast`.
- **Assertions:** use asserts to express and check pre- and postconditions.
- **`noexcept`:** mark functions that are guaranteed not to throw.
- **No side effects:** avoid out parameters, except where expected (e.g. an STL-style output
  iterator).
- **Follow the C++ Core Guidelines.** Deviate only for a good reason, documented in a comment.
- **Maintainability:** prefer code that is maintainable, testable and easy to understand.

## CI

`.github/workflows/` (GitHub Actions) and `.woodpecker/` (self-hosted Woodpecker) are maintained
side by side. A change to a preset, a build step or a release rule goes into both. See
[.woodpecker/README.md](.woodpecker/README.md).

## Commit messages

Commits follow Conventional Commits, so that release notes can be generated from the history:

```text
type[(scope)][!]: short imperative summary
```

`tools/git-hooks/check-conventional-commit.sh` holds the rules (types, scopes, breaking changes,
examples). It prints them with `--help` and with every rejected message. Install it as the local
`commit-msg` hook with `tools/git-hooks/install-hooks.sh` (PowerShell: `install-hooks.ps1`). Both
CI systems run the same script on every pull request.

No LLM names itself as a co-author: no `Co-Authored-By:` trailers or similar attribution in
commit messages or pull request descriptions.

To use these rules in another repository, copy `.githooks/`, `tools/git-hooks/`, the
commit-messages workflow of each CI system (Woodpecker: with `.woodpecker/scripts/ci-common.ps1`
and `check-commit-messages.ps1`), `.forgejo/default_merge_message/` and `cliff.toml`.

## Merging pull requests

Pull requests are opened and merged on Forgejo only. The history holds pull requests of both
GitHub and Forgejo, each numbered from `#1`, so a number in a commit subject is ambiguous and squash
merges use the pull request title alone: Forgejo prefills the message from
`.forgejo/default_merge_message/SQUASH_TEMPLATE.md`, and `cliff.toml` strips ` (#N)` from older
subjects in the release notes.

## Publishing to GitHub

Forgejo is the source of truth. The public GitHub repository receives `main` and release tags only
through `tools/github-sync/sync-to-github.sh`, which shows what it would publish unless given
`--push`. A commit merged on GitHub splits the histories, and the script then refuses to publish.

## Releases

1. Bump the version in `project()` in `CMakeLists.txt` and in `vcpkg.json` together.
2. Push a tag `vX.Y.Z` with the same version to Forgejo, which starts the Woodpecker release, then
   publish it, which starts the GitHub release:

   ```sh
   git tag v0.1.0
   git push jatinas v0.1.0
   sh tools/github-sync/sync-to-github.sh --tag v0.1.0 --push
   ```

The release workflows (`.github/workflows/release.yml`, `.woodpecker/release*.yaml`) refuse a tag
that does not match both versions, and a release that changes the product identity (design
decision 10 in `ReadMe.md`). The release notes cover the Conventional Commits since the previous
`v*` tag.
