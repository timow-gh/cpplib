# Installs and runs the packages of one delivery mode the way a user would; the Windows half of
# the verify-packages job of .github/workflows/release.yml.
#
# Unlike a GitHub runner, the agent is a machine someone works on. The MSI is therefore always
# uninstalled again, and the script refuses to run while the product is installed for real,
# because installing the MSI would upgrade that installation and the cleanup would remove it.
#
# -ZipOnly skips the MSI, which needs an elevated agent; windows-package.yaml uses it to check
# the packages of pull requests.
param(
    [Parameter(Mandatory)]
    [ValidateSet('shared', 'standalone')]
    [string] $DeliveryMode,

    [switch] $ZipOnly
)

. "$PSScriptRoot\ci-common.ps1"

# Exit codes of msiexec that mean success; 3010 asks for a reboot, which a verification ignores.
$script:MsiSuccess = @(0, 3010)
# ERROR_UNKNOWN_PRODUCT: uninstalling something that is not installed.
$script:MsiUnknownProduct = 1605

function Get-SinglePackage([string] $PackageDirectory, [string] $Filter) {
    $files = @(Get-ChildItem -File (Join-Path $PackageDirectory $Filter))
    if ($files.Count -ne 1) {
        throw "Expected exactly one $Filter in $PackageDirectory, found $($files.Count)"
    }
    return $files[0].FullName
}

function Invoke-Msiexec([string[]] $ArgumentList, [string] $LogFile) {
    $process = Start-Process msiexec.exe -Wait -PassThru -ArgumentList ($ArgumentList + @('/qn', '/l*v', "`"$LogFile`""))
    return $process.ExitCode
}

function Assert-ProductNotInstalled([string] $UpgradeGuid) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $installed = @($installer.RelatedProducts("{$($UpgradeGuid.ToUpper())}"))
    if ($installed.Count -gt 0) {
        throw "[verify-refused] A product with the upgrade code {$UpgradeGuid} is already installed on this machine (product code $($installed -join ', ')). Installing the MSI would upgrade it and the cleanup would uninstall it. Uninstall it first (Settings > Apps) or verify on another agent."
    }
}

function Assert-ValidSignature([string[]] $Files) {
    foreach ($file in $Files) {
        $signature = Get-AuthenticodeSignature $file
        if ($signature.Status -ne 'Valid') {
            throw "Not validly signed ($($signature.Status)): $file"
        }
    }
}

function Test-MsiPackage([string] $PackageDirectory, [string] $AppName, [string] $WorkDirectory) {
    $msi = Get-SinglePackage $PackageDirectory '*.msi'
    $installDirectory = Join-Path $WorkDirectory 'msi-install'
    $installLog = Join-Path $WorkDirectory 'msi-install.log'
    $uninstallLog = Join-Path $WorkDirectory 'msi-uninstall.log'

    Write-Host "Installing $msi into $installDirectory"
    $cleanupFailed = $false
    try {
        $exitCode = Invoke-Msiexec @('/i', "`"$msi`"", 'ALLUSERS=1', "APPLICATIONFOLDER=`"$installDirectory`"") $installLog
        if ($script:MsiSuccess -notcontains $exitCode) {
            Get-Content $installLog -Tail 50 | ForEach-Object { Write-Host $_ }
            throw "[command-failed] msiexec /i exited with $exitCode (install MSI, log: $installLog)"
        }
        $app = Join-Path $installDirectory "bin\$AppName"
        if ($env:WINDOWS_SIGNTOOL_ARGS) {
            Assert-ValidSignature @($msi, $app)
        }
        Invoke-Native 'run the installed app' $app
    }
    finally {
        Write-Host "Uninstalling $msi"
        $exitCode = Invoke-Msiexec @('/x', "`"$msi`"") $uninstallLog
        if ($script:MsiSuccess -notcontains $exitCode -and $exitCode -ne $script:MsiUnknownProduct) {
            Write-Host "[cleanup-failed] msiexec /x exited with $exitCode; the product may still be installed on this machine (log: $uninstallLog)"
            $cleanupFailed = $true
        }
    }
    if ($cleanupFailed) {
        throw 'Uninstalling the verified MSI failed, see [cleanup-failed] above'
    }
}

function Test-ZipPackage([string] $PackageDirectory, [string] $AppName, [string] $WorkDirectory) {
    $zip = Get-SinglePackage $PackageDirectory '*.zip'
    $archiveDirectory = Join-Path $WorkDirectory 'zip'
    Expand-Archive $zip -DestinationPath $archiveDirectory
    $bin = Join-Path (Get-ChildItem -Directory $archiveDirectory)[0].FullName 'bin'
    Get-ChildItem $bin | ForEach-Object { Write-Host "  $($_.Name)" }
    if ($DeliveryMode -eq 'shared' -and -not (Test-Path (Join-Path $bin 'vcruntime140.dll'))) {
        throw 'The shared package must ship the app-local MSVC runtime (vcruntime140.dll missing)'
    }
    Invoke-Native 'run the app from the ZIP' (Join-Path $bin $AppName)
}

Invoke-Main {
    if (-not $ZipOnly) {
        Assert-Prerequisites -Require elevated
    }

    $appName = "$((Get-ProjectInfo).Name)_app.exe"
    $packageDirectory = (Resolve-Path "out\packages\package-msvc-release-$DeliveryMode").Path
    $workDirectory = Join-Path (Get-Location).Path "out\release\verify-$DeliveryMode"
    if (Test-Path $workDirectory) {
        Remove-Item -Recurse -Force $workDirectory
    }
    New-Item -ItemType Directory -Force $workDirectory | Out-Null

    if (-not $ZipOnly) {
        Assert-ProductNotInstalled (Get-WixUpgradeGuid)
        Test-MsiPackage $packageDirectory $appName $workDirectory
    }
    Test-ZipPackage $packageDirectory $appName $workDirectory
}
