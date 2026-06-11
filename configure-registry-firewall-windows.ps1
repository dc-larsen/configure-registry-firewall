# Configure package managers to use Socket Registry Firewall
# Deploys machine-wide registry overrides so all package installs route through
# your Socket Firewall instance.
#
# Platform: Windows
# Run as:   SYSTEM or Administrator (via MDM custom script: Intune, SCCM, etc.)
#
# Usage:
#   1. Set $FirewallHost below to your Socket Firewall hostname
#   2. Uncomment the registries your team uses
#   3. Deploy via your endpoint management tool
#
# Intune note: either check "Run script in 64-bit PowerShell host" when
# assigning the script, or rely on the relaunch shim below. Intune defaults to
# the 32-bit host, which sees different paths and registry views.

# Relaunch in 64-bit PowerShell if we were started in the 32-bit host
if ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64') {
    & "$env:WINDIR\SysNative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $MyInvocation.MyCommand.Path
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Stop'

###############################################################################
# Configuration -- set your firewall hostname here
###############################################################################

$FirewallHost = 'sfw.yourcompany.com:8443'

# Uncomment the registries your team uses:
$NpmRegistryUrl  = "https://$FirewallHost/npm/"
$PypiRegistryUrl = "https://$FirewallHost/pypi/simple"
# $MavenRegistryUrl    = "https://$FirewallHost/maven"
# $GoRegistryUrl       = "https://$FirewallHost/go"
# $NugetRegistryUrl    = "https://$FirewallHost/nuget/v3/index.json"
# $CargoRegistryUrl    = "https://$FirewallHost/cargo"
# $RubygemsRegistryUrl = "https://$FirewallHost/rubygems"
# $CondaRegistryUrl    = "https://$FirewallHost/conda"

###############################################################################
# Logging and backup
###############################################################################

function Write-Log { param([string]$Message) Write-Output "[socket-registry] $Message" }

$BackupDir = Join-Path $env:TEMP ("socket-registry-backup-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
$BackedUpFiles = @{}   # original path -> backup path ('' if the file did not exist)
$PreviousEnv   = @{}   # machine env var name -> previous value ($null if unset)

Write-Log "Backup directory: $BackupDir"

function Backup-File {
    param([string]$Path)
    if ($BackedUpFiles.ContainsKey($Path)) { return }
    if (Test-Path $Path) {
        $dest = Join-Path $BackupDir ($Path -replace '[:\\/]', '_')
        Copy-Item -Path $Path -Destination $dest -Force
        $BackedUpFiles[$Path] = $dest
        Write-Log "Backed up $Path"
    } else {
        $BackedUpFiles[$Path] = ''
    }
}

function Restore-Backups {
    Write-Log 'ERROR: restoring backups due to failure'
    foreach ($entry in $BackedUpFiles.GetEnumerator()) {
        if ($entry.Value -and (Test-Path $entry.Value)) {
            Copy-Item -Path $entry.Value -Destination $entry.Key -Force
            Write-Log "Restored $($entry.Key)"
        } elseif (Test-Path $entry.Key) {
            Remove-Item -Path $entry.Key -Force
            Write-Log "Removed $($entry.Key) (did not exist before)"
        }
    }
    foreach ($entry in $PreviousEnv.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Machine')
        Write-Log "Restored environment variable $($entry.Key)"
    }
    Remove-Item -Path $BackupDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log 'Backups restored. Exiting.'
    exit 1
}

function Set-MachineEnv {
    param([string]$Name, [string]$Value)
    if (-not $PreviousEnv.ContainsKey($Name)) {
        $PreviousEnv[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Machine')
    }
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Machine')
    Write-Log "Set machine environment variable $Name"
}

function New-ParentDirectory {
    param([string]$Path)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

###############################################################################
# Helper: set index-url in a pip.ini file, preserving existing content
###############################################################################

function Set-PipConfIndex {
    param([string]$Path, [string]$Url)
    Backup-File $Path
    New-ParentDirectory $Path
    if ((Test-Path $Path) -and (Select-String -Path $Path -Pattern '^\[global\]' -Quiet)) {
        if (Select-String -Path $Path -Pattern '^index-url' -Quiet) {
            Write-Log "Updating existing index-url in $Path"
            (Get-Content $Path) -replace '^index-url.*', "index-url = $Url" | Set-Content -Path $Path -Encoding ascii
        } else {
            Write-Log "Adding index-url to existing [global] section in $Path"
            $lines = Get-Content $Path
            $out = foreach ($line in $lines) {
                $line
                if ($line -match '^\[global\]') { "index-url = $Url" }
            }
            $out | Set-Content -Path $Path -Encoding ascii
        }
    } else {
        Write-Log "Appending [global] section to $Path"
        Add-Content -Path $Path -Value "`r`n[global]`r`nindex-url = $Url" -Encoding ascii
    }
}

try {

###############################################################################
# npm -- global config in the Node.js install (system-wide)
#
# npm's machine-wide config lives at <node prefix>\etc\npmrc. The
# NPM_CONFIG_REGISTRY environment variable set below covers installs where
# Node.js lives somewhere else (nvm-windows, Volta, scoop).
###############################################################################

if ($NpmRegistryUrl) {
    $NpmrcPath = Join-Path $env:ProgramFiles 'nodejs\etc\npmrc'
    if (Test-Path (Join-Path $env:ProgramFiles 'nodejs')) {
        Write-Log 'Configuring npm registry'
        Backup-File $NpmrcPath
        New-ParentDirectory $NpmrcPath
        if ((Test-Path $NpmrcPath) -and (Select-String -Path $NpmrcPath -Pattern '^registry=' -Quiet)) {
            Write-Log "Updating existing registry in $NpmrcPath"
            (Get-Content $NpmrcPath) -replace '^registry=.*', "registry=$NpmRegistryUrl" | Set-Content -Path $NpmrcPath -Encoding ascii
        } else {
            Write-Log "Adding registry to $NpmrcPath"
            Add-Content -Path $NpmrcPath -Value "registry=$NpmRegistryUrl" -Encoding ascii
        }
    } else {
        Write-Log 'Node.js install dir not found; relying on NPM_CONFIG_REGISTRY environment variable'
    }
}

###############################################################################
# pip -- global config at C:\ProgramData\pip\pip.ini
###############################################################################

if ($PypiRegistryUrl) {
    Write-Log 'Configuring pip global index-url'
    Set-PipConfIndex -Path (Join-Path $env:ProgramData 'pip\pip.ini') -Url $PypiRegistryUrl
}

###############################################################################
# uv -- system-wide config at C:\ProgramData\uv\uv.toml
###############################################################################

if ($PypiRegistryUrl) {
    $UvConf = Join-Path $env:ProgramData 'uv\uv.toml'
    Write-Log 'Configuring uv index-url'
    Backup-File $UvConf
    New-ParentDirectory $UvConf
    if ((Test-Path $UvConf) -and (Select-String -Path $UvConf -Pattern '^index-url' -Quiet)) {
        Write-Log "Updating existing index-url in $UvConf"
        (Get-Content $UvConf) -replace '^index-url.*', "index-url = `"$PypiRegistryUrl`"" | Set-Content -Path $UvConf -Encoding ascii
    } else {
        Write-Log "Adding index-url to $UvConf"
        Add-Content -Path $UvConf -Value "index-url = `"$PypiRegistryUrl`"" -Encoding ascii
    }
}

###############################################################################
# Maven -- no machine-wide config path on Windows. Maven reads
# %MAVEN_HOME%\conf\settings.xml (per install) or %USERPROFILE%\.m2.
# Uncomment and set $MavenSettings to your Maven install if needed.
###############################################################################

# if ($MavenRegistryUrl) {
#     $MavenSettings = 'C:\Program Files\Apache\maven\conf\settings.xml'
#     Write-Log 'Configuring Maven mirror'
#     Backup-File $MavenSettings
#     New-ParentDirectory $MavenSettings
#     @"
# <settings>
#   <mirrors>
#     <mirror>
#       <id>socket-firewall</id>
#       <url>$MavenRegistryUrl</url>
#       <mirrorOf>*</mirrorOf>
#     </mirror>
#   </mirrors>
# </settings>
# "@ | Set-Content -Path $MavenSettings -Encoding ascii
# }

###############################################################################
# Go -- set via environment variable (GOPROXY)
# Handled in the environment variable section below
###############################################################################

###############################################################################
# NuGet -- machine-wide config dir (applies to all users and Visual Studio)
###############################################################################

# if ($NugetRegistryUrl) {
#     $NugetConfig = Join-Path ${env:ProgramFiles(x86)} 'NuGet\Config\SocketFirewall.config'
#     Write-Log 'Configuring NuGet source'
#     Backup-File $NugetConfig
#     New-ParentDirectory $NugetConfig
#     @"
# <?xml version="1.0" encoding="utf-8"?>
# <configuration>
#   <packageSources>
#     <clear />
#     <add key="socket-firewall" value="$NugetRegistryUrl" />
#   </packageSources>
# </configuration>
# "@ | Set-Content -Path $NugetConfig -Encoding ascii
# }

###############################################################################
# Cargo -- no machine-wide config path on Windows (CARGO_HOME is per user).
# The CARGO_REGISTRIES_SOCKET_FIREWALL_INDEX environment variable below covers
# it; pair with [registry] default = "socket-firewall" in per-user config.
###############################################################################

###############################################################################
# RubyGems -- system-wide config at C:\ProgramData\gemrc
###############################################################################

# if ($RubygemsRegistryUrl) {
#     $Gemrc = Join-Path $env:ProgramData 'gemrc'
#     Write-Log 'Configuring RubyGems source'
#     Backup-File $Gemrc
#     @"
# ---
# :sources:
#   - $RubygemsRegistryUrl
# "@ | Set-Content -Path $Gemrc -Encoding ascii
# }

###############################################################################
# Conda -- system-wide config at C:\ProgramData\conda\.condarc
###############################################################################

# if ($CondaRegistryUrl) {
#     $Condarc = Join-Path $env:ProgramData 'conda\.condarc'
#     Write-Log 'Configuring Conda channel'
#     Backup-File $Condarc
#     New-ParentDirectory $Condarc
#     @"
# channels:
#   - $CondaRegistryUrl
# default_channels:
#   - $CondaRegistryUrl
# "@ | Set-Content -Path $Condarc -Encoding ascii
# }

###############################################################################
# Machine environment variables (all users, all shells)
#
# Windows equivalent of the macOS shell-profile exports: these act as
# fallbacks in case a tool ignores config files. New sign-ins and newly
# started processes pick them up; already-running shells will not.
###############################################################################

if ($NpmRegistryUrl)  { Set-MachineEnv -Name 'NPM_CONFIG_REGISTRY' -Value $NpmRegistryUrl }
if ($PypiRegistryUrl) { Set-MachineEnv -Name 'PIP_INDEX_URL'       -Value $PypiRegistryUrl }
if ($PypiRegistryUrl) { Set-MachineEnv -Name 'UV_INDEX_URL'        -Value $PypiRegistryUrl }
# if ($GoRegistryUrl)    { Set-MachineEnv -Name 'GOPROXY' -Value "$GoRegistryUrl,direct" }
# if ($CargoRegistryUrl) { Set-MachineEnv -Name 'CARGO_REGISTRIES_SOCKET_FIREWALL_INDEX' -Value $CargoRegistryUrl }

###############################################################################
# Poetry
#
# Poetry does not support a global override for the default PyPI source URL.
# Each project must configure it in pyproject.toml:
#
#   [[tool.poetry.source]]
#   name = "pypi"
#   url = "https://<YOUR_FIREWALL_HOST>/pypi/simple"
#   priority = "primary"
#
# See: https://python-poetry.org/docs/repositories/#private-repository-example
###############################################################################

} catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Restore-Backups
}

# Clean up backups on success
Remove-Item -Path $BackupDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Log 'Done. Package managers configured to use Socket Registry Firewall.'
