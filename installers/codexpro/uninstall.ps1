[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$StateDir = (Join-Path $HOME '.codexpro'),
    [switch]$RemoveTunnel,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if ($env:OS -ne 'Windows_NT') {
    throw 'installer.codexpro uninstall is Windows-only.'
}

$DeploymentPath = Join-Path $StateDir 'deployment.json'
if (-not (Test-Path -LiteralPath $DeploymentPath -PathType Leaf)) {
    throw "CodexPro installer state not found: $DeploymentPath"
}
$Deployment = Get-Content -LiteralPath $DeploymentPath -Raw | ConvertFrom-Json
if ($Deployment.installerId -ne 'installer.codexpro') {
    throw "Refusing to uninstall unowned state from $StateDir."
}

[string[]]$SelectedTunnels = if ($Deployment.tunnels) {
    @($Deployment.tunnels | ForEach-Object { ([string]$_).ToLowerInvariant() })
}
elseif ($Deployment.hostname) {
    @('cloudflare')
}
else {
    @()
}

function Remove-ManagedProfileBlock {
    param([string]$ProfilePath)
    if (-not $ProfilePath -or -not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) {
        return
    }
    $Start = '# >>> qbit codexpro >>>'
    $End = '# <<< qbit codexpro <<<'
    $Current = [IO.File]::ReadAllText($ProfilePath)
    $Pattern = '(?ms)^' + [regex]::Escape($Start) + '.*?^' + [regex]::Escape($End) + '\s*'
    $Updated = [regex]::Replace($Current, $Pattern, '', 1)
    if ($Updated -ne $Current) {
        [IO.File]::WriteAllText($ProfilePath, $Updated, $Utf8NoBom)
    }
}

function Remove-InstallerOwnedCodexProPackage {
    if ([bool]$Deployment.codexProWasPresentBefore) {
        return $false
    }

    $ManagerName = [string]$Deployment.packageManager
    $ManagerExecutable = [string]$Deployment.packageManagerExecutable
    if (-not $ManagerExecutable -or -not (Test-Path -LiteralPath $ManagerExecutable -PathType Leaf)) {
        $Resolved = Get-Command $ManagerName -ErrorAction SilentlyContinue | Select-Object -First 1
        $ManagerExecutable = if ($Resolved) { $Resolved.Source } else { $null }
    }
    if (-not $ManagerExecutable) {
        throw "Package manager required to remove installer-owned CodexPro is unavailable: $ManagerName"
    }

    switch ($ManagerName) {
        'bun'  { & $ManagerExecutable remove -g codexpro }
        'npm'  { & $ManagerExecutable uninstall -g codexpro }
        'pnpm' { & $ManagerExecutable remove -g codexpro }
        default { throw "Unsupported recorded package manager: $ManagerName" }
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to remove installer-owned CodexPro with $ManagerName (exit $LASTEXITCODE)."
    }
    return $true
}

function Restore-PackagePatch {
    param([string]$BackupDir, [string]$PackageDir)
    if (-not $BackupDir) { return $false }
    if (-not (Test-Path -LiteralPath $BackupDir -PathType Container)) {
        throw "Recorded CodexPro patch backup is missing: $BackupDir"
    }
    $MetadataPath = Join-Path $BackupDir 'backup.json'
    if (-not (Test-Path -LiteralPath $MetadataPath -PathType Leaf)) {
        throw "CodexPro patch backup metadata is missing: $MetadataPath"
    }
    if (-not (Test-Path -LiteralPath $PackageDir -PathType Container)) {
        throw "Installed CodexPro package directory is missing: $PackageDir"
    }
    $PackageJsonPath = Join-Path $PackageDir 'package.json'
    $Package = Get-Content -LiteralPath $PackageJsonPath -Raw | ConvertFrom-Json
    if ($Package.name -ne 'codexpro' -or $Package.version -ne '0.29.0') {
        throw "Refusing to restore a 0.29.0 backup over $($Package.name)@$($Package.version)."
    }

    $Dist = Join-Path $PackageDir 'dist'
    $ServerPath = Join-Path $Dist 'server.js'
    $ConfigPath = Join-Path $Dist 'config.js'
    $BashPath = Join-Path $Dist 'bashOps.js'
    $HostPath = Join-Path $Dist 'hostOps.js'
    $OwnedMarkersPresent =
        (Test-Path -LiteralPath $ServerPath -PathType Leaf) -and
        [IO.File]::ReadAllText($ServerPath).Contains('registerCodexTool(config, server, "host_exec"') -and
        (Test-Path -LiteralPath $ConfigPath -PathType Leaf) -and
        [IO.File]::ReadAllText($ConfigPath).Contains('CODEXPRO_HOST_EXEC_MODE')
    if (-not $OwnedMarkersPresent -and -not $Force) {
        throw 'Current CodexPro package no longer matches the installer-owned patch. Use -Force only after reviewing the package drift.'
    }

    $BackupMetadata = Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json
    Copy-Item -LiteralPath (Join-Path $BackupDir 'bashOps.js') -Destination $BashPath -Force
    Copy-Item -LiteralPath (Join-Path $BackupDir 'config.js') -Destination $ConfigPath -Force
    Copy-Item -LiteralPath (Join-Path $BackupDir 'server.js') -Destination $ServerPath -Force
    if ([bool]$BackupMetadata.hostOpsExisted) {
        Copy-Item -LiteralPath (Join-Path $BackupDir 'hostOps.js') -Destination $HostPath -Force
    }
    else {
        Remove-Item -LiteralPath $HostPath -Force -ErrorAction SilentlyContinue
    }
    return $true
}

$PackageRestored = $false
if ($PSCmdlet.ShouldProcess([string]$Deployment.packageDir, 'restore CodexPro package patch backup')) {
    $PackageRestored = Restore-PackagePatch -BackupDir ([string]$Deployment.patchBackupDir) -PackageDir ([string]$Deployment.packageDir)
}

$PackageRemoved = $false
if (-not [bool]$Deployment.codexProWasPresentBefore -and $PSCmdlet.ShouldProcess('codexpro', 'remove installer-owned global CodexPro package')) {
    $PackageRemoved = Remove-InstallerOwnedCodexProPackage
}

if ([bool]$Deployment.profileManaged -and $PSCmdlet.ShouldProcess([string]$Deployment.profilePath, 'remove managed cpx profile block')) {
    Remove-ManagedProfileBlock -ProfilePath ([string]$Deployment.profilePath)
}

$ManagedAssets = if ($Deployment.managedAssets) {
    @($Deployment.managedAssets | ForEach-Object { [string]$_ })
}
else {
    @('Start-CodexPro.ps1', 'Get-CodexProConnectorUrl.ps1')
}
$PreviousAssetBackups = @{}
if ($Deployment.previousAssetBackups) {
    foreach ($Property in $Deployment.previousAssetBackups.PSObject.Properties) {
        $PreviousAssetBackups[$Property.Name] = [string]$Property.Value
    }
}
else {
    if ($Deployment.previousLauncherBackup) {
        $PreviousAssetBackups['Start-CodexPro.ps1'] = [string]$Deployment.previousLauncherBackup
    }
    if ($Deployment.previousUrlHelperBackup) {
        $PreviousAssetBackups['Get-CodexProConnectorUrl.ps1'] = [string]$Deployment.previousUrlHelperBackup
    }
}

foreach ($AssetName in $ManagedAssets) {
    $AssetPath = Join-Path $StateDir $AssetName
    if (-not $PSCmdlet.ShouldProcess($AssetPath, 'restore or remove managed CodexPro asset')) {
        continue
    }

    $BackupPath = if ($PreviousAssetBackups.ContainsKey($AssetName)) { [string]$PreviousAssetBackups[$AssetName] } else { '' }
    if ($BackupPath -and (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        Copy-Item -LiteralPath $BackupPath -Destination $AssetPath -Force
    }
    else {
        Remove-Item -LiteralPath $AssetPath -Force -ErrorAction SilentlyContinue
    }
}

$TokenPath = Join-Path $StateDir 'http-token'
if (-not [bool]$Deployment.tokenWasPresentBefore -and $PSCmdlet.ShouldProcess($TokenPath, 'remove installer-created MCP token')) {
    Remove-Item -LiteralPath $TokenPath -Force -ErrorAction SilentlyContinue
}

$TunnelRemoved = $false
if ($RemoveTunnel) {
    if ('cloudflare' -notin $SelectedTunnels) {
        throw '-RemoveTunnel only applies to a configured Cloudflare named tunnel.'
    }

    $CloudflareProvider = if ($Deployment.providers -and $Deployment.providers.cloudflare) { $Deployment.providers.cloudflare } else { $null }
    $Cloudflared = if ($CloudflareProvider -and $CloudflareProvider.executable) {
        [string]$CloudflareProvider.executable
    }
    else {
        [string]$Deployment.cloudflaredExecutable
    }
    $TunnelName = if ($CloudflareProvider -and $CloudflareProvider.tunnelName) {
        [string]$CloudflareProvider.tunnelName
    }
    else {
        [string]$Deployment.tunnelName
    }

    if (-not (Test-Path -LiteralPath $Cloudflared -PathType Leaf)) {
        throw "cloudflared is unavailable; cannot remove tunnel $TunnelName."
    }
    if ($PSCmdlet.ShouldProcess($TunnelName, 'delete Cloudflare named tunnel')) {
        & $Cloudflared tunnel delete --force $TunnelName
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to delete Cloudflare tunnel $TunnelName. DNS cleanup may still be required in Cloudflare."
        }
        $TunnelRemoved = $true
    }
}

if ($PSCmdlet.ShouldProcess($DeploymentPath, 'remove installer ownership state')) {
    Remove-Item -LiteralPath $DeploymentPath -Force
}

Write-Host 'CodexPro installer-owned state was removed.'
if (-not $RemoveTunnel -and 'cloudflare' -in $SelectedTunnels -and [bool]$Deployment.tunnelConfigured) {
    Write-Host "Cloudflare tunnel '$($Deployment.tunnelName)' was preserved."
}
if ('openai' -in $SelectedTunnels) {
    Write-Host 'OpenAI tunnel-client configuration, tunnel id, and runtime key were preserved.'
}
if ('ngrok' -in $SelectedTunnels) {
    Write-Host 'ngrok account configuration and hostname ownership were preserved.'
}
Write-Host 'Shared host dependencies were preserved.'

[pscustomobject]@{
    status = 'ok'
    installer = 'installer.codexpro'
    tunnelRemoved = $TunnelRemoved
    packageRestored = [bool]$PackageRestored
    packageRemoved = [bool]$PackageRemoved
} | ConvertTo-Json -Compress
