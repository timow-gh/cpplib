# Shared helpers for the Woodpecker scripts. Dot-source it first: . "$PSScriptRoot\ci-common.ps1"
#
# The scripts run on Windows PowerShell 5.1 (the `powershell` shell of the Woodpecker local
# backend), so this file avoids PowerShell 7 features and keeps to ASCII: 5.1 reads BOM-less
# scripts in the ANSI code page.

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 still negotiates TLS 1.0 by default, which current servers refuse.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Runs a script body and turns any failure into one readable log line and exit code 1.
#
# Without it, an unhandled exception prints PowerShell's multi-line error record, which buries
# the message a human or a coding agent has to act on.
function Invoke-Main([scriptblock] $Body) {
    try {
        & $Body
    }
    catch {
        $message = $_.Exception.Message
        Write-Host ''
        Write-Host "[error] $message"
        # Tagged errors ([command-failed], ...) are expected failures that already say what went
        # wrong; only unexpected ones need the location.
        if (-not $message.StartsWith('[')) {
            Write-Host $_.ScriptStackTrace
        }
        exit 1
    }
    exit 0
}

# Text of one line of native command output merged with 2>&1. For stderr lines Windows
# PowerShell 5.1 yields error records whose text is "System.Management.Automation.RemoteException"
# for an empty line; the original line is in TargetObject.
function ConvertTo-LogLine($Line) {
    if ($Line -is [System.Management.Automation.ErrorRecord] -and $Line.TargetObject -is [string]) {
        return $Line.TargetObject
    }
    return "$Line"
}

# Runs a native command, streams its output and throws a `[command-failed]` error on a
# non-zero exit code.
#
# stderr is merged into the log as plain text: Windows PowerShell 5.1 turns native stderr into
# error records when its own output is redirected, which `$ErrorActionPreference = 'Stop'`
# would treat as a failure even when the command succeeds.
function Invoke-Native([string] $Step, [string] $FilePath, [string[]] $ArgumentList = @()) {
    $commandLine = (@($FilePath) + $ArgumentList) -join ' '
    Write-Host "> $commandLine"
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @ArgumentList 2>&1 | ForEach-Object { Write-Host (ConvertTo-LogLine $_) }
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
        throw "[command-failed] $commandLine exited with $exitCode ($Step)"
    }
}

# Like Invoke-Native, but returns stdout instead of logging it; stderr still goes to the log.
function Invoke-NativeCapture([string] $Step, [string] $FilePath, [string[]] $ArgumentList = @()) {
    $commandLine = (@($FilePath) + $ArgumentList) -join ' '
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $FilePath @ArgumentList 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    $stdout = @()
    foreach ($line in $output) {
        if ($line -is [System.Management.Automation.ErrorRecord]) {
            Write-Host (ConvertTo-LogLine $line)
        }
        else {
            $stdout += "$line"
        }
    }
    if ($exitCode -ne 0) {
        throw "[command-failed] $commandLine exited with $exitCode ($Step)"
    }
    return $stdout
}

function Invoke-WithRetry([string] $Description, [int] $Attempts, [int] $BackoffSeconds, [scriptblock] $Action) {
    for ($attempt = 1; ; $attempt++) {
        try {
            & $Action
            return
        }
        catch {
            if ($attempt -ge $Attempts) {
                throw
            }
            $delay = $attempt * $BackoffSeconds
            Write-Host "[retry] $Description failed (attempt $attempt of $Attempts): $($_.Exception.Message)"
            Write-Host "[retry] retrying in $delay s"
            Start-Sleep -Seconds $delay
        }
    }
}

function Write-Utf8File([string] $Path, [string] $Content) {
    # .NET resolves relative paths against the process directory, not the PowerShell location.
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path $directory)) {
        New-Item -ItemType Directory -Force $directory | Out-Null
    }
    # No BOM and LF line endings, so the file is byte-identical to the one the GitHub workflow writes.
    [IO.File]::WriteAllText($Path, $Content.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
}

# --- Project ---------------------------------------------------------------------------------

# Reads the project name and version from the root CMakeLists.txt.
#
# The project name drives every target, package and installer name, so the release scripts read
# it instead of hard-coding it.
function Get-ProjectInfo {
    $cmakeLists = Get-Content -Raw 'CMakeLists.txt'
    $project = [regex]::Match($cmakeLists, '(?m)^\s*project\s*\(\s*(?<name>[A-Za-z0-9_]+)(?<body>[^)]*)\)')
    if (-not $project.Success) {
        throw 'Could not find the project() call in CMakeLists.txt'
    }
    $version = [regex]::Match($project.Groups['body'].Value, '\bVERSION\s+(?<version>\S+)')
    if (-not $version.Success) {
        throw 'Could not read the CMake project version from CMakeLists.txt'
    }
    return [pscustomobject]@{
        Name    = $project.Groups['name'].Value
        Version = $version.Groups['version'].Value
    }
}

function Get-WixUpgradeGuid {
    $match = Select-String -Path 'cmake/product_identity.cmake' -Pattern 'set\(PRODUCT_WIX_UPGRADE_GUID "(?<guid>[^"]+)"'
    if (-not $match) {
        throw 'Could not read PRODUCT_WIX_UPGRADE_GUID from cmake/product_identity.cmake'
    }
    return $match.Matches[0].Groups['guid'].Value
}

# --- Forgejo API -----------------------------------------------------------------------------

# Base URL of Forgejo as seen from this agent.
#
# CI_FORGE_URL is the URL the Woodpecker server uses. When the server reaches Forgejo through a
# container-internal name the agent cannot resolve, FORGEJO_URL in the agent environment
# overrides it.
function Get-ForgejoBaseUrl {
    $base = if ($env:FORGEJO_URL) { $env:FORGEJO_URL } else { $env:CI_FORGE_URL }
    if (-not $base) {
        throw 'Neither FORGEJO_URL nor CI_FORGE_URL is set; cannot reach the Forgejo API'
    }
    return $base.TrimEnd('/')
}

function Get-ForgejoApiUrl {
    return "$(Get-ForgejoBaseUrl)/api/v1"
}

function Get-ForgejoHeaders {
    $headers = @{ Accept = 'application/json' }
    if ($env:FORGEJO_TOKEN) {
        $headers['Authorization'] = "token $env:FORGEJO_TOKEN"
    }
    return $headers
}

# Calls the Forgejo REST API and returns the decoded JSON response.
#
# With -AllowNotFound a 404 returns $null instead of throwing, for lookups of things that may
# not exist yet (the first release, a release for a new tag); -AllowConflict does the same for a
# 409, for creating something another workflow may have created first.
function Invoke-ForgejoApi([string] $Method = 'Get', [string] $Path, $Body, [switch] $AllowNotFound, [switch] $AllowConflict) {
    $request = @{
        Method          = $Method
        Uri             = "$(Get-ForgejoApiUrl)/$Path"
        Headers         = Get-ForgejoHeaders
        UseBasicParsing = $true
        TimeoutSec      = 30
    }
    if ($null -ne $Body) {
        # Send bytes: Windows PowerShell 5.1 would encode a string body as ISO-8859-1.
        $request['Body'] = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 5))
        $request['ContentType'] = 'application/json; charset=utf-8'
    }
    try {
        return Invoke-RestMethod @request
    }
    catch {
        $response = $_.Exception.Response
        if ($AllowNotFound -and $response -and [int]$response.StatusCode -eq 404) {
            return $null
        }
        if ($AllowConflict -and $response -and [int]$response.StatusCode -eq 409) {
            return $null
        }
        throw "[forgejo-api-failed] $Method $($request.Uri): $($_.Exception.Message)"
    }
}

# --- Releases --------------------------------------------------------------------------------

# Returns the release of a tag, drafts included, or $null.
#
# Lists the releases instead of asking for releases/tags/<tag>, which may not return drafts.
function Find-Release([string] $Tag) {
    for ($page = 1; ; $page++) {
        # Windows PowerShell 5.1 may pass a JSON array on as one object; the ForEach-Object
        # yields its elements either way.
        $releases = @(Invoke-ForgejoApi -Path "repos/$env:CI_REPO/releases?limit=50&page=$page" |
            ForEach-Object { $_ } | Where-Object { $null -ne $_ })
        if ($releases.Count -eq 0) {
            return $null
        }
        $release = $releases | Where-Object { $_.tag_name -eq $Tag } | Select-Object -First 1
        if ($release) {
            return $release
        }
    }
}

# Returns the release of a tag, creating it as a draft if it does not exist yet.
#
# The Windows and the Linux release workflows run at the same time, and both may try to create
# the release; the one that loses gets 409 Conflict and reads the other's release.
# release-finalize.ps1 publishes the draft once both have uploaded their packages.
function Get-OrCreateDraftRelease([string] $Tag, [string] $Version) {
    $release = Find-Release $Tag
    if ($release) {
        Write-Host "Reusing the existing release $($release.html_url)"
        return $release
    }
    $release = Invoke-ForgejoApi -Method Post -Path "repos/$env:CI_REPO/releases" -AllowConflict -Body @{
        tag_name   = $Tag
        name       = "Release $Version"
        body       = ''
        draft      = $true
        prerelease = $false
    }
    if (-not $release) {
        $release = Find-Release $Tag
        if (-not $release) {
            throw "[forgejo-api-failed] creating the release for $Tag returned 409, but no release for $Tag exists"
        }
        Write-Host 'Reusing the release created by the other release workflow'
        return $release
    }
    Write-Host "Created the draft release $($release.html_url)"
    return $release
}

# Uploads one file as a release asset, replacing an asset with the same name.
function Publish-ReleaseAsset($Release, [string] $Path) {
    $name = Split-Path -Leaf $Path
    $existing = @($Release.assets) | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if ($existing) {
        Invoke-ForgejoApi -Method Delete -Path "repos/$env:CI_REPO/releases/$($Release.id)/assets/$($existing.id)" | Out-Null
        Write-Host "Replacing $name"
    }

    # curl.exe instead of Invoke-RestMethod: Windows PowerShell 5.1 has no multipart -Form.
    $uploadUrl = "$(Get-ForgejoApiUrl)/repos/$env:CI_REPO/releases/$($Release.id)/assets?name=$([Uri]::EscapeDataString($name))"
    $responseFile = [IO.Path]::GetTempFileName()
    # curl reports errors on stderr; let the status check below decide instead of 'Stop'.
    $ErrorActionPreference = 'Continue'
    try {
        $status = & curl.exe -sS -o $responseFile -w '%{http_code}' -X POST `
            -H "Authorization: token $env:FORGEJO_TOKEN" -F "attachment=@$Path" $uploadUrl
        if ($LASTEXITCODE -ne 0 -or $status -ne '201') {
            $response = Get-Content -Raw $responseFile
            throw "[forgejo-api-failed] uploading $name returned HTTP $status (curl exit code $LASTEXITCODE): $response"
        }
    }
    finally {
        Remove-Item -Force $responseFile
    }
    Write-Host "Uploaded $name"
}

# --- Prerequisites ---------------------------------------------------------------------------

function New-CheckPassed([string] $Detail) {
    return [pscustomobject]@{ Passed = $true; Detail = $Detail }
}

function New-CheckFailed([string] $Problem, [string] $Checked, [string] $Fix) {
    return [pscustomobject]@{ Passed = $false; Problem = $Problem; Checked = $Checked; Fix = $Fix }
}

# The agent's start script exports its own path, so fix hints can name the file to edit.
$script:AgentScript = if ($env:WOODPECKER_AGENT_SCRIPT) { $env:WOODPECKER_AGENT_SCRIPT } else { 'the agent start script (run-agent.ps1)' }
$script:RestartHint = "then restart the agent (environment changes reach the steps only through the agent process)"

# Each check returns New-CheckPassed or New-CheckFailed. The problem and fix text is
# the only documentation of a prerequisite, so it has to be self-contained.
$script:PrerequisiteChecks = [ordered]@{
    'git'           = {
        $git = Get-Command git.exe -ErrorAction SilentlyContinue
        if (-not $git) {
            return New-CheckFailed 'git.exe is not on the PATH of the agent process' 'Get-Command git.exe' `
                "install Git for Windows (winget install Git.Git) and add its cmd directory to PATH in $AgentScript, $RestartHint"
        }
        return New-CheckPassed "$(& git.exe --version) ($($git.Source))"
    }
    'cmake'         = {
        $cmake = Get-Command cmake.exe -ErrorAction SilentlyContinue
        if (-not $cmake) {
            return New-CheckFailed 'cmake.exe is not on the PATH of the agent process' 'Get-Command cmake.exe' `
                "install CMake >= 3.28 (winget install Kitware.CMake) and add its bin directory to PATH in $AgentScript; the cmake.exe bundled with Visual Studio is only on PATH in a Developer prompt; $RestartHint"
        }
        $versionLine = (& cmake.exe --version | Select-Object -First 1)
        $match = [regex]::Match("$versionLine", '(\d+\.\d+\.\d+)')
        if (-not $match.Success -or [version]$match.Value -lt [version]'3.28.0') {
            return New-CheckFailed "CMake is too old: '$versionLine' ($($cmake.Source)), CMakePresets.json requires >= 3.28" 'cmake --version' `
                "install CMake >= 3.28 (winget install Kitware.CMake) and make sure it comes first on PATH in $AgentScript, $RestartHint"
        }
        return New-CheckPassed "cmake $($match.Value) (>= 3.28) ($($cmake.Source))"
    }
    'vcpkg-root'    = {
        $fix = "clone https://github.com/microsoft/vcpkg, run bootstrap-vcpkg.bat in it, add `$env:VCPKG_ROOT = '<path>' to $AgentScript, $RestartHint"
        if (-not $env:VCPKG_ROOT) {
            return New-CheckFailed 'VCPKG_ROOT is not set in the agent environment' '$env:VCPKG_ROOT' $fix
        }
        $toolchain = Join-Path $env:VCPKG_ROOT 'scripts\buildsystems\vcpkg.cmake'
        if (-not (Test-Path $toolchain)) {
            return New-CheckFailed "VCPKG_ROOT='$env:VCPKG_ROOT' does not contain a vcpkg checkout" "Test-Path $toolchain" $fix
        }
        $vcpkg = Join-Path $env:VCPKG_ROOT 'vcpkg.exe'
        if (-not (Test-Path $vcpkg)) {
            return New-CheckFailed "vcpkg in '$env:VCPKG_ROOT' is not bootstrapped (vcpkg.exe missing)" "Test-Path $vcpkg" `
                "run $env:VCPKG_ROOT\bootstrap-vcpkg.bat once"
        }
        return New-CheckPassed "vcpkg at $env:VCPKG_ROOT"
    }
    'msvc'          = {
        $fix = 'install Visual Studio 2022 or the Build Tools for Visual Studio 2022 with the "Desktop development with C++" workload (winget install Microsoft.VisualStudio.2022.BuildTools --override "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --passive")'
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (-not (Test-Path $vswhere)) {
            return New-CheckFailed 'No Visual Studio installation found (vswhere.exe is missing)' "Test-Path $vswhere" $fix
        }
        # Windows PowerShell 5.1 returns a JSON array as one object, hence the @(...)[0].
        $json = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json) -join "`n"
        $instance = @($json | ConvertFrom-Json)[0]
        if (-not $instance) {
            return New-CheckFailed 'Visual Studio is installed, but without the x64 C++ build tools' `
                'vswhere -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64' $fix
        }
        return New-CheckPassed "$($instance.displayName) $($instance.installationVersion) ($($instance.installationPath))"
    }
    'sh'            = {
        $shell = Get-Command sh.exe -ErrorAction SilentlyContinue
        if (-not $shell) {
            return New-CheckFailed 'sh.exe is not on the PATH of the agent process; tools/git-hooks/check-conventional-commit.sh needs it' 'Get-Command sh.exe' `
                "add the bin directory of Git for Windows to PATH in $AgentScript (`$env:PATH = 'C:\Program Files\Git\bin;' + `$env:PATH), $RestartHint"
        }
        return New-CheckPassed "sh ($($shell.Source))"
    }
    'wix'           = {
        $fix = "install the WiX Toolset v3 (choco install wixtoolset, or the v3.14 installer from https://github.com/wixtoolset/wix3/releases); its installer sets the WIX environment variable that CPack reads; $RestartHint"
        if (-not $env:WIX) {
            return New-CheckFailed 'WIX is not set in the agent environment, so CPack cannot find WiX v3' '$env:WIX' $fix
        }
        foreach ($tool in 'candle.exe', 'light.exe') {
            $path = Join-Path $env:WIX "bin\$tool"
            if (-not (Test-Path $path)) {
                return New-CheckFailed "WIX='$env:WIX' does not contain bin\$tool (WiX v4+ is not supported by the packaging)" "Test-Path $path" $fix
            }
        }
        return New-CheckPassed "WiX at $env:WIX"
    }
    'git-cliff'     = {
        $cliff = Get-Command git-cliff.exe -ErrorAction SilentlyContinue
        if (-not $cliff) {
            return New-CheckFailed 'git-cliff.exe is not on the PATH of the agent process; it generates the release notes' 'Get-Command git-cliff.exe' `
                "install git-cliff (winget install orhun.git-cliff, or a release from https://github.com/orhun/git-cliff/releases) and add it to PATH in $AgentScript, $RestartHint"
        }
        return New-CheckPassed "$(& git-cliff.exe --version) ($($cliff.Source))"
    }
    'curl'          = {
        $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
        if (-not $curl) {
            return New-CheckFailed 'curl.exe is not on the PATH of the agent process; it uploads the release assets' 'Get-Command curl.exe' `
                "curl.exe ships with Windows 10 1803 and later in C:\Windows\System32; make sure that directory is on PATH in $AgentScript"
        }
        return New-CheckPassed "$((& curl.exe --version | Select-Object -First 1)) ($($curl.Source))"
    }
    'forgejo-token' = {
        if (-not $env:FORGEJO_TOKEN) {
            return New-CheckFailed 'FORGEJO_TOKEN is empty' '$env:FORGEJO_TOKEN (Woodpecker secret forgejo_token)' `
                'create a Forgejo access token and add it in Woodpecker as the repository secret forgejo_token; its scopes and events are listed in .woodpecker/README.md#secrets'
        }
        return New-CheckPassed 'FORGEJO_TOKEN is set'
    }
    'forgejo-api'   = {
        $fix = "make sure this machine can reach Forgejo; if CI_FORGE_URL ('$env:CI_FORGE_URL') is an address only the Woodpecker server can resolve, set `$env:FORGEJO_URL = 'http://<nas-ip>:<port>' in $AgentScript, $RestartHint"
        try {
            $url = "$(Get-ForgejoApiUrl)/version"
        }
        catch {
            return New-CheckFailed $_.Exception.Message '$env:FORGEJO_URL, $env:CI_FORGE_URL' $fix
        }
        try {
            $version = Invoke-ForgejoApi -Path 'version'
        }
        catch {
            return New-CheckFailed "The Forgejo API is not reachable from this agent: $($_.Exception.Message)" "GET $url" $fix
        }
        return New-CheckPassed "Forgejo $($version.version) at $(Get-ForgejoApiUrl)"
    }
    'elevated'      = {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal $identity
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            return New-CheckFailed "The agent runs without administrator rights (user $($identity.Name)); verifying the MSI needs a per-machine install" 'WindowsPrincipal.IsInRole(Administrator)' `
                "start $AgentScript from an elevated PowerShell (Run as administrator), or run the agent as a service under an administrator account"
        }
        return New-CheckPassed "elevated ($($identity.Name))"
    }
}

# Checks what a script needs from the agent before it does any work.
#
# Runs every requested check instead of stopping at the first failure, so one run lists
# everything that is missing. Each failure is printed as a `[prerequisite-missing] id=<id>`
# block with problem, what was checked, and a concrete fix, a format meant to
# be read by humans and grepped by coding agents. Exits with code 2 if a required check fails;
# checks passed via -Warn are reported the same way but never fail the step.
function Assert-Prerequisites([string[]] $Require = @(), [string[]] $Warn = @()) {
    $failedCount = 0
    $checks = @($Require | ForEach-Object { @{ Id = $_; Required = $true } }) + @($Warn | ForEach-Object { @{ Id = $_; Required = $false } })
    foreach ($check in $checks) {
        if (-not $script:PrerequisiteChecks.Contains($check.Id)) {
            throw "Unknown prerequisite id '$($check.Id)'"
        }
        try {
            $result = & $script:PrerequisiteChecks[$check.Id]
        }
        catch {
            $result = New-CheckFailed "The check itself failed: $($_.Exception.Message)" "check '$($check.Id)'" 'see the error above'
        }
        if ($result.Passed) {
            Write-Host "[prerequisite-ok] $($check.Id): $($result.Detail)"
            continue
        }
        $label = if ($check.Required) { 'prerequisite-missing' } else { 'prerequisite-warning' }
        if ($check.Required) {
            $failedCount++
        }
        Write-Host "[$label] id=$($check.Id)"
        Write-Host "  problem:  $($result.Problem)"
        Write-Host "  checked:  $($result.Checked)"
        Write-Host "  fix:      $($result.Fix)"
    }
    if ($failedCount -gt 0) {
        $agent = if ($env:CI_MACHINE) { $env:CI_MACHINE } else { $env:COMPUTERNAME }
        Write-Host "[prerequisites] $failedCount of $($Require.Count) required checks failed - the agent '$agent' is not set up for this workflow"
        exit 2
    }
}
