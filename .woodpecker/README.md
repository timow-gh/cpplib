# Woodpecker CI

These workflows run the CI of this repository on a self-hosted Forgejo + Woodpecker setup. They
mirror `.github/workflows/`, which stays the primary CI; both are maintained side by side.

Two agents run them: a native Windows agent (labels `os=windows`, `env=native`) and a Linux agent
in WSL Ubuntu 24.04 (labels `os=linux`, `env=wsl`). Both use the local backend.

## Workflows

| Woodpecker | GitHub | Agent | Runs on | Differences |
|---|---|---|---|---|
| `windows-agent-check.yaml` | – | Windows | push, manual | Smoke test: checks every tool the workflows need ([Troubleshooting](#troubleshooting)) |
| `linux-agent-check.yaml` | – | Linux | push, manual | The same for the Linux agent |
| `windows-build.yaml` | `windows-build.yml` | Windows | push `main`, PR → `main`, push `develop-**` | Same matrix: debug, release, release-standalone; `develop-*` pushes build debug only |
| `linux-build.yaml` | `ubuntu-build.yml` | Linux | push `main`, PR → `main`, push `develop-**` | Same matrix: gcc/clang × debug/release, gcc release-standalone; `develop-*` pushes build gcc-debug only |
| `linux-sanitizers.yaml` | `ubuntu-sanitizers.yml` | Linux | push `main`, PR → `main` | Same: clang debug with ASan, TSan, UBSan |
| `linux-static-analysis.yaml` | `ubuntu-static-analysis.yml` | Linux | push `main`, PR → `main` | Same: clang-tidy through the clang debug build, ninja `-k 0` |
| `linux-coverage.yaml` | `ubuntu-coverage.yml` | Linux | push `main`, PR → `main` | No PR comment; report in the log and on the agent host; `main` uploads it to the package registry ([Coverage](#coverage)) |
| `windows-package.yaml` | – | Windows | PR → `main` | Builds the shared and standalone packages like a release and runs the app from the ZIP (no MSI install) |
| `linux-package.yaml` | – | Linux | PR → `main` | Builds the shared and standalone packages like a release and checks them without installing them ([Package checks on Linux](#package-checks-on-linux)) |
| `commit-messages.yaml` | `commit-messages.yml` | Windows | PR, PR title edit | Same checks, same script (`tools/git-hooks/check-conventional-commit.sh`) |
| `release.yaml` | `release.yml` | Windows | tag `v*`, manual | Windows packages; uploads into a draft Forgejo release; no attestations |
| `release-linux.yaml` | `release.yml` | Linux | tag `v*`, manual | Linux packages; uploads into the same draft |
| `release-finalize.yaml` | `release.yml` | Windows | tag `v*` | Runs after both release workflows succeeded; writes the notes and publishes the draft |
| – | `stale-branches.yml` | – | – | GitHub only |

There are no `*-summary` jobs: Forgejo shows one status per workflow and matrix entry. Status
check names therefore differ from GitHub's; adjust branch protection rules in Forgejo
accordingly.

### Releases

GitHub publishes a release only after the packages of every platform were verified. Here the
packages are built on two agents, so a tag pipeline runs three workflows:

1. `release.yaml` (Windows) checks the version and the product identity, builds and verifies
   the MSI and ZIP packages, and uploads them with `product-identity.txt` into a **draft**
   release of the tag, which it creates if needed.
2. `release-linux.yaml` (Linux) runs at the same time, checks the version, builds and verifies the
   DEB and TGZ packages, and uploads them into the same draft. Whichever workflow comes second
   finds the draft (or gets 409 Conflict on creating it and reads it again).
3. `release-finalize.yaml` (`depends_on` both) checks that every expected asset is there,
   generates the notes with git-cliff and publishes the release.

If one of the first two fails, Woodpecker skips the finalize workflow and the release stays an
unpublished draft. Fix the cause and restart the pipeline; uploads replace assets of the same
name. A draft that should not become a release is deleted in the Forgejo UI. A manual run builds
and verifies on both agents and publishes nothing.

### Maintenance

- A change to a preset name, a build step or a release rule has to be made in both
  `.github/workflows/` and here.
- All logic lives in `scripts/`: `*.ps1` for the Windows agent, `*.sh` (bash) for the Linux agent.
  Woodpecker substitutes variables in the raw text of the workflow files (comments included)
  before the shell sees it, which breaks PowerShell's `$env:X` and `$LASTEXITCODE` and bash
  variables alike. The only `$` in a workflow file is an intended matrix variable such as
  `${PRESET_SUFFIX}`.
- The PowerShell scripts run in Windows PowerShell 5.1 (`image: powershell`) and must stay ASCII:
  5.1 reads BOM-less scripts in the ANSI code page.
- The bash scripts are called as `bash .woodpecker/scripts/x.sh`, so they need no executable bit,
  and `.gitattributes` keeps them at LF line endings. `ci-common.sh` is the bash counterpart of
  `ci-common.ps1` and prints the same tagged log lines; keep the two in step.

## Windows agent setup

The agent uses the local backend: steps run directly on the machine, as the user that runs the
agent, with the agent's environment. Install once:

| Tool | Install | Needed by |
|---|---|---|
| Git for Windows | `winget install Git.Git` | all |
| CMake ≥ 3.28 | `winget install Kitware.CMake` | build, release |
| Visual Studio 2022 or Build Tools with the C++ workload | `winget install Microsoft.VisualStudio.2022.BuildTools --override "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --passive"` | build, release |
| vcpkg | `git clone https://github.com/microsoft/vcpkg` and `bootstrap-vcpkg.bat` | build, release |
| WiX Toolset v3 | `choco install wixtoolset` | package, release |
| git-cliff | `winget install orhun.git-cliff` | release (finalize) |
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

## Linux agent setup (WSL)

The Linux agent also uses the local backend, inside a WSL 2 distribution on the same machine.
Steps run as the user that runs the agent, without root rights and without Docker.

`tools/woodpecker/setup-linux-agent.sh` does steps 2 to 7 and the ThreadSanitizer fix from
[Troubleshooting](#problems-the-scripts-cannot-see) in one run, and is safe to run again, e.g. to
update the agent to the version of the server. Install the distribution (step 1), register the
agent (step 6) to get its token, then run it in the distribution as the agent user:

```sh
bash /mnt/c/path/to/cpplib/tools/woodpecker/setup-linux-agent.sh \
    --agent-version 3.19.0 --server <host>:<grpc-port> [--systemd]
```

`--systemd` runs the agent as the systemd service `woodpecker-agent-wsl.service`, which starts
`run-agent.sh`; without it, start the agent as in step 8. `--help` lists the other options. The
steps below are what the script does, for reference and for setting up by hand.

1. Install the distribution (Ubuntu 20.04 is too old for gcc-14 and clang-20):

   ```powershell
   wsl --install -d Ubuntu-24.04
   ```

   Limit what the WSL VM may take, so that Windows and Linux pipelines can run side by side, in
   `%UserProfile%\.wslconfig`:

   ```ini
   [wsl2]
   memory=12GB
   processors=8
   ```

2. Install the tools in the distribution:

   ```sh
   sudo apt-get update
   sudo apt-get install -y git git-lfs cmake ninja-build build-essential dpkg-dev pkg-config \
       gcc-14 g++-14 clang-20 clang-tidy-20 libclang-rt-20-dev lcov python3 \
       curl jq zip unzip tar
   ```

   If `clang-20` is not available from the Ubuntu archive, install it from apt.llvm.org
   (`wget https://apt.llvm.org/llvm.sh && sudo bash llvm.sh 20`, then
   `sudo apt-get install -y clang-tidy-20 libclang-rt-20-dev`).

3. Pin the compilers. The presets call plain `gcc`, `g++`, `clang` and `clang++` (only
   `conf-gcc-coverage` names `gcc-14`), so put links to the intended versions first on the
   agent's PATH instead of changing the system defaults:

   ```sh
   mkdir -p ~/woodpecker-agent/bin
   for tool in gcc g++; do ln -sf "/usr/bin/$tool-14" ~/woodpecker-agent/bin/$tool; done
   for tool in clang clang++; do ln -sf "/usr/bin/$tool-20" ~/woodpecker-agent/bin/$tool; done
   ```

   `cmake/static_analysis.cmake` finds `clang-tidy-20` through the clang version. The agent check
   prints which versions the plain names resolve to.

4. Clone vcpkg into the Linux file system (`~/vcpkg`, not below `/mnt/c`, which is much slower) and
   run `~/vcpkg/bootstrap-vcpkg.sh`. Its binary cache (`~/.cache/vcpkg/archives`) persists between
   pipelines.

5. Download `woodpecker-agent` and `plugin-git` for linux-amd64 into `~/woodpecker-agent/` and
   `chmod +x` them. Use the agent version of the Woodpecker server.

6. Register the agent in the Woodpecker UI (*Settings → Agents → Add agent*); it gets its own
   token. Store the token outside the repository, readable only by you:

   ```sh
   printf 'WOODPECKER_AGENT_SECRET=%s\n' '<token>' > ~/woodpecker-agent/agent.env
   chmod 600 ~/woodpecker-agent/agent.env
   ```

7. Create `~/woodpecker-agent/run-agent.sh`, the counterpart of `run-agent.ps1`. Steps see only
   what the agent process sees, so environment changes need a restart:

   ```sh
   #!/usr/bin/env bash
   # Pipeline steps on the local backend inherit this environment. After changing it, restart
   # the agent. See .woodpecker/README.md in the cpplib repository.
   set -euo pipefail
   agent_dir="$HOME/woodpecker-agent"

   # The pin directory selects the compiler versions; the agent directory provides plugin-git.
   export PATH="$agent_dir/bin:$agent_dir:/usr/local/bin:/usr/bin:/bin"
   export VCPKG_ROOT="$HOME/vcpkg"
   # Every pipeline starts in a fresh workspace; this keeps CPM's GoogleTest download.
   export CPM_SOURCE_CACHE="$agent_dir/cache/cpm"
   # Coverage reports of every run, see "Coverage".
   export COVERAGE_REPORT_DIR="$agent_dir/coverage"
   # Lets the CI scripts name this file in their fix hints.
   export WOODPECKER_AGENT_SCRIPT="$agent_dir/run-agent.sh"
   # Only if CI_FORGE_URL is not reachable from WSL:
   # export FORGEJO_URL="http://<host>:<forgejo-port>"

   set -a
   . "$agent_dir/agent.env"
   set +a
   export WOODPECKER_SERVER="<host>:<grpc-port>"
   export WOODPECKER_BACKEND=local
   export WOODPECKER_HOSTNAME=wsl-ubuntu
   export WOODPECKER_AGENT_LABELS="os=linux,env=wsl"
   export WOODPECKER_MAX_WORKFLOWS=1

   exec "$agent_dir/woodpecker-agent"
   ```

8. Keep it running. WSL stops a distribution once no process runs in it; the running agent keeps
   it alive. Start it at logon with a Windows scheduled task (*Task Scheduler → Create Task*,
   trigger *At log on*, action `wsl.exe` with the arguments
   `-d Ubuntu-24.04 -- bash -lc ~/woodpecker-agent/run-agent.sh`), or by hand in a WSL terminal.

9. The agent appears under *Settings → Agents*. Push to a branch (or run `linux-agent-check`
   manually) and check that every line of the agent check reads `[prerequisite-ok]`.

The machine runs both agents, each with `WOODPECKER_MAX_WORKFLOWS=1`. A pull request queues about
a dozen Linux workflows, which run one after another; raise the limit if the machine has the
cores and memory for parallel builds.

### Package checks on Linux

`linux-verify.sh` checks the packages without root rights and without changing the agent:

- TGZ: unpacks the archive and runs the app, as on GitHub.
- DEB: shows the metadata and contents of every package and simulates installing them together
  with `apt-get install --simulate` (dependencies, conflicts). GitHub installs them for real in a
  clean `ubuntu:24.04` container instead.
- Unpacks the DEB packages with `dpkg-deb --extract` and runs the app from there; it finds the
  library through its RPATH (`$ORIGIN/../lib`).
- Shared mode: builds and runs `test/test_install/consumer` against the unpacked SDK, without
  vcpkg and with `CMAKE_PREFIX_PATH` pointing at the unpacked `usr` directory. GitHub installs the
  SDK DEB into `/usr` and needs no prefix path.

### Coverage

The coverage step needs no token and runs for pushes to `main` and for pull requests. It writes
`out/coverage/`:

- `coverage-summary.md`: line and branch coverage with the status (Low < 70 % ≤ Fair < 80 % ≤
  Good, as on GitHub); for pull requests also the change against `main` and the files the pull
  request changed. It is printed in the step log.
- `coverage.json`: per file line and branch coverage, uncovered line ranges and whether the pull
  request changed the file; meant for tools and coding agents.
- `coverage-html.tar.gz`: the HTML report of `genhtml`.

Every run also copies the summary, the JSON and the HTML report to
`$COVERAGE_REPORT_DIR/<pr-N|branch>/<commit>/` on the agent host.

Only a push to `main` uploads the three files, with the secret `forgejo_package_token`, to the
Forgejo generic package registry as package `cpplib-coverage`, versions `<commit>` and
`main-latest`. A pull request downloads `main-latest/coverage.json` anonymously for the
comparison, so the package must be readable without login (a public owner). There is no pull
request comment: it would need a token in the pull request pipeline, which runs unreviewed code.

## Secrets

Create these as repository secrets in Woodpecker. Woodpecker refuses to start a pipeline that
references a secret that does not exist.

| Secret | Value | Events |
|---|---|---|
| `forgejo_token` | Forgejo access token with `write:repository` | tag, manual |
| `allow_product_identity_change` | `false`; set to `true` only for a release that deliberately becomes a new product | tag, manual |
| `forgejo_package_token` | Forgejo access token with **only** `write:package` | push |

Only the release workflows and the upload step of `linux-coverage.yaml` use secrets. No secret
is available for `pull_request`: a pull request pipeline runs the code of the pull request branch
and could read any secret it is given.

`forgejo_package_token` is the exception for `push`: Woodpecker filters secrets by event, not by
branch, so a push to a `develop-*` branch, whose code has not been reviewed yet either, could
request it too. That is why it is a separate token that can only write packages, never the
release token.

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
`[verify-refused]`, `[cleanup-failed]`, `[warning]`. Run `windows-agent-check` or
`linux-agent-check` manually to see the state of a whole agent at once.

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
| Pipeline stays pending | No connected agent has the labels of the workflow (`os=windows,env=native` or `os=linux,env=wsl`) | Start the agent; check *Settings → Agents* and `WOODPECKER_AGENT_LABELS` |
| Linux workflows pending after a while | WSL stopped the distribution (agent not started, or its terminal closed) | Start it again; use the scheduled task from the [Linux agent setup](#linux-agent-setup-wsl) |
| `secret "forgejo_token" not found` (or similar) | Secret missing or not allowed for the event | Create it, see [Secrets](#secrets) |
| `exec: "powershell": executable file not found` | `C:\Windows\System32\WindowsPowerShell\v1.0` not on the agent's PATH | Fix PATH in `run-agent.ps1` |
| `exec: "bash": executable file not found` | `/usr/bin` not on the Linux agent's PATH | Fix PATH in `run-agent.sh` |
| Clone step fails before any script runs | `plugin-git` missing next to the agent binary, or not on PATH | Put it into the agent directory (`C:\Woodpecker`, `~/woodpecker-agent`) |
| `fork/exec .../plugin-git: exec format error` | `plugin-git` is a build for another platform (e.g. `darwin-*`, `windows-*`) or not a binary at all (a saved error page) | `file "$(command -v plugin-git)"` must say `ELF 64-bit ... x86-64`; install `linux-amd64_plugin-git` |
| `git init`: `unknown option 'object-format'` in the clone step | git older than 2.29 (Ubuntu 20.04 ships 2.25) | Use Ubuntu 24.04, see [Linux agent setup](#linux-agent-setup-wsl) |
| `git: 'lfs' is not a git command` in the clone step | `plugin-git` fetches LFS objects in every clone, even without LFS files | `sudo apt-get install git-lfs` (Git for Windows ships it) |
| `... cannot be loaded because running scripts is disabled` | Execution policy | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` for the agent user |
| `$'\r': command not found` in a bash script | The script has CRLF line endings | Check `.gitattributes` (`*.sh text eol=lf`) and re-checkout |
| `FATAL: ThreadSanitizer: unexpected memory mapping` | WSL kernel with high ASLR entropy | `sudo sysctl vm.mmap_rnd_bits=28` (persist it in `/etc/sysctl.d/`) |

### git

Windows: `git.exe` must be on the agent's PATH (Git for Windows adds `C:\Program Files\Git\cmd`).
Linux: `sudo apt-get install git`.

### cmake

CMake ≥ 3.28 must be on the agent's PATH. Windows: the `cmake.exe` bundled with Visual Studio is
only on PATH inside a Developer prompt, which the agent is not. Linux: Ubuntu 24.04 ships 3.28.

### ninja

Linux: the gcc and clang presets use the Ninja generator (`sudo apt-get install ninja-build`).

### vcpkg-root

`VCPKG_ROOT` must point to a bootstrapped vcpkg checkout (`vcpkg.exe`/`vcpkg` and
`scripts/buildsystems/vcpkg.cmake`). The presets use it as the toolchain. Its binary cache
(Windows `%LOCALAPPDATA%\vcpkg\archives`, Linux `~/.cache/vcpkg/archives`) persists between
pipelines, so dependencies are built once per triplet. On Linux keep the checkout in the WSL file
system, not below `/mnt/c`.

### msvc

The presets use the Visual Studio generator, which finds MSVC through `vswhere.exe`; no developer
prompt is needed. The check requires an installation with
`Microsoft.VisualStudio.Component.VC.Tools.x86.x64`.

### gcc

Linux: `gcc` and `g++` as the presets call them. Link them to `gcc-14`/`g++-14` in the pin
directory, see [Linux agent setup](#linux-agent-setup-wsl), step 3.

### clang

Linux: `clang` and `clang++` as the presets call them, linked to `clang-20`/`clang++-20` in the pin
directory. The clang presets compile against libstdc++ (`-stdlib=libstdc++`).

### clang-rt

Linux: the sanitizer presets link the clang sanitizer runtime, a package of its own
(`libclang-rt-20-dev` for clang 20). The check links an empty program with ASan, UBSan and TSan.

### clang-tidy

Linux: `cpplib_STATIC_ANALYSIS` is on by default, so every clang build runs clang-tidy, and
`cmake/static_analysis.cmake` fails the configure step without it. It looks for
`clang-tidy-<clang major>` first, then `clang-tidy`.

### gcov

Linux: `conf-gcc-coverage` compiles with `gcc-14`, and lcov needs `gcov-14` of exactly that
version (a mismatch fails with "stamp mismatch"). `gcc-14` ships it.

### lcov

Linux: `lcov` and `genhtml` for `cmake/coverage.cmake` (`sudo apt-get install lcov`).

### python3

Linux: `coverage-report.py` writes the coverage report; it uses the standard library only.

### jq

Linux: reads the Forgejo API responses in `ci-common.sh` and `vcpkg.json` in the release check.

### dpkg

Linux: CPack's DEB generator calls `dpkg-shlibdeps` (`dpkg-dev`) for the package dependencies; the
package checks use `dpkg-deb` and `apt-get --simulate`.

### coverage-dir

Linux: `COVERAGE_REPORT_DIR` is where every coverage run keeps its report on the agent host. Only
a warning: without it the report is only in the log and, for `main`, in the package registry.

### sh

`commit-messages.yaml` runs `tools/git-hooks/check-conventional-commit.sh` with Git for Windows'
`sh.exe`. Add `C:\Program Files\Git\bin` to the agent's PATH; the `cmd` directory that the Git
installer adds contains no `sh.exe`.

### wix

CPack's WIX generator drives WiX v3 (`candle.exe`, `light.exe`) and finds it through the `WIX`
environment variable, which the WiX v3 installer sets. Restart the agent after installing, so it
inherits the variable.

### git-cliff

Generates the release notes from Conventional Commits (`cliff.toml`) in `release-finalize.yaml`.
Without a forge integration the notes contain no PR numbers or authors, unlike on GitHub.

### curl

Uploads release assets and coverage reports. Windows PowerShell 5.1 has no multipart upload of
its own.

### forgejo-token

The Woodpecker secret `forgejo_token`, see [Secrets](#secrets). Only the release workflows use it,
to compare the product identity with the last release, to upload the packages and to publish the
release.

### forgejo-package-token

The Woodpecker secret `forgejo_package_token`, see [Secrets](#secrets). Only the upload step of
`linux-coverage.yaml` uses it, for pushes to `main`.

### forgejo-api

The agent calls the Forgejo API at `CI_FORGE_URL`, the URL the Woodpecker server knows Forgejo
by. If that is a host name only the server can resolve (for example a container name on the NAS),
set `FORGEJO_URL` in the agent's start script to an address this machine can reach. WSL reaches
the LAN through the Windows host.

### elevated

Only `release.yaml` needs it, to install the MSI per machine during verification. Start the agent
from an elevated PowerShell, or run it as a service under an administrator account.

## Not ported

- **Stale branch cleanup** stays on GitHub.
- **Build-provenance attestations** have no Forgejo equivalent.
- **Coverage PR comment**: needs a token in pull request pipelines, see [Coverage](#coverage).
