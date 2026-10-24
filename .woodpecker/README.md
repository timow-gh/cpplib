# Woodpecker CI

These workflows run the CI of this repository on a self-hosted Forgejo + Woodpecker setup. They
mirror `.github/workflows/`, which stays the primary CI; both are maintained side by side.

For now only a native Windows agent exists. The Linux workflows follow once a WSL agent is set up
(see [Not ported yet](#not-ported-yet)).

## Workflows

| Woodpecker | GitHub | Runs on | Differences |
|---|---|---|---|
| `windows-agent-check.yaml` | – | push, manual | Smoke test: checks every tool the workflows need ([Troubleshooting](#troubleshooting)) |
| `windows-build.yaml` | `windows-build.yml` | push `main`, PR → `main`, push `develop-**` | Same matrix: debug, release, release-standalone; `develop-*` pushes build debug only |
| `windows-package.yaml` | – | PR → `main` | Builds the shared and standalone packages like a release and runs the app from the ZIP (no MSI install) |
| `commit-messages.yaml` | `commit-messages.yml` | PR, PR title edit | Same checks, same script (`tools/git-hooks/check-conventional-commit.sh`) |
| `release.yaml` | `release.yml` | tag `v*`, manual | Windows packages only; publishes a Forgejo release; no attestations |
| – | `ubuntu-*.yml`, Linux half of `release.yml` | – | Not ported yet (needs the WSL agent) |
| – | `stale-branches.yml` | – | GitHub only |

There are no `*-summary` jobs: Forgejo shows one status per workflow and matrix entry. Status
check names therefore differ from GitHub's; adjust branch protection rules in Forgejo
accordingly.

### Maintenance

- A change to a preset name, a build step or a release rule has to be made in both
  `.github/workflows/` and here.
- All logic lives in `scripts/*.ps1`. Woodpecker substitutes variables in the raw text of the
  workflow files (comments included) before the shell sees it, which breaks PowerShell's
  `$env:X` and `$LASTEXITCODE`. The only `$` in a workflow file is an intended matrix variable
  such as `${PRESET_SUFFIX}`.
- The scripts run in Windows PowerShell 5.1 (`image: powershell`) and must stay ASCII: 5.1 reads
  BOM-less scripts in the ANSI code page.

## Agent setup

The agent uses the local backend: steps run directly on the machine, as the user that runs the
agent, with the agent's environment. Install once:

| Tool | Install | Needed by |
|---|---|---|
| Git for Windows | `winget install Git.Git` | all |
| CMake ≥ 3.28 | `winget install Kitware.CMake` | build, release |
| Visual Studio 2022 or Build Tools with the C++ workload | `winget install Microsoft.VisualStudio.2022.BuildTools --override "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --passive"` | build, release |
| vcpkg | `git clone https://github.com/microsoft/vcpkg` and `bootstrap-vcpkg.bat` | build, release |
| WiX Toolset v3 | `choco install wixtoolset` | package, release |
| git-cliff | `winget install orhun.git-cliff` | release |
| curl | ships with Windows 10 1803+ | release |

Then extend `C:\Woodpecker\run-agent.ps1` and restart the agent. Steps see only what the agent
process sees, so environment changes need a restart:

```powershell
# Git for Windows' bin directory provides sh.exe for the commit message check.
$env:PATH = "C:\Woodpecker;C:\Program Files\Git\bin;$env:PATH"
$env:VCPKG_ROOT = "C:\path\to\vcpkg"

# Recommended: every pipeline starts in a fresh workspace; this keeps CPM's GoogleTest download.
$env:CPM_SOURCE_CACHE = "C:\Woodpecker\cache\cpm"

# Lets the CI scripts name this file in their fix hints.
$env:WOODPECKER_AGENT_SCRIPT = $PSCommandPath

# Only if CI_FORGE_URL (the Forgejo URL the Woodpecker server uses) is not reachable from this
# machine, e.g. a container-internal host name:
# $env:FORGEJO_URL = "http://<host>:<forgejo-port>"
```

Verifying the MSI of a release installs it per machine, so release pipelines need the agent to run
elevated ("Run as administrator"). Build and PR pipelines do not; `windows-package.yaml` builds
the MSI but does not install it. The verification uninstalls the
MSI again and refuses to run while the product is installed on the machine for real.

The execution policy of the agent user must allow local scripts (`RemoteSigned`).

### Secrets

Create these as repository secrets in Woodpecker. Woodpecker refuses to start a pipeline that
references a secret that does not exist.

| Secret | Value | Events |
|---|---|---|
| `forgejo_token` | Forgejo access token with `write:repository` | tag, manual |
| `allow_product_identity_change` | `false`; set to `true` only for a release that deliberately becomes a new product | tag, manual |

Only `release.yaml` uses secrets. No secret is available for `push` or `pull_request`: a pull
request pipeline runs the code of the pull request branch and could read any secret it is given,
and a push to a `develop-*` branch runs code that has not been reviewed yet either.

A pull request pipeline still runs that code on the agent machine, as the agent's user. Keep
*Settings → Project → Require approval for* at least at pull requests from forks, so that code
from others only runs after you have read it.

## Troubleshooting

Each script checks what it needs before doing any work. A failure looks like this; the script
exits with code 2, which Woodpecker reports as a failed step (shown with exit code 1):

```
[prerequisite-missing] id=vcpkg-root
  problem:  VCPKG_ROOT is not set in the agent environment
  checked:  $env:VCPKG_ROOT
  fix:      clone https://github.com/microsoft/vcpkg, run bootstrap-vcpkg.bat in it, ...
  docs:     .woodpecker/README.md#vcpkg-root
[prerequisites] 1 of 4 required checks failed - the agent 'windows-native' is not set up for this workflow
```

Other tagged log lines: `[prerequisite-ok]` (tool and version used), `[prerequisite-warning]`,
`[command-failed]` (a command and its exit code), `[forgejo-api-failed]`, `[retry]`,
`[verify-refused]`, `[cleanup-failed]`. Run `windows-agent-check` manually to see the state of
the whole agent at once.

### Reading pipeline logs (coding agents)

Logs are available through the Woodpecker CLI or REST API, both authenticated with a personal
token from the Woodpecker UI (user settings):

```sh
export WOODPECKER_SERVER=http://<woodpecker-host>:<port>
export WOODPECKER_TOKEN=<token>
woodpecker-cli pipeline ls <owner>/cpplib
woodpecker-cli pipeline log show <owner>/cpplib <pipeline-number>
```

The subcommands moved between CLI versions; `woodpecker-cli --help` shows the ones of the
installed version. Search the log for `[prerequisite-missing]`, `[command-failed]` and `[error]`.

### Problems the scripts cannot see

| Symptom | Cause | Fix |
|---|---|---|
| Pipeline stays pending | No connected agent has the labels `os=windows`, `env=native` | Start the agent; check *Settings → Agents* and `WOODPECKER_AGENT_LABELS` |
| `secret "forgejo_token" not found` (or similar) | Secret missing or not allowed for the event | Create it, see [Secrets](#secrets) |
| `exec: "powershell": executable file not found` | `C:\Windows\System32\WindowsPowerShell\v1.0` not on the agent's PATH | Fix PATH in `run-agent.ps1` |
| Clone step fails before any script runs | `plugin-git.exe` missing next to `woodpecker-agent.exe`, or not on PATH | Put it into `C:\Woodpecker` |
| `... cannot be loaded because running scripts is disabled` | Execution policy | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` for the agent user |

### git

`git.exe` must be on the agent's PATH (Git for Windows adds `C:\Program Files\Git\cmd`).

### cmake

CMake ≥ 3.28 must be on the agent's PATH. The `cmake.exe` bundled with Visual Studio is only on
PATH inside a Developer prompt, which the agent is not.

### vcpkg-root

`VCPKG_ROOT` must point to a bootstrapped vcpkg checkout (`vcpkg.exe` and
`scripts\buildsystems\vcpkg.cmake`). The presets use it as the toolchain. Its binary cache
(`%LOCALAPPDATA%\vcpkg\archives`) persists between pipelines, so dependencies are built once per
triplet.

### msvc

The presets use the Visual Studio generator, which finds MSVC through `vswhere.exe`; no developer
prompt is needed. The check requires an installation with
`Microsoft.VisualStudio.Component.VC.Tools.x86.x64`.

### sh

`commit-messages.yaml` runs `tools/git-hooks/check-conventional-commit.sh` with Git for Windows'
`sh.exe`. Add `C:\Program Files\Git\bin` to the agent's PATH; the `cmd` directory that the Git
installer adds contains no `sh.exe`.

### wix

CPack's WIX generator drives WiX v3 (`candle.exe`, `light.exe`) and finds it through the `WIX`
environment variable, which the WiX v3 installer sets. Restart the agent after installing, so it
inherits the variable.

### git-cliff

Generates the release notes from Conventional Commits (`cliff.toml`). Without a forge integration
the notes contain no PR numbers or authors, unlike on GitHub.

### curl

Uploads release assets; Windows PowerShell 5.1 has no multipart upload of its own.

### forgejo-token

The Woodpecker secret `forgejo_token`, see [Secrets](#secrets). Only `release.yaml` uses it,
to compare the product identity with the last release and to publish the release.

### forgejo-api

The agent calls the Forgejo API at `CI_FORGE_URL`, the URL the Woodpecker server knows Forgejo
by. If that is a host name only the server can resolve (for example a container name on the NAS),
set `FORGEJO_URL` in `run-agent.ps1` to an address this machine can reach.

### elevated

Only `release.yaml` needs it, to install the MSI per machine during verification. Start the agent
from an elevated PowerShell, or run it as a service under an administrator account.

## Not ported yet

- **Linux workflows** for a WSL agent (labels `os=linux`, `env=wsl`): Ubuntu build, sanitizers,
  clang-tidy, coverage, and the Linux half of the release (DEB/TGZ packages, verification, SDK
  consumer build) uploading into the same Forgejo release.
- **Coverage** is planned to produce `coverage.json` (per file: line and branch coverage,
  uncovered line ranges, files changed by the PR), `coverage-summary.md` and the HTML report;
  stored in the Forgejo generic package registry (`coverage/<sha>`, `pr-<n>`, `main-latest`) and
  in a folder on the agent host, with one PR comment that is updated on every run.
- **Stale branch cleanup** stays on GitHub.
