param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('start', 'status', 'checkpoint', 'audit')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot,

    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [switch]$Offline
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'context-continuity.ps1')

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -C $WorkingDirectory @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "Git command failed in '$WorkingDirectory': git $($Arguments -join ' ')"
    }

    [pscustomobject]@{
        ExitCode = $code
        Output = ($output -join "`n").Trim()
    }
}

function Get-GitHubCredentialPrefix {
    param([string]$Remote)

    if ($Remote -notmatch '^https?://github\.com(?:/|$)') { return @() }
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if ($null -eq $gh) { return @() }

    return @(
        '-c', 'credential.helper=',
        '-c', 'credential.helper=!gh auth git-credential'
    )
}

function Invoke-GitNetwork {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Remote,
        [switch]$AllowFailure
    )

    $result = Invoke-Git -WorkingDirectory $WorkingDirectory -Arguments $Arguments -AllowFailure
    if ($result.ExitCode -eq 0) { return $result }

    $credentialPrefix = @(Get-GitHubCredentialPrefix -Remote $Remote)
    if ($credentialPrefix.Count -gt 0) {
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = @(& git @credentialPrefix -C $WorkingDirectory @Arguments 2>&1)
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        $result = [pscustomobject]@{ ExitCode = $code; Output = ($output -join "`n").Trim() }
    }

    if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
        throw "Git network command failed in '$WorkingDirectory': git $($Arguments -join ' ')"
    }
    return $result
}

function Resolve-RepoPath {
    param([string]$Root, [string]$PathValue)
    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        throw 'AI context cachePath must be repository-relative.'
    }
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@([char]92,[char]47))
    $resolved = [System.IO.Path]::GetFullPath((Join-Path $rootFull $PathValue))
    $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not (($resolved + [System.IO.Path]::DirectorySeparatorChar).StartsWith($prefix,[System.StringComparison]::OrdinalIgnoreCase))) {
        throw 'AI context cachePath must remain inside the member repository.'
    }
    $current = $rootFull
    foreach ($segment in $PathValue.Replace([char]92,[char]47).Split('/')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.') { continue }
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'AI context cachePath must not traverse a reparse point.'
            }
        }
    }
    return $resolved
}

function Get-GitState {
    param([string]$Root)

    $branch = (Invoke-Git -WorkingDirectory $Root -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')).Output
    $head = (Invoke-Git -WorkingDirectory $Root -Arguments @('rev-parse', 'HEAD')).Output
    $porcelain = (Invoke-Git -WorkingDirectory $Root -Arguments @('status', '--porcelain')).Output
    $dirty = -not [string]::IsNullOrWhiteSpace($porcelain)

    $upstreamNameResult = Invoke-Git -WorkingDirectory $Root -Arguments @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}') -AllowFailure
    $upstream = $null
    $ahead = $null
    $behind = $null
    if ($upstreamNameResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($upstreamNameResult.Output)) {
        $upstream = $upstreamNameResult.Output
        $counts = Invoke-Git -WorkingDirectory $Root -Arguments @('rev-list', '--left-right', '--count', "HEAD...$upstream") -AllowFailure
        if ($counts.ExitCode -eq 0 -and $counts.Output -match '^(\d+)\s+(\d+)$') {
            $ahead = [int]$Matches[1]
            $behind = [int]$Matches[2]
        }
    }

    [pscustomobject]@{
        branch = $branch
        head = $head
        dirty = $dirty
        upstream = $upstream
        ahead = $ahead
        behind = $behind
        fingerprint = (Get-ContinuityFingerprint -Root $Root)
    }
}

function Assert-RequiredContextFiles {
    param([string]$ContextRoot)
    $required = @(
        'AI_CONTEXT.md',
        'project/authority.md',
        'state/current.md',
        'state/next-action.md',
        'repositories/repositories.yaml'
    )
    foreach ($relative in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $ContextRoot $relative) -PathType Leaf)) {
            throw "Central context is missing required file: $relative"
        }
    }
}

function Normalize-RegistryValue {
    param([string]$Raw, [string]$Label)
    $value = $Raw.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Repository registry $Label must not be empty." }
    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        if ($value.Length -lt 2) { throw "Repository registry $Label has invalid quoted scalar syntax." }
        $value = $value.Substring(1, $value.Length - 2)
    }
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Repository registry $Label must not be empty." }
    return $value
}

function Get-RepositoryRegistry {
    param([string]$ContextRoot)
    $path = Join-Path $ContextRoot 'repositories/repositories.yaml'
    $project = $null
    $repositories = [ordered]@{}
    $inRepositories = $false
    $sawRepositories = $false
    $currentRepository = $null
    $currentRole = $null
    $currentPath = $null
    $ignoredTopLevelBlock = $false
    $ignoredRepositoryMetadata = $false

    foreach ($line in @(Get-Content -LiteralPath $path)) {
        $text = [string]$line
        if ($text.Contains("`t")) { throw 'Repository registry must not use tab indentation.' }
        if ([string]::IsNullOrWhiteSpace($text) -or $text.TrimStart().StartsWith('#')) { continue }
        $indent = [regex]::Match($text, '^ *').Length
        if (($indent % 2) -ne 0) { throw 'Repository registry must use two-space indentation.' }

        if ($ignoredTopLevelBlock) {
            if ($indent -gt 0) { continue }
            $ignoredTopLevelBlock = $false
        }
        if ($inRepositories -and $ignoredRepositoryMetadata) {
            if ($indent -gt 4) { continue }
            $ignoredRepositoryMetadata = $false
        }

        if ($inRepositories -and -not $text.StartsWith(' ')) {
            if ($null -ne $currentRepository) {
                if ([string]::IsNullOrWhiteSpace($currentRole)) { throw "Repository registry entry '$currentRepository' is missing required role." }
                $repositories[$currentRepository] = [ordered]@{ role = $currentRole; path = $currentPath }
                $currentRepository = $null; $currentRole = $null; $currentPath = $null
            }
            $inRepositories = $false
        }

        if ($inRepositories) {
            if ($text -match '^  ([A-Za-z0-9][A-Za-z0-9._-]{0,127}):\s*\z') {
                if ($null -ne $currentRepository) {
                    if ([string]::IsNullOrWhiteSpace($currentRole)) { throw "Repository registry entry '$currentRepository' is missing required role." }
                    $repositories[$currentRepository] = [ordered]@{ role = $currentRole; path = $currentPath }
                }
                $repoId = [string]$Matches[1]
                if ($repositories.Contains($repoId)) { throw "Repository registry contains duplicate repository id '$repoId'." }
                $currentRepository = $repoId; $currentRole = $null; $currentPath = $null
                continue
            }
            if ($null -ne $currentRepository -and $text -match '^    (path|role):\s*(.*)\z') {
                $field = [string]$Matches[1]
                $value = Normalize-RegistryValue -Raw ([string]$Matches[2]) -Label "$currentRepository.$field"
                if ($field -eq 'role') {
                    if ($null -ne $currentRole) { throw "Repository registry entry '$currentRepository' contains duplicate role." }
                    $currentRole = $value
                } else {
                    if ($null -ne $currentPath) { throw "Repository registry entry '$currentRepository' contains duplicate path." }
                    $currentPath = $value
                }
                continue
            }
            if ($null -ne $currentRepository -and $text -match '^    ([A-Za-z0-9_][A-Za-z0-9_.-]*):\s*(.*)\z') {
                $metadataField = [string]$Matches[1]
                $metadataValue = [string]$Matches[2]
                if ([string]::IsNullOrWhiteSpace($metadataValue)) {
                    $ignoredRepositoryMetadata = $true
                } else {
                    $null = Normalize-RegistryValue -Raw $metadataValue -Label "$currentRepository.$metadataField"
                }
                continue
            }
            throw "Repository registry has unsupported repositories structure: $text"
        }

        if ($text -match '^project:\s*(.+)\z') {
            if ($null -ne $project) { throw 'Repository registry contains duplicate project field.' }
            $project = Normalize-RegistryValue -Raw ([string]$Matches[1]) -Label 'project'
            continue
        }
        if ($text -match '^repositories:\s*(.*)\z') {
            if ($sawRepositories) { throw 'Repository registry contains duplicate repositories field.' }
            $sawRepositories = $true
            $value = ([string]$Matches[1]).Trim()
            if ([string]::IsNullOrWhiteSpace($value)) { $inRepositories = $true; continue }
            if ($value -eq '[]' -or $value -eq '{}') { continue }
            throw 'Repository registry repositories field must be an indented mapping, [] or {}.'
        }
        if ($text -match '^(schema_version|workspace_root|context_source_mode|context_source):\s*(.*)\z') { continue }
        if ($text -match '^([A-Za-z0-9_][A-Za-z0-9_.-]*):\s*(.*)\z') {
            $metadataField = [string]$Matches[1]
            $metadataValue = [string]$Matches[2]
            if ([string]::IsNullOrWhiteSpace($metadataValue)) {
                $ignoredTopLevelBlock = $true
            } else {
                $null = Normalize-RegistryValue -Raw $metadataValue -Label $metadataField
            }
            continue
        }
        throw "Repository registry contains unsupported top-level syntax: $text"
    }

    if ($null -ne $currentRepository) {
        if ([string]::IsNullOrWhiteSpace($currentRole)) { throw "Repository registry entry '$currentRepository' is missing required role." }
        $repositories[$currentRepository] = [ordered]@{ role = $currentRole; path = $currentPath }
    }
    if ([string]::IsNullOrWhiteSpace($project)) { throw 'Repository registry is missing required project field.' }
    if (-not $sawRepositories) { throw 'Repository registry is missing required repositories field.' }
    return [pscustomobject]@{ project = $project; repositories = $repositories; path = 'repositories/repositories.yaml' }
}

function Get-MembershipInfo {
    param([string]$ContextRoot, [object]$Config)
    $registry = Get-RepositoryRegistry -ContextRoot $ContextRoot
    $configuredProject = [string]$Config.project
    $repoId = [string]$Config.repository
    $projectMatches = $configuredProject -ceq [string]$registry.project
    $entry = if ($projectMatches -and $registry.repositories.Contains($repoId)) { $registry.repositories[$repoId] } else { $null }
    $registered = $null -ne $entry
    $issue = if (-not $projectMatches) {
        "Member project '$configuredProject' does not match central context project '$($registry.project)'."
    } elseif (-not $registered) {
        "Repository '$repoId' is not registered in $($registry.path)."
    } else { $null }
    return [pscustomobject]@{
        registered = $registered
        projectMatches = $projectMatches
        centralProject = [string]$registry.project
        role = $(if ($null -ne $entry) { [string]$entry.role } else { $null })
        path = $(if ($null -ne $entry) { $entry.path } else { $null })
        registryPath = [string]$registry.path
        issue = $issue
    }
}

function Assert-RegisteredMember {
    param([string]$ContextRoot, [object]$Config)
    $membership = Get-MembershipInfo -ContextRoot $ContextRoot -Config $Config
    if (-not $membership.projectMatches -or -not $membership.registered) { throw [string]$membership.issue }
    return $membership
}

function Get-ContextRemoteRepositoryName {
    param([string]$Remote)
    $value = $Remote.TrimEnd([char[]]@([char]92,[char]47))
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    $name = ($value -split '[/\\]')[-1]
    if ($name.EndsWith('.git')) { return $name.Substring(0, $name.Length - 4) }
    return $name
}

function Get-NormalizedRemoteIdentity {
    param([string]$Remote)
    $value = ([string]$Remote).Trim().Replace([char]92, [char]47).TrimEnd([char]47)
    if ([string]::IsNullOrWhiteSpace($value)) { return '' }
    if ($value.EndsWith('.git')) { $value = $value.Substring(0, $value.Length - 4) }
    if ($value -match '^[^@/\s]+@([^:]+):(.+)$') {
        return ($Matches[1].ToLowerInvariant() + '/' + $Matches[2].TrimStart([char]47))
    }
    if ($value -match '^[A-Za-z][A-Za-z0-9+.-]*://(?:[^@/]+@)?([^/]+)/(.+)$') {
        return ($Matches[1].ToLowerInvariant() + '/' + $Matches[2].TrimStart([char]47))
    }
    return $value
}

function Test-RepositoryRemoteMatch {
    param([string]$RepositoryRoot, [string]$ExpectedRemote)
    $expected = Get-NormalizedRemoteIdentity -Remote $ExpectedRemote
    if ([string]::IsNullOrWhiteSpace($expected)) { return $false }
    $remotes = Invoke-Git -WorkingDirectory $RepositoryRoot -Arguments @('remote') -AllowFailure
    if ($remotes.ExitCode -ne 0) { return $false }
    foreach ($remoteName in @($remotes.Output -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $urls = Invoke-Git -WorkingDirectory $RepositoryRoot -Arguments @('remote','get-url','--all',$remoteName.Trim()) -AllowFailure
        if ($urls.ExitCode -ne 0) { continue }
        foreach ($url in @($urls.Output -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            if ((Get-NormalizedRemoteIdentity -Remote $url.Trim()) -ceq $expected) { return $true }
        }
    }
    return $false
}

function Resolve-RegisteredLocalPath {
    param([string]$MemberRoot, [string]$ContextRoot, [object]$Entry, [string]$Repository)
    $configuredPath = if ($null -ne $Entry.path) { [string]$Entry.path } else { $null }
    if (-not [string]::IsNullOrWhiteSpace($configuredPath)) {
        if ([System.IO.Path]::IsPathRooted($configuredPath)) { return [System.IO.Path]::GetFullPath($configuredPath) }
        $fromContext = [System.IO.Path]::GetFullPath((Join-Path $ContextRoot $configuredPath))
        if (Test-Path -LiteralPath $fromContext) { return $fromContext }
        $leaf = Split-Path -Leaf $configuredPath
        if (-not [string]::IsNullOrWhiteSpace($leaf)) {
            return [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $MemberRoot) $leaf))
        }
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $MemberRoot) $Repository))
}

function Get-MembershipAudit {
    param([string]$MemberRoot, [string]$ContextRoot, [object]$Config)
    $registry = Get-RepositoryRegistry -ContextRoot $ContextRoot
    if ([string]$Config.project -cne [string]$registry.project) {
        throw "Member project '$($Config.project)' does not match central context project '$($registry.project)'."
    }

    $registeredResults = @()
    foreach ($repoId in @($registry.repositories.Keys | Sort-Object)) {
        $entry = $registry.repositories[$repoId]
        $localPath = Resolve-RegisteredLocalPath -MemberRoot $MemberRoot -ContextRoot $ContextRoot -Entry $entry -Repository $repoId
        $issues = @()
        $status = 'ok'
        if (-not (Test-Path -LiteralPath $localPath)) {
            $status = 'missing-local-path'; $issues += 'Registered repository local path is missing.'
        } elseif (-not (Test-Path -LiteralPath (Join-Path $localPath '.git'))) {
            $status = 'not-git-repository'; $issues += 'Registered local path is not a Git repository/worktree.'
        } else {
            $memberConfigPath = Join-Path $localPath '.ai/context/config.json'
            if (-not (Test-Path -LiteralPath $memberConfigPath -PathType Leaf)) {
                $status = 'missing-context-config'; $issues += 'Registered repository is missing .ai/context/config.json.'
            } else {
                try { $memberConfig = Get-Content -LiteralPath $memberConfigPath -Raw | ConvertFrom-Json } catch {
                    $status = 'invalid-context-config'; $issues += 'Member context config is invalid JSON.'; $memberConfig = $null
                }
                if ($null -ne $memberConfig) {
                    if ([string]$memberConfig.project -cne [string]$registry.project) { $issues += 'Member context project does not match central project.' }
                    if ([string]$memberConfig.repository -cne [string]$repoId) { $issues += 'Member context repository id does not match registry id.' }
                    if ($issues.Count -gt 0) { $status = 'mismatched-context-config' }
                }
            }
        }
        $registeredResults += [pscustomobject]@{
            repository = $repoId; role = [string]$entry.role; configuredPath = $entry.path
            localPath = $localPath; status = $status; issues = @($issues)
        }
    }

    $registeredNames = @{}
    foreach ($name in $registry.repositories.Keys) { $registeredNames[[string]$name] = $true }
    $contextRemote = [string]$Config.context.remote
    $contextRepoName = Get-ContextRemoteRepositoryName -Remote $contextRemote
    $workspaceRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $MemberRoot))
    $candidates = @()
    foreach ($candidate in @(Get-ChildItem -LiteralPath $workspaceRoot -Directory -Force | Sort-Object Name)) {
        if ($registeredNames.ContainsKey($candidate.Name) -or $candidate.Name -eq $contextRepoName) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $candidate.FullName '.git'))) { continue }
        if (Test-RepositoryRemoteMatch -RepositoryRoot $candidate.FullName -ExpectedRemote $contextRemote) { continue }
        $looksManaged = (Test-Path -LiteralPath (Join-Path $candidate.FullName 'AI_CONTEXT.md') -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $candidate.FullName '.ai/context')) -or $candidate.Name.StartsWith(([string]$registry.project + '-'))
        if (-not $looksManaged) { continue }
        $candidates += [pscustomobject]@{ repository = $candidate.Name; localPath = $candidate.FullName; reason = 'Sibling Git repository resembles a project member but is not registered.' }
    }

    $healthy = @($registeredResults | Where-Object { $_.status -eq 'ok' }).Count
    return [pscustomobject]@{
        schemaVersion = 1; project = [string]$registry.project; registryPath = [string]$registry.path
        workspaceRoot = $workspaceRoot; registered = @($registeredResults); unregisteredCandidates = @($candidates)
        summary = [pscustomobject]@{ registered = $registeredResults.Count; healthy = $healthy; issues = $registeredResults.Count - $healthy; candidates = $candidates.Count }
    }
}

function Read-OptionalText {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Get-Content -LiteralPath $Path -Raw)
    }
    return $null
}

function Write-RuntimeBundle {
    param(
        [string]$MemberRoot,
        [string]$ContextRoot,
        [object]$Config,
        [string]$ContextFreshness,
        [object]$Membership = $null
    )

    $memberState = Get-GitState -Root $MemberRoot
    $contextState = Get-GitState -Root $ContextRoot
    if ($null -eq $Membership) { $Membership = Get-MembershipInfo -ContextRoot $ContextRoot -Config $Config }
    $bridgeDir = Join-Path $MemberRoot '.ai-bridge'
    New-Item -ItemType Directory -Path $bridgeDir -Force | Out-Null

    $runtime = [ordered]@{
        schemaVersion = 1
        generatedAt = (Get-Date).ToString('o')
        project = [string]$Config.project
        repository = [string]$Config.repository
        member = [ordered]@{
            root = $MemberRoot
            branch = $memberState.branch
            head = $memberState.head
            dirty = $memberState.dirty
            upstream = $memberState.upstream
            ahead = $memberState.ahead
            behind = $memberState.behind
            fingerprint = $memberState.fingerprint
        }
        context = [ordered]@{
            root = $ContextRoot
            remote = [string]$Config.context.remote
            branch = $contextState.branch
            head = $contextState.head
            dirty = $contextState.dirty
            freshness = $ContextFreshness
        }
        membership = $Membership
    }

    $repoId = [string]$Config.repository
    $continuityRuntime = Get-ContinuityRuntime -ContextRoot $ContextRoot -Repository $repoId -MemberState $memberState
    $runtime['continuity'] = [ordered]@{
        mode = $continuityRuntime.mode
        workstreamId = $continuityRuntime.workstreamId
        workstreamStatus = $continuityRuntime.workstreamStatus
        currentItemId = $continuityRuntime.currentItemId
        workstreamPath = $continuityRuntime.workstreamPath
        validation = $continuityRuntime.validation
    }

    $runtimeJsonPath = Join-Path $bridgeDir 'context-runtime.json'
    $runtime | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runtimeJsonPath -Encoding UTF8

    $sections = New-Object System.Collections.Generic.List[string]
    $sections.Add('# Runtime AI Context')
    $sections.Add('')
    $sections.Add("Generated: $($runtime.generatedAt)")
    $sections.Add("Repository: $($runtime.repository)")
    $sections.Add("Repository HEAD: $($runtime.member.head)")
    $sections.Add("Repository branch: $($runtime.member.branch)")
    $sections.Add("Repository dirty: $($runtime.member.dirty)")
    $sections.Add("Context HEAD: $($runtime.context.head)")
    $sections.Add("Context freshness: $ContextFreshness")
    $sections.Add("Member registered: $($Membership.registered)")
    $sections.Add("Member role: $(if ($null -ne $Membership.role) { [string]$Membership.role } else { 'none' })")
    $sections.Add('')
    $sections.Add('> This bundle is generated runtime evidence. Canonical implementation sources still outrank AI context.')

    $inputs = @(
        @{ Title = 'Central Entry Point'; Path = 'AI_CONTEXT.md' },
        @{ Title = 'Authority'; Path = 'project/authority.md' },
        @{ Title = 'Current Project State'; Path = 'state/current.md' },
        @{ Title = 'Next Action'; Path = 'state/next-action.md' },
        @{ Title = 'Open Questions'; Path = 'state/open-questions.md' },
        @{ Title = 'Pending Decisions'; Path = 'state/pending-decisions.md' },
        @{ Title = 'Repository Map'; Path = 'repositories/repositories.yaml' }
    )

    foreach ($item in $inputs) {
        $text = Read-OptionalText -Path (Join-Path $ContextRoot $item.Path)
        if ($null -ne $text) {
            $sections.Add('')
            $sections.Add("## $($item.Title)")
            $sections.Add('')
            $sections.Add("Source: ``$($item.Path)``")
            $sections.Add('')
            $sections.Add($text.TrimEnd())
        }
    }

    $repoId = [string]$Config.repository
    $repoScoped = @(
        @{ Title = 'Latest Repository State'; Path = "state/repositories/$repoId.md" },
        @{ Title = 'Latest Repository Handoff'; Path = "handoffs/repositories/$repoId.md" },
        @{ Title = 'Repository Provenance'; Path = "manifests/repositories/$repoId.json" }
    )
    foreach ($item in $repoScoped) {
        $text = Read-OptionalText -Path (Join-Path $ContextRoot $item.Path)
        if ($null -ne $text) {
            $sections.Add('')
            $sections.Add("## $($item.Title)")
            $sections.Add('')
            $sections.Add("Source: ``$($item.Path)``")
            $sections.Add('')
            $sections.Add($text.TrimEnd())
        }
    }

    if ($null -ne $continuityRuntime.workstream) {
        $sections.Add('')
        $sections.Add('## Active Workstream')
        $sections.Add('')
        $sections.Add("Source: ``$($continuityRuntime.workstreamPath)``")
        $sections.Add('')
        $sections.Add((Convert-ContinuityWorkstreamToMarkdown -Workstream $continuityRuntime.workstream).TrimEnd())
    }
    $sections.Add('')
    $sections.Add('## Validation Freshness')
    $sections.Add('')
    $sections.Add("Source: ``$($continuityRuntime.validation.path)``")
    $sections.Add('')
    $sections.Add("Entries: $($continuityRuntime.validation.entries)")
    $sections.Add("Fresh for current worktree: $($continuityRuntime.validation.freshEntries)")
    $sections.Add("Stale for current worktree: $($continuityRuntime.validation.staleEntries)")
    if ($null -ne $continuityRuntime.validation.mostRecent) {
        $sections.Add("Latest validation: ``$($continuityRuntime.validation.mostRecent.id)`` / ``$($continuityRuntime.validation.mostRecent.result)`` - $($continuityRuntime.validation.mostRecent.summary)")
    }

    $runtimeMarkdownPath = Join-Path $bridgeDir 'context-runtime.md'
    ($sections -join "`r`n") + "`r`n" | Set-Content -LiteralPath $runtimeMarkdownPath -Encoding UTF8

    return $runtime
}

function Assert-CheckpointShape {
    param([object]$Checkpoint, [string]$ExpectedRepository)

    $requiredScalar = @('schemaVersion', 'repository', 'scope', 'status', 'objective', 'nextAction')
    foreach ($field in $requiredScalar) {
        if (-not ($Checkpoint.PSObject.Properties.Name -contains $field)) {
            throw "Checkpoint is missing required field: $field"
        }
        if ($field -ne 'schemaVersion' -and [string]::IsNullOrWhiteSpace([string]$Checkpoint.$field)) {
            throw "Checkpoint field must not be empty: $field"
        }
    }
    if (@(1, 2) -notcontains [int]$Checkpoint.schemaVersion) {
        throw 'Unsupported checkpoint schemaVersion.'
    }
    if ([string]$Checkpoint.repository -ne $ExpectedRepository) {
        throw 'Checkpoint repository does not match the active repository config.'
    }

    $allowedStatuses = @('PROPOSED', 'IN_PROGRESS', 'IMPLEMENTED', 'VALIDATED', 'APPROVED', 'MERGED', 'DEPLOYED', 'SUPERSEDED', 'STALE', 'BLOCKED', 'UNKNOWN')
    if ($allowedStatuses -notcontains [string]$Checkpoint.status) {
        throw 'Checkpoint status is not allowed.'
    }

    foreach ($field in @('confirmedFindings', 'decisions', 'rejectedApproaches', 'validation', 'openQuestions')) {
        if (-not ($Checkpoint.PSObject.Properties.Name -contains $field)) {
            throw "Checkpoint is missing required array: $field"
        }
        if ($null -eq $Checkpoint.$field -or $Checkpoint.$field -is [string]) {
            throw "Checkpoint field must be an array: $field"
        }
    }
    Assert-ContinuityCheckpointShape -Checkpoint $Checkpoint -ExpectedRepository $ExpectedRepository
}

function Assert-NoSecrets {
    param([object]$Value)

    $forbiddenKey = '(?i)(password|passwd|secret|token|private.?key|cookie|authorization|dsn|api.?key|client.?secret)'
    $forbiddenValue = '(?i)(-----BEGIN [A-Z ]*PRIVATE KEY-----|\bBearer\s+[A-Za-z0-9._\-+/=]{8,}|glpat-[A-Za-z0-9_\-]{8,}|gh[pousr]_[A-Za-z0-9]{16,}|sk-[A-Za-z0-9]{16,})'

    function Visit-Value {
        param([object]$Node, [string]$Path)
        if ($null -eq $Node) { return }

        if ($Node -is [string]) {
            if ($Node -match $forbiddenValue) {
                throw "Checkpoint contains secret-like material at $Path."
            }
            return
        }

        # ConvertFrom-Json on PowerShell 7 can materialize ISO timestamps as DateTime.
        # JSON scalar value types cannot contain nested credential fields and must be
        # treated as leaves to avoid recursively walking self-referential properties
        # such as DateTime.Date.Date...
        if ($Node -is [System.ValueType]) { return }

        if ($Node -is [System.Collections.IDictionary]) {
            foreach ($key in $Node.Keys) {
                if ([string]$key -match $forbiddenKey) {
                    throw "Checkpoint contains a forbidden credential-like field at $Path."
                }
                Visit-Value -Node $Node[$key] -Path "$Path.$key"
            }
            return
        }

        if ($Node -is [System.Collections.IEnumerable] -and -not ($Node -is [string])) {
            $index = 0
            foreach ($item in $Node) {
                Visit-Value -Node $item -Path "$Path[$index]"
                $index++
            }
            return
        }

        foreach ($property in $Node.PSObject.Properties) {
            if ($property.Name -match $forbiddenKey) {
                throw "Checkpoint contains a forbidden credential-like field at $Path."
            }
            Visit-Value -Node $property.Value -Path "$Path.$($property.Name)"
        }
    }

    Visit-Value -Node $Value -Path '$'
}

function Convert-ToBullets {
    param([object[]]$Items)
    if ($null -eq $Items -or $Items.Count -eq 0) { return '- None.' }
    return (($Items | ForEach-Object { '- ' + ([string]$_).Trim() }) -join "`r`n")
}

function New-CheckpointMarkdown {
    param([object]$Checkpoint, [object]$MemberState, [string]$GeneratedAt)

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(
        '---',
        "date: $GeneratedAt",
        "status: $($Checkpoint.status)",
        "repository: $($Checkpoint.repository)",
        "branch: $($MemberState.branch)",
        "commit: $($MemberState.head)",
        "dirty: $($MemberState.dirty.ToString().ToLowerInvariant())",
        "worktreeFingerprint: $($MemberState.fingerprint)",
        '---', '', '# Objective', '', [string]$Checkpoint.objective, '',
        '# Confirmed Findings', '', (Convert-ToBullets -Items @($Checkpoint.confirmedFindings)), '',
        '# Decisions', '', (Convert-ToBullets -Items @($Checkpoint.decisions)), '',
        '# Rejected Approaches', '', (Convert-ToBullets -Items @($Checkpoint.rejectedApproaches)), '',
        '# Validation', '', (Convert-ToBullets -Items @($Checkpoint.validation)), '',
        '# Open Questions', '', (Convert-ToBullets -Items @($Checkpoint.openQuestions)), ''
    )) { $lines.Add($line) }

    if ([int]$Checkpoint.schemaVersion -eq 2) {
        $lines.Add('# Continuity')
        $lines.Add('')
        $lines.Add("Mode: ``$($Checkpoint.continuity.mode)``")
        $lines.Add('')
        if ($null -ne $Checkpoint.continuity.workstream) {
            $lines.Add((Convert-ContinuityWorkstreamToMarkdown -Workstream $Checkpoint.continuity.workstream).TrimEnd())
            $lines.Add('')
        }
        if (@($Checkpoint.continuity.validationLedger).Count -gt 0) {
            $lines.Add('Validation ledger entries added by this checkpoint:')
            $lines.Add('')
            foreach ($entry in @($Checkpoint.continuity.validationLedger)) {
                $lines.Add("- ``$($entry.id)`` ``$($entry.result)`` - $($entry.summary)")
            }
            $lines.Add('')
        }
    }
    $lines.Add('# Next Action')
    $lines.Add('')
    $lines.Add([string]$Checkpoint.nextAction)
    return ($lines -join "`r`n")
}

function Get-SafeSlug {
    param([string]$Value)
    $slug = $Value.Trim().ToLowerInvariant() -replace '[^a-z0-9._-]+', '-'
    $slug = $slug.Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) { return 'checkpoint' }
    if ($slug.Length -gt 64) { return $slug.Substring(0, 64).Trim('-') }
    return $slug
}

function Test-GitAncestor {
    param([string]$ContextRoot, [string]$Ancestor, [string]$Descendant)
    $result = Invoke-Git -WorkingDirectory $ContextRoot -Arguments @('merge-base', '--is-ancestor', $Ancestor, $Descendant) -AllowFailure
    return $result.ExitCode -eq 0
}

function Sync-CheckpointPush {
    param([string]$ContextRoot, [string]$ExpectedBranch, [string]$Remote)
    $push = Invoke-GitNetwork -WorkingDirectory $ContextRoot -Arguments @('push', 'origin', "HEAD:$ExpectedBranch") -Remote $Remote -AllowFailure
    if ($push.ExitCode -eq 0) { return }

    Invoke-GitNetwork -WorkingDirectory $ContextRoot -Arguments @('fetch', 'origin', $ExpectedBranch) -Remote $Remote | Out-Null
    $remoteRef = "origin/$ExpectedBranch"
    $remoteIsAncestor = Test-GitAncestor -ContextRoot $ContextRoot -Ancestor $remoteRef -Descendant 'HEAD'
    $localIsAncestor = Test-GitAncestor -ContextRoot $ContextRoot -Ancestor 'HEAD' -Descendant $remoteRef

    if ($remoteIsAncestor -and -not $localIsAncestor) {
        $retry = Invoke-GitNetwork -WorkingDirectory $ContextRoot -Arguments @('push', 'origin', "HEAD:$ExpectedBranch") -Remote $Remote -AllowFailure
        if ($retry.ExitCode -ne 0) { throw 'Context push remained unconfirmed even though remote history is an ancestor of the local checkpoint.' }
        return
    }
    if ($localIsAncestor) {
        Invoke-Git -WorkingDirectory $ContextRoot -Arguments @('merge', '--ff-only', $remoteRef) | Out-Null
        return
    }
    throw 'Context push was rejected because local and remote context histories diverged. Automatic merge, rebase, reset, and force-push are forbidden; both histories were preserved.'
}

$configFullPath = [System.IO.Path]::GetFullPath($ConfigPath)
$memberRootFullPath = [System.IO.Path]::GetFullPath($RepositoryRoot)
if (-not (Test-Path -LiteralPath $configFullPath -PathType Leaf)) {
    throw "Context config not found: $configFullPath"
}
$config = Get-Content -LiteralPath $configFullPath -Raw | ConvertFrom-Json
if ([int]$config.schemaVersion -ne 1) { throw 'Unsupported context config schemaVersion.' }
$contextRemote = [string]$config.context.remote

$contextRoot = Resolve-RepoPath -Root $memberRootFullPath -PathValue ([string]$config.context.cachePath)
if (-not (Test-Path -LiteralPath (Join-Path $contextRoot '.git'))) {
    throw 'Central context cache is not a Git repository. Run the member context launcher first.'
}
Assert-RequiredContextFiles -ContextRoot $contextRoot

$contextState = Get-GitState -Root $contextRoot
$expectedBranch = [string]$config.context.branch
if ($contextState.branch -ne $expectedBranch) {
    throw "Central context cache must be on branch '$expectedBranch'."
}

$freshness = if ($contextState.dirty) {
    'DIRTY_LOCAL_CONTEXT'
} elseif ($Offline) {
    'OFFLINE_IMPORTED_CONTEXT'
} elseif ($null -ne $contextState.ahead -and $null -ne $contextState.behind -and $contextState.ahead -gt 0 -and $contextState.behind -gt 0) {
    'DIVERGED_LOCAL_CONTEXT'
} elseif ($null -ne $contextState.behind -and $contextState.behind -gt 0) {
    'STALE_LOCAL_CONTEXT'
} else {
    'CURRENT_OR_FETCHED'
}

if ($Action -eq 'audit') {
    $audit = Get-MembershipAudit -MemberRoot $memberRootFullPath -ContextRoot $contextRoot -Config $config
    $audit | ConvertTo-Json -Depth 10
    exit 0
}

if ($Action -eq 'status') {
    $membership = Get-MembershipInfo -ContextRoot $contextRoot -Config $config
    $runtime = Write-RuntimeBundle -MemberRoot $memberRootFullPath -ContextRoot $contextRoot -Config $config -ContextFreshness $freshness -Membership $membership
    $runtime | ConvertTo-Json -Depth 10
    if (-not $membership.projectMatches -or -not $membership.registered) { exit 12 }
    exit 0
}

if ($Action -eq 'start') {
    $membership = Assert-RegisteredMember -ContextRoot $contextRoot -Config $config
    $runtime = Write-RuntimeBundle -MemberRoot $memberRootFullPath -ContextRoot $contextRoot -Config $config -ContextFreshness $freshness -Membership $membership
    Write-Output "AI context ready: $($runtime.repository) @ $($runtime.context.head) [$freshness]"
    exit 0
}

if ($Action -eq 'checkpoint') {
    if ($contextState.dirty) {
        throw 'Automated checkpoint refused because the central context cache has pre-existing uncommitted changes.'
    }
    Assert-RegisteredMember -ContextRoot $contextRoot -Config $config | Out-Null
    $checkpointFreshness = if ($Offline) { 'OFFLINE_IMPORTED_CONTEXT' } else { 'CURRENT_OR_FETCHED' }

    $checkpointPath = Join-Path $memberRootFullPath '.ai-bridge/context-checkpoint.json'
    if (-not (Test-Path -LiteralPath $checkpointPath -PathType Leaf)) {
        throw 'No context checkpoint file exists at .ai-bridge/context-checkpoint.json.'
    }

    $checkpoint = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
    Assert-CheckpointShape -Checkpoint $checkpoint -ExpectedRepository ([string]$config.repository)
    Assert-NoSecrets -Value $checkpoint
    Assert-ContinuityTransition -ContextRoot $contextRoot -Checkpoint $checkpoint -Repository ([string]$config.repository)

    $memberState = Get-GitState -Root $memberRootFullPath
    $now = Get-Date
    $generatedAt = $now.ToString('o')
    $year = $now.ToString('yyyy')
    $month = $now.ToString('MM')
    $stamp = $now.ToString('yyyy-MM-dd-HHmmss')
    $repoId = [string]$config.repository
    $scopeSlug = Get-SafeSlug -Value ([string]$checkpoint.scope)
    $repoSlug = Get-SafeSlug -Value $repoId

    $sessionRelative = "sessions/$year/$month/$stamp-$repoSlug-$scopeSlug.md"
    $stateRelative = "state/repositories/$repoId.md"
    $handoffRelative = "handoffs/repositories/$repoId.md"
    $manifestRelative = "manifests/repositories/$repoId.json"
    $continuityResult = Write-ContinuityState -ContextRoot $contextRoot -Checkpoint $checkpoint -MemberState $memberState -GeneratedAt $generatedAt -SessionRelative $sessionRelative

    foreach ($relative in @($sessionRelative, $stateRelative, $handoffRelative, $manifestRelative)) {
        $parent = Split-Path -Parent (Join-Path $contextRoot $relative)
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $sessionText = New-CheckpointMarkdown -Checkpoint $checkpoint -MemberState $memberState -GeneratedAt $generatedAt
    Set-Content -LiteralPath (Join-Path $contextRoot $sessionRelative) -Value $sessionText -Encoding UTF8

    $continuityLines = @()
    if ($null -ne $continuityResult.Metadata) {
        $continuityLines = @(
            '## Continuity',
            '',
            ('Mode: `' + [string]$continuityResult.Metadata.mode + '`'),
            ('Workstream: `' + $(if ($null -ne $continuityResult.Metadata.workstreamId) { [string]$continuityResult.Metadata.workstreamId } else { 'none' }) + '`'),
            ('Workstream status: `' + $(if ($null -ne $continuityResult.Metadata.workstreamStatus) { [string]$continuityResult.Metadata.workstreamStatus } else { 'none' }) + '`'),
            ('Current item: `' + $(if ($null -ne $continuityResult.Metadata.currentItemId) { [string]$continuityResult.Metadata.currentItemId } else { 'none' }) + '`'),
            ('Workstream record: `' + $(if ($null -ne $continuityResult.Metadata.workstreamPath) { [string]$continuityResult.Metadata.workstreamPath } else { 'none' }) + '`'),
            ('Validation ledger: `' + [string]$continuityResult.Metadata.validationLedgerPath + '`'),
            ''
        )
    }

    $stateLines = @(
        "# Repository State - $repoId",
        '',
        "Updated: $generatedAt",
        ('Status: `' + [string]$checkpoint.status + '`'),
        ('Branch: `' + [string]$memberState.branch + '`'),
        ('Commit: `' + [string]$memberState.head + '`'),
        ('Dirty: `' + [string]$memberState.dirty + '`'),
        ('Worktree fingerprint: `' + [string]$memberState.fingerprint + '`'),
        '',
        '## Objective',
        '',
        [string]$checkpoint.objective,
        '',
        '## Confirmed Findings',
        '',
        (Convert-ToBullets -Items @($checkpoint.confirmedFindings)),
        ''
    )
    $stateLines += $continuityLines
    $stateLines += @(
        '## Open Questions',
        '',
        (Convert-ToBullets -Items @($checkpoint.openQuestions)),
        '',
        '## Next Action',
        '',
        [string]$checkpoint.nextAction,
        '',
        ('Latest session: `' + $sessionRelative + '`')
    )
    $stateText = $stateLines -join "`r`n"
    Set-Content -LiteralPath (Join-Path $contextRoot $stateRelative) -Value $stateText -Encoding UTF8

    $handoffLines = @(
        "# Repository Handoff - $repoId",
        '',
        "Updated: $generatedAt",
        ('Status: `' + [string]$checkpoint.status + '`'),
        '',
        '## Validation',
        '',
        (Convert-ToBullets -Items @($checkpoint.validation)),
        '',
        '## Decisions',
        '',
        (Convert-ToBullets -Items @($checkpoint.decisions)),
        '',
        '## Rejected Approaches',
        '',
        (Convert-ToBullets -Items @($checkpoint.rejectedApproaches)),
        ''
    )
    $handoffLines += $continuityLines
    $handoffLines += @(
        '## Next Action',
        '',
        [string]$checkpoint.nextAction,
        '',
        ('Session: `' + $sessionRelative + '`')
    )
    $handoffText = $handoffLines -join "`r`n"
    Set-Content -LiteralPath (Join-Path $contextRoot $handoffRelative) -Value $handoffText -Encoding UTF8

    $manifest = [ordered]@{
        schemaVersion = 1
        generatedAt = $generatedAt
        repository = $repoId
        branch = $memberState.branch
        commit = $memberState.head
        dirty = $memberState.dirty
        worktreeFingerprint = $memberState.fingerprint
        upstream = $memberState.upstream
        ahead = $memberState.ahead
        behind = $memberState.behind
        status = [string]$checkpoint.status
        scope = [string]$checkpoint.scope
        session = $sessionRelative
    }
    if ($null -ne $continuityResult.Metadata) {
        $manifest['continuity'] = $continuityResult.Metadata
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $contextRoot $manifestRelative) -Encoding UTF8

    $pathsToCommit = @($sessionRelative, $stateRelative, $handoffRelative, $manifestRelative) + @($continuityResult.Paths)
    $pathsToCommit = @($pathsToCommit | Select-Object -Unique)
    Invoke-Git -WorkingDirectory $contextRoot -Arguments (@('add', '--') + $pathsToCommit) | Out-Null
    Invoke-Git -WorkingDirectory $contextRoot -Arguments @('diff', '--cached', '--check') | Out-Null

    $staged = (Invoke-Git -WorkingDirectory $contextRoot -Arguments @('diff', '--cached', '--name-only')).Output
    if ([string]::IsNullOrWhiteSpace($staged)) {
        Remove-Item -LiteralPath $checkpointPath -Force
        Write-RuntimeBundle -MemberRoot $memberRootFullPath -ContextRoot $contextRoot -Config $config -ContextFreshness $checkpointFreshness | Out-Null
        Write-Output 'AI context checkpoint produced no changes.'
        exit 0
    }

    $message = "chore(context): checkpoint $repoId $scopeSlug"
    Invoke-Git -WorkingDirectory $contextRoot -Arguments (@('commit', '-m', $message, '--') + $pathsToCommit) | Out-Null

    if (-not $Offline -and [bool]$config.behavior.pushContext) {
        Sync-CheckpointPush -ContextRoot $contextRoot -ExpectedBranch $expectedBranch -Remote $contextRemote
    }

    Remove-Item -LiteralPath $checkpointPath -Force
    $runtime = Write-RuntimeBundle -MemberRoot $memberRootFullPath -ContextRoot $contextRoot -Config $config -ContextFreshness $checkpointFreshness
    Write-Output "AI context checkpoint committed: $($runtime.context.head)"
}
