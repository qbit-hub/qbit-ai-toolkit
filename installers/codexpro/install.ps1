[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkspaceRoot,

    [string]$Hostname = '',

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$')]
    [string]$TunnelName = 'codexpro-local',

    [ValidateSet('off', 'on-request', 'full-access')]
    [string]$HostExecMode = 'on-request',

    [ValidateSet('auto', 'quic', 'http2')]
    [string]$TunnelProtocol = 'http2',

    [ValidateSet('auto', 'bun', 'npm', 'pnpm')]
    [string]$PackageManager = 'auto',

    [string]$CloudflaredPath = '',

    [ValidateSet('openai', 'cloudflare', 'ngrok')]
    [string[]]$Tunnels,

    [ValidateSet('', 'openai', 'cloudflare', 'ngrok')]
    [string]$DefaultTunnel = '',

    [string]$NgrokHostname = '',
    [string]$NgrokConfigPath = (Join-Path $HOME '.config\ngrok\ngrok.yml'),
    [string]$NgrokExecutable = '',

    [string]$TunnelClientExecutable = (Join-Path $HOME '.tunnel-client\bin\tunnel-client.exe'),
    [string]$OpenAITunnelIdFile = (Join-Path $HOME '.tunnel-client\codexpro\tunnel-id.txt'),
    [string]$OpenAIRuntimeKeyFile = (Join-Path $HOME '.tunnel-client\secrets\runtime.key'),
    [string]$OpenAITunnelAlias = 'codexpro-laptop',
    [string]$OpenAITunnelProfile = 'codexpro-laptop',
    [string]$OpenAIProfileDir = (Join-Path $HOME '.config\tunnel-client'),

    [string]$StateDir = (Join-Path $HOME '.codexpro'),

    [string]$ProfilePath = ([string]$PROFILE),

    [switch]$SkipTunnelSetup,
    [switch]$SkipProfileUpdate,
    [switch]$SkipCodexLogin,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$InstallerVersion = '1.1.0'
$CodexProVersion = '0.29.0'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$InstallerRoot = $PSScriptRoot

if ($env:OS -ne 'Windows_NT') {
    throw 'installer.codexpro 1.1.0 is Windows-only.'
}

[string[]]$SelectedTunnels = if ($PSBoundParameters.ContainsKey('Tunnels')) {
    @($Tunnels | ForEach-Object { ([string]$_).ToLowerInvariant() })
}
else {
    @('cloudflare')
}
if ($SelectedTunnels.Count -eq 0) {
    throw 'Select at least one CodexPro tunnel provider: openai, cloudflare, or ngrok.'
}
$DuplicateTunnels = @($SelectedTunnels | Group-Object | Where-Object Count -gt 1)
if ($DuplicateTunnels.Count -gt 0) {
    throw "Duplicate tunnel provider selection: $($DuplicateTunnels.Name -join ', ')."
}

$EffectiveDefaultTunnel = if ($DefaultTunnel) { $DefaultTunnel.ToLowerInvariant() } else { $SelectedTunnels[0] }
if ($EffectiveDefaultTunnel -notin $SelectedTunnels) {
    throw "Default tunnel '$EffectiveDefaultTunnel' is not selected. Selected providers: $($SelectedTunnels -join ', ')."
}

$UseOpenAI = 'openai' -in $SelectedTunnels
$UseCloudflare = 'cloudflare' -in $SelectedTunnels
$UseNgrok = 'ngrok' -in $SelectedTunnels
$NeedsHttpToken = $UseCloudflare -or $UseNgrok
$HostnamePattern = '^(?=.{1,253}$)(?!-)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'

if ($UseCloudflare -and ([string]::IsNullOrWhiteSpace($Hostname) -or $Hostname -notmatch $HostnamePattern)) {
    throw 'Cloudflare selection requires -Hostname with a valid public DNS hostname.'
}
if ($UseNgrok -and ([string]::IsNullOrWhiteSpace($NgrokHostname) -or $NgrokHostname -notmatch $HostnamePattern)) {
    throw 'ngrok selection requires -NgrokHostname with a valid stable ngrok hostname.'
}
if ($SkipTunnelSetup -and -not $UseCloudflare) {
    throw '-SkipTunnelSetup is a Cloudflare-only compatibility switch and requires cloudflare in -Tunnels.'
}
if (-not (Test-Path -LiteralPath $WorkspaceRoot -PathType Container)) {
    throw "WorkspaceRoot does not exist: $WorkspaceRoot"
}
$ResolvedWorkspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path

function Refresh-ProcessPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $extras = @(
        (Join-Path $HOME '.bun\bin'),
        (Join-Path $HOME 'AppData\Local\Microsoft\WinGet\Links'),
        'C:\Program Files\Git\cmd',
        'C:\Program Files\Git\bin',
        'C:\Program Files\nodejs'
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }
    $env:PATH = (($extras + @($machine, $user)) | Where-Object { $_ }) -join ';'
}

function Resolve-CommandPath {
    param([Parameter(Mandatory)][string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and $command.Source) {
        return $command.Source
    }
    return $null
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Label,
        [switch]$AllowFailure
    )
    & $Executable @Arguments
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "$Label failed with exit code $code."
    }
    return $code
}

function Ensure-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Purpose
    )
    $winget = Resolve-CommandPath 'winget'
    if (-not $winget) {
        throw "$Purpose is missing and winget is unavailable. Install App Installer/winget or install $Purpose manually, then rerun."
    }
    Write-Host "Installing $Purpose with winget ($Id)..."
    Invoke-Native $winget @(
        'install', '--id', $Id, '--exact',
        '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity'
    ) "winget install $Id" | Out-Null
    Refresh-ProcessPath
}

function Get-GitBash {
    $candidates = @(
        'C:\Program Files\Git\bin\bash.exe',
        'C:\Program Files\Git\usr\bin\bash.exe'
    )
    return $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}

function Ensure-Git {
    $git = Resolve-CommandPath 'git'
    $bash = Get-GitBash
    if (-not $git -or -not $bash) {
        Ensure-WingetPackage -Id 'Git.Git' -Purpose 'Git for Windows'
        $git = Resolve-CommandPath 'git'
        $bash = Get-GitBash
    }
    if (-not $git -or -not $bash) {
        throw 'Git for Windows was installed or detected, but git.exe/Git Bash could not be resolved.'
    }
    return [pscustomobject]@{ Git = $git; Bash = $bash }
}

function Select-PackageManager {
    param([string]$Requested)
    Refresh-ProcessPath
    if ($Requested -ne 'auto') {
        $path = Resolve-CommandPath $Requested
        if (-not $path) {
            if ($Requested -eq 'bun') {
                Ensure-WingetPackage -Id 'Oven-sh.Bun' -Purpose 'Bun'
                $path = Resolve-CommandPath 'bun'
            }
            else {
                throw "Requested package manager is not available: $Requested"
            }
        }
        return [pscustomobject]@{ Name = $Requested; Executable = $path }
    }
    foreach ($candidate in @('bun', 'npm', 'pnpm')) {
        $path = Resolve-CommandPath $candidate
        if ($path) {
            return [pscustomobject]@{ Name = $candidate; Executable = $path }
        }
    }
    Ensure-WingetPackage -Id 'Oven-sh.Bun' -Purpose 'Bun'
    $bun = Resolve-CommandPath 'bun'
    if (-not $bun) {
        throw 'No supported package manager could be installed or resolved.'
    }
    return [pscustomobject]@{ Name = 'bun'; Executable = $bun }
}

function Infer-CodexProPackageManager {
    param([Parameter(Mandatory)][string]$Executable)

    $resolvedExecutable = [IO.Path]::GetFullPath($Executable)
    $bunBin = Join-Path $HOME '.bun\bin'
    if ($resolvedExecutable.StartsWith([IO.Path]::GetFullPath($bunBin), [StringComparison]::OrdinalIgnoreCase)) {
        return 'bun'
    }

    $npm = Resolve-CommandPath 'npm'
    if ($npm) {
        $npmRoot = (& $npm root -g 2>$null | Select-Object -Last 1)
        if ($LASTEXITCODE -eq 0 -and $npmRoot) {
            $npmRoot = $npmRoot.Trim()
            $npmBin = Split-Path -Parent $npmRoot
            if ((Split-Path -Parent $resolvedExecutable) -ieq $npmBin -and (Test-Path -LiteralPath (Join-Path $npmRoot 'codexpro\package.json') -PathType Leaf)) {
                return 'npm'
            }
        }
    }

    $pnpm = Resolve-CommandPath 'pnpm'
    if ($pnpm) {
        $pnpmBin = (& $pnpm bin -g 2>$null | Select-Object -Last 1)
        $pnpmRoot = (& $pnpm root -g 2>$null | Select-Object -Last 1)
        if ($pnpmBin -and $pnpmRoot -and $LASTEXITCODE -eq 0) {
            $pnpmBin = $pnpmBin.Trim()
            $pnpmRoot = $pnpmRoot.Trim()
            if ((Split-Path -Parent $resolvedExecutable) -ieq $pnpmBin -and (Test-Path -LiteralPath (Join-Path $pnpmRoot 'codexpro\package.json') -PathType Leaf)) {
                return 'pnpm'
            }
        }
    }

    return $null
}

function Install-GlobalPackage {
    param(
        [Parameter(Mandatory)]$Manager,
        [Parameter(Mandatory)][string]$PackageSpec
    )
    switch ($Manager.Name) {
        'bun'  { Invoke-Native $Manager.Executable @('add', '-g', $PackageSpec) "bun install $PackageSpec" | Out-Null }
        'npm'  { Invoke-Native $Manager.Executable @('install', '-g', $PackageSpec) "npm install $PackageSpec" | Out-Null }
        'pnpm' { Invoke-Native $Manager.Executable @('add', '-g', $PackageSpec) "pnpm install $PackageSpec" | Out-Null }
        default { throw "Unsupported package manager: $($Manager.Name)" }
    }
    Refresh-ProcessPath
}

function Resolve-CodexProPackageDir {
    param([Parameter(Mandatory)]$Manager)
    switch ($Manager.Name) {
        'bun' {
            $path = Join-Path $HOME '.bun\install\global\node_modules\codexpro'
        }
        'npm' {
            $root = (& $Manager.Executable root -g | Select-Object -Last 1).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $root) { throw 'npm root -g failed.' }
            $path = Join-Path $root 'codexpro'
        }
        'pnpm' {
            $root = (& $Manager.Executable root -g | Select-Object -Last 1).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $root) { throw 'pnpm root -g failed.' }
            $path = Join-Path $root 'codexpro'
        }
        default { throw "Unsupported package manager: $($Manager.Name)" }
    }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        throw "CodexPro package directory was not found after installation: $path"
    }
    return (Resolve-Path -LiteralPath $path).Path
}

function Ensure-CodexCli {
    param([Parameter(Mandatory)]$Manager)
    $codex = Resolve-CommandPath 'codex'
    if (-not $codex) {
        Write-Host 'Codex CLI not found; installing @openai/codex...'
        Install-GlobalPackage -Manager $Manager -PackageSpec '@openai/codex'
        $codex = Resolve-CommandPath 'codex'
    }
    if (-not $codex) {
        throw 'Codex CLI could not be resolved after installation.'
    }

    & $codex login status *> $null
    $status = $LASTEXITCODE
    if ($status -ne 0) {
        if ($SkipCodexLogin) {
            throw 'Codex CLI is not authenticated and -SkipCodexLogin was specified.'
        }
        Write-Host 'Codex CLI is not authenticated. Starting interactive Codex login...'
        Invoke-Native $codex @('login') 'codex login' | Out-Null
        & $codex login status *> $null
        if ($LASTEXITCODE -ne 0) {
            throw 'Codex CLI login did not produce an authenticated session.'
        }
    }
    return $codex
}

function Ensure-Cloudflared {
    param([string]$TargetStateDir)
    $cloudflared = Resolve-CommandPath 'cloudflared'
    if (-not $cloudflared) {
        $candidates = @(
            (Join-Path $TargetStateDir 'bin\cloudflared.exe'),
            (Join-Path $HOME '.codexpro\bin\cloudflared.exe')
        ) | Select-Object -Unique
        $cloudflared = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    }
    if (-not $cloudflared) {
        Ensure-WingetPackage -Id 'Cloudflare.cloudflared' -Purpose 'cloudflared'
        $cloudflared = Resolve-CommandPath 'cloudflared'
    }
    if (-not $cloudflared) {
        throw 'cloudflared could not be resolved after installation.'
    }
    return $cloudflared
}

function Ensure-Token {
    param([Parameter(Mandatory)][string]$TokenPath)
    if (Test-Path -LiteralPath $TokenPath -PathType Leaf) {
        $existing = [IO.File]::ReadAllText($TokenPath).Trim()
        if ($existing.Length -eq 64 -and $existing -match '^[0-9a-f]{64}$') {
            return
        }
        if (-not $Force) {
            throw "Existing CodexPro token is invalid. Use -Force to replace it: $TokenPath"
        }
    }
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = New-Object byte[] 32
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }
    $token = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
    [IO.File]::WriteAllText($TokenPath, $token, $Utf8NoBom)

    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    if (Test-Path -LiteralPath $icacls -PathType Leaf) {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        & $icacls $TokenPath '/inheritance:r' '/grant:r' "*$sid`:(F)" '/grant:r' '*S-1-5-18:(F)' *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to restrict ACLs on CodexPro token file: $TokenPath"
        }
    }
}

function Update-ManagedProfileBlock {
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$LauncherPath
    )
    $start = '# >>> qbit codexpro >>>'
    $end = '# <<< qbit codexpro <<<'
    $LauncherLiteral = $LauncherPath.Replace("'", "''")
    $block = @(
        $start
        'function cpx {'
        ('    $launcher = ''{0}''' -f $LauncherLiteral)
        '    & $launcher @args'
        '}'
        $end
    ) -join [Environment]::NewLine

    $parent = Split-Path -Parent $ProfilePath
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $current = if (Test-Path -LiteralPath $ProfilePath -PathType Leaf) { [IO.File]::ReadAllText($ProfilePath) } else { '' }
    $pattern = '(?ms)^' + [regex]::Escape($start) + '.*?^' + [regex]::Escape($end) + '\s*'
    if ([regex]::IsMatch($current, $pattern)) {
        $updated = [regex]::Replace($current, $pattern, $block.TrimEnd() + [Environment]::NewLine, 1)
    }
    else {
        $prefix = if ($current -and -not $current.EndsWith([Environment]::NewLine)) { $current + [Environment]::NewLine } else { $current }
        $updated = $prefix + $block
    }
    if ($updated -ne $current) {
        if ($current) {
            [IO.File]::WriteAllText("$ProfilePath.qbit-codexpro.bak", $current, $Utf8NoBom)
        }
        [IO.File]::WriteAllText($ProfilePath, $updated, $Utf8NoBom)
    }
}
function Ensure-CloudflareTunnel {
    param(
        [Parameter(Mandatory)][string]$Cloudflared,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$PublicHostname
    )
    $json = & $Cloudflared tunnel list --output json 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Cloudflare tunnel credentials were not available. Starting interactive cloudflared login...'
        Invoke-Native $Cloudflared @('tunnel', 'login') 'cloudflared tunnel login' | Out-Null
        $json = & $Cloudflared tunnel list --output json 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw 'cloudflared authentication did not become available after login.'
        }
    }
    $tunnels = @()
    if ($json) {
        $parsed = ($json -join [Environment]::NewLine) | ConvertFrom-Json
        $tunnels = @($parsed)
    }
    $existing = $tunnels | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $existing) {
        Write-Host "Creating Cloudflare named tunnel: $Name"
        Invoke-Native $Cloudflared @('tunnel', 'create', $Name) 'cloudflared tunnel create' | Out-Null
    }
    Write-Host "Routing $PublicHostname to Cloudflare tunnel $Name..."
    $routeCode = Invoke-Native $Cloudflared @('tunnel', 'route', 'dns', '--overwrite-dns', $Name, $PublicHostname) 'cloudflared tunnel route dns' -AllowFailure
    if ($routeCode -ne 0) {
        Invoke-Native $Cloudflared @('tunnel', 'route', 'dns', $Name, $PublicHostname) 'cloudflared tunnel route dns' | Out-Null
    }
    Invoke-Native $Cloudflared @('tunnel', 'info', $Name) 'cloudflared tunnel info' | Out-Null
}

Refresh-ProcessPath
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $StateDir 'backups') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $StateDir 'bin') -Force | Out-Null

$ExistingDeploymentPath = Join-Path $StateDir 'deployment.json'
$ExistingDeployment = $null
if (Test-Path -LiteralPath $ExistingDeploymentPath -PathType Leaf) {
    $ExistingDeployment = Get-Content -LiteralPath $ExistingDeploymentPath -Raw | ConvertFrom-Json
    if ($ExistingDeployment.installerId -and $ExistingDeployment.installerId -ne 'installer.codexpro' -and -not $Force) {
        throw "StateDir is owned by another deployment: $StateDir"
    }

    if ($UseCloudflare -and -not $Force) {
        $ExistingCloudflareHostname = if ($ExistingDeployment.providers -and $ExistingDeployment.providers.cloudflare) {
            [string]$ExistingDeployment.providers.cloudflare.hostname
        }
        else {
            [string]$ExistingDeployment.hostname
        }
        $ExistingCloudflareTunnelName = if ($ExistingDeployment.providers -and $ExistingDeployment.providers.cloudflare) {
            [string]$ExistingDeployment.providers.cloudflare.tunnelName
        }
        else {
            [string]$ExistingDeployment.tunnelName
        }
        if (($ExistingCloudflareHostname -and $ExistingCloudflareHostname -ne $Hostname) -or
            ($ExistingCloudflareTunnelName -and $ExistingCloudflareTunnelName -ne $TunnelName)) {
            throw 'Existing deployment uses a different Cloudflare hostname or tunnel name. Re-run with -Force to migrate it intentionally.'
        }
    }
}

$GitState = Ensure-Git

$CodexProCommandBefore = Resolve-CommandPath 'codexpro'
$ExistingCodexProVersion = $null
$ExistingCodexProManager = $null
if ($CodexProCommandBefore) {
    $versionOutput = & $CodexProCommandBefore --version 2>$null
    if ($LASTEXITCODE -eq 0 -and $versionOutput) {
        $ExistingCodexProVersion = (($versionOutput | Select-Object -Last 1) -replace '^codexpro\s+', '').Trim()
    }
    $ExistingCodexProManager = Infer-CodexProPackageManager -Executable $CodexProCommandBefore
    if (-not $ExistingCodexProManager) {
        throw "An existing CodexPro executable was found but its package manager could not be identified safely: $CodexProCommandBefore"
    }
}

$EffectivePackageManager = $PackageManager
if ($PackageManager -eq 'auto' -and $ExistingCodexProManager) {
    $EffectivePackageManager = $ExistingCodexProManager
}
elseif ($PackageManager -ne 'auto' -and $ExistingCodexProManager -and $PackageManager -ne $ExistingCodexProManager) {
    throw "CodexPro is currently managed by $ExistingCodexProManager, but -PackageManager $PackageManager was requested. Remove or migrate the existing global CodexPro installation explicitly before changing package managers."
}

$Manager = Select-PackageManager -Requested $EffectivePackageManager
$CodexExecutable = Ensure-CodexCli -Manager $Manager

$CloudflaredExecutable = ''
if ($UseCloudflare) {
    if ($CloudflaredPath) {
        if (-not (Test-Path -LiteralPath $CloudflaredPath -PathType Leaf)) {
            throw "Configured cloudflared executable does not exist: $CloudflaredPath"
        }
        $CloudflaredExecutable = (Resolve-Path -LiteralPath $CloudflaredPath).Path
    }
    else {
        $CloudflaredExecutable = Ensure-Cloudflared -TargetStateDir $StateDir
    }
}

$ResolvedNgrokExecutable = ''
if ($UseNgrok) {
    if ($NgrokExecutable) {
        if (-not (Test-Path -LiteralPath $NgrokExecutable -PathType Leaf)) {
            throw "Configured ngrok executable does not exist: $NgrokExecutable"
        }
        $ResolvedNgrokExecutable = (Resolve-Path -LiteralPath $NgrokExecutable).Path
    }
    else {
        $ResolvedNgrokExecutable = Resolve-CommandPath 'ngrok'
        if (-not $ResolvedNgrokExecutable) {
            Ensure-WingetPackage -Id 'Ngrok.Ngrok' -Purpose 'ngrok'
            $ResolvedNgrokExecutable = Resolve-CommandPath 'ngrok'
        }
    }
    if (-not $ResolvedNgrokExecutable) {
        throw 'ngrok could not be resolved after installation.'
    }
    if (-not (Test-Path -LiteralPath $NgrokConfigPath -PathType Leaf)) {
        throw "ngrok account configuration was not found: $NgrokConfigPath. Configure ngrok with your own account before rerunning."
    }
    & $ResolvedNgrokExecutable config check --config $NgrokConfigPath *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "ngrok configuration is invalid: $NgrokConfigPath"
    }
}

if ($UseOpenAI) {
    foreach ($OpenAIAsset in @($TunnelClientExecutable, $OpenAITunnelIdFile, $OpenAIRuntimeKeyFile)) {
        if ([string]::IsNullOrWhiteSpace($OpenAIAsset) -or -not (Test-Path -LiteralPath $OpenAIAsset -PathType Leaf)) {
            throw "Required OpenAI Secure MCP Tunnel asset is unavailable: $OpenAIAsset"
        }
    }
    if ([string]::IsNullOrWhiteSpace($OpenAITunnelAlias) -or [string]::IsNullOrWhiteSpace($OpenAITunnelProfile)) {
        throw 'OpenAI Secure MCP Tunnel alias and runtime profile must be non-empty.'
    }
    if (-not (Test-Path -LiteralPath $OpenAIProfileDir -PathType Container)) {
        throw "OpenAI tunnel profile directory is unavailable: $OpenAIProfileDir"
    }
    if ([string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($OpenAITunnelIdFile).Trim())) {
        throw "OpenAI tunnel id file is empty: $OpenAITunnelIdFile"
    }
    if ((Get-Item -LiteralPath $OpenAIRuntimeKeyFile).Length -le 0) {
        throw "OpenAI runtime key file is empty: $OpenAIRuntimeKeyFile"
    }
}

if ($CodexProCommandBefore -and -not $ExistingCodexProVersion) {
    throw "An existing CodexPro executable was found but its version could not be verified safely: $CodexProCommandBefore"
}
if ($ExistingCodexProVersion -and $ExistingCodexProVersion -ne $CodexProVersion) {
    throw "CodexPro $ExistingCodexProVersion is already installed. This installer is pinned to $CodexProVersion and will not overwrite a different version. Remove or migrate the existing installation explicitly, then rerun."
}
if (-not $CodexProCommandBefore) {
    Write-Host "Installing codexpro@$CodexProVersion with $($Manager.Name)..."
    Install-GlobalPackage -Manager $Manager -PackageSpec "codexpro@$CodexProVersion"
}
$CodexProExecutable = Resolve-CommandPath 'codexpro'
if (-not $CodexProExecutable) {
    throw 'codexpro executable could not be resolved after installation.'
}
$InstalledCodexProManager = Infer-CodexProPackageManager -Executable $CodexProExecutable
if (-not $InstalledCodexProManager -or $InstalledCodexProManager -ne $Manager.Name) {
    throw "CodexPro executable resolved through an unexpected package manager after installation: $CodexProExecutable"
}
$PackageDir = Resolve-CodexProPackageDir -Manager $Manager

$PatchScript = Join-Path $InstallerRoot 'lib\patch-codexpro.ps1'
$PatchJson = & $PatchScript -PackageDir $PackageDir -BackupRoot (Join-Path $StateDir 'backups') -Force:$Force
$PatchResult = $PatchJson | ConvertFrom-Json

$TokenFile = Join-Path $StateDir 'http-token'
$TokenWasPresentBefore = if ($ExistingDeployment -and $null -ne $ExistingDeployment.tokenWasPresentBefore) {
    [bool]$ExistingDeployment.tokenWasPresentBefore
}
else {
    Test-Path -LiteralPath $TokenFile -PathType Leaf
}
if ($NeedsHttpToken) {
    Ensure-Token -TokenPath $TokenFile
}
elseif ($ExistingDeployment -and -not $TokenWasPresentBefore -and (Test-Path -LiteralPath $TokenFile -PathType Leaf)) {
    Remove-Item -LiteralPath $TokenFile -Force
}

$AssetNames = @(
    'Start-CodexPro.ps1',
    'Start-CodexPro.openai.ps1',
    'Start-CodexPro.cloudflare.ps1',
    'Start-CodexPro.ngrok.ps1',
    'Get-CodexProConnectorUrl.ps1'
)
$PreviouslyOwnedAssets = if ($ExistingDeployment -and $ExistingDeployment.managedAssets) {
    @($ExistingDeployment.managedAssets | ForEach-Object { [string]$_ })
}
elseif ($ExistingDeployment) {
    @('Start-CodexPro.ps1', 'Get-CodexProConnectorUrl.ps1')
}
else {
    @()
}

$PreviousAssetBackups = [ordered]@{}
if ($ExistingDeployment -and $ExistingDeployment.previousAssetBackups) {
    foreach ($Property in $ExistingDeployment.previousAssetBackups.PSObject.Properties) {
        $PreviousAssetBackups[$Property.Name] = [string]$Property.Value
    }
}
elseif ($ExistingDeployment) {
    $PreviousAssetBackups['Start-CodexPro.ps1'] = [string]$ExistingDeployment.previousLauncherBackup
    $PreviousAssetBackups['Get-CodexProConnectorUrl.ps1'] = [string]$ExistingDeployment.previousUrlHelperBackup
}

$AssetBackupDir = $null
foreach ($AssetName in $AssetNames) {
    $Target = Join-Path $StateDir $AssetName
    if ((Test-Path -LiteralPath $Target -PathType Leaf) -and
        $AssetName -notin $PreviouslyOwnedAssets -and
        -not $PreviousAssetBackups.Contains($AssetName)) {
        if (-not $AssetBackupDir) {
            $AssetBackupDir = Join-Path (Join-Path $StateDir 'backups') ("pre-installer-state-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            New-Item -ItemType Directory -Path $AssetBackupDir -Force | Out-Null
        }
        $Backup = Join-Path $AssetBackupDir $AssetName
        Copy-Item -LiteralPath $Target -Destination $Backup
        $PreviousAssetBackups[$AssetName] = $Backup
    }
}

foreach ($AssetName in $AssetNames) {
    $Source = Join-Path (Join-Path $InstallerRoot 'templates') $AssetName
    $Target = Join-Path $StateDir $AssetName
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Required installer template is missing: $Source"
    }
    Copy-Item -LiteralPath $Source -Destination $Target -Force
}

$LauncherTarget = Join-Path $StateDir 'Start-CodexPro.ps1'
$UrlHelperTarget = Join-Path $StateDir 'Get-CodexProConnectorUrl.ps1'

if ($UseCloudflare -and -not $SkipTunnelSetup) {
    Ensure-CloudflareTunnel -Cloudflared $CloudflaredExecutable -Name $TunnelName -PublicHostname $Hostname
}

if (-not $SkipProfileUpdate) {
    Update-ManagedProfileBlock -ProfilePath $ProfilePath -LauncherPath $LauncherTarget
}

$Providers = [ordered]@{}
if ($UseOpenAI) {
    $Providers.openai = [ordered]@{
        tunnelClient = (Resolve-Path -LiteralPath $TunnelClientExecutable).Path
        tunnelIdFile = (Resolve-Path -LiteralPath $OpenAITunnelIdFile).Path
        runtimeKeyFile = (Resolve-Path -LiteralPath $OpenAIRuntimeKeyFile).Path
        alias = $OpenAITunnelAlias
        profile = $OpenAITunnelProfile
        profileDir = [IO.Path]::GetFullPath($OpenAIProfileDir)
        localPort = 8788
    }
}
if ($UseCloudflare) {
    $Providers.cloudflare = [ordered]@{
        hostname = $Hostname
        tunnelName = $TunnelName
        tunnelProtocol = $TunnelProtocol
        executable = $CloudflaredExecutable
        localPort = 8787
        provisioned = -not [bool]$SkipTunnelSetup
    }
}
if ($UseNgrok) {
    $Providers.ngrok = [ordered]@{
        hostname = $NgrokHostname
        executable = $ResolvedNgrokExecutable
        configPath = [IO.Path]::GetFullPath($NgrokConfigPath)
        localPort = 8789
    }
}

$Deployment = [ordered]@{
    schemaVersion = 2
    installerId = 'installer.codexpro'
    installerVersion = $InstallerVersion
    codexProVersion = $CodexProVersion
    installedAt = (Get-Date).ToString('o')
    workspaceRoot = $ResolvedWorkspace
    tunnels = $SelectedTunnels
    defaultTunnel = $EffectiveDefaultTunnel
    providers = $Providers
    hostExecMode = $HostExecMode
    packageManager = $Manager.Name
    packageManagerExecutable = $Manager.Executable
    packageDir = $PackageDir
    codexProExecutable = $CodexProExecutable
    codexExecutable = $CodexExecutable
    gitExecutable = $GitState.Git
    gitBash = $GitState.Bash

    hostname = if ($UseCloudflare) { $Hostname } else { '' }
    tunnelName = if ($UseCloudflare) { $TunnelName } else { '' }
    tunnelProtocol = if ($UseCloudflare) { $TunnelProtocol } else { '' }
    cloudflaredExecutable = if ($UseCloudflare) { $CloudflaredExecutable } else { '' }
    tunnelConfigured = $UseCloudflare -and -not [bool]$SkipTunnelSetup

    profileManaged = -not [bool]$SkipProfileUpdate
    profilePath = $ProfilePath
    patchBackupDir = if ($PatchResult.backupDir) { [string]$PatchResult.backupDir } elseif ($ExistingDeployment) { [string]$ExistingDeployment.patchBackupDir } else { '' }
    codexProWasPresentBefore = if ($ExistingDeployment -and $null -ne $ExistingDeployment.codexProWasPresentBefore) { [bool]$ExistingDeployment.codexProWasPresentBefore } else { [bool]$CodexProCommandBefore }
    tokenWasPresentBefore = $TokenWasPresentBefore
    managedAssets = $AssetNames
    previousAssetBackups = $PreviousAssetBackups
    previousLauncherBackup = if ($PreviousAssetBackups.Contains('Start-CodexPro.ps1')) { [string]$PreviousAssetBackups['Start-CodexPro.ps1'] } else { '' }
    previousUrlHelperBackup = if ($PreviousAssetBackups.Contains('Get-CodexProConnectorUrl.ps1')) { [string]$PreviousAssetBackups['Get-CodexProConnectorUrl.ps1'] } else { '' }
}

$DeploymentJson = $Deployment | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText($ExistingDeploymentPath, $DeploymentJson, $Utf8NoBom)

$VerifyScript = Join-Path $InstallerRoot 'verify.ps1'
& $VerifyScript -StateDir $StateDir -SkipTunnelCheck:$SkipTunnelSetup | Out-Host

Write-Host ''
Write-Host 'CodexPro installation completed.'
Write-Host "State:       $StateDir"
Write-Host "Workspace:   $ResolvedWorkspace"
Write-Host "Tunnels:     $($SelectedTunnels -join ', ')"
Write-Host "Default:     $EffectiveDefaultTunnel"
Write-Host "Host access: $HostExecMode"
if (-not $SkipProfileUpdate) {
    Write-Host 'Start:       open a new PowerShell session and run cpx'
}
else {
    Write-Host "Start:       & '$LauncherTarget'"
}
if ($NeedsHttpToken) {
    Write-Host "Connector URL helper (explicitly prints a secret): & '$UrlHelperTarget'"
}

[pscustomobject]@{
    status = 'ok'
    installer = 'installer.codexpro'
    version = $InstallerVersion
    stateDir = $StateDir
    workspaceRoot = $ResolvedWorkspace
    tunnels = $SelectedTunnels
    defaultTunnel = $EffectiveDefaultTunnel
    hostExecMode = $HostExecMode
} | ConvertTo-Json -Compress
