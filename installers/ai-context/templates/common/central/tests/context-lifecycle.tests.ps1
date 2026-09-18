Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$templateLauncher = Join-Path $repoRoot 'templates/member/context.ps1'
$templateTransferHelper = Join-Path $repoRoot 'templates/member/context-transfer.ps1'
$centralTool = Join-Path $repoRoot 'tooling/context-lifecycle.ps1'
$centralContinuityTool = Join-Path $repoRoot 'tooling/context-continuity.ps1'
$powerShellHost = (Get-Process -Id $PID).Path

function Invoke-Git {
    param([string]$Root, [string[]]$Arguments)
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -C $Root @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($code -ne 0) {
        throw "git failed in ${Root}: git $($Arguments -join ' ')`n$($output -join "`n")"
    }
    return ($output -join "`n").Trim()
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-Fails {
    param([scriptblock]$Script, [string]$Contains)
    $message = $null
    try {
        & $Script
    } catch {
        $message = $_.Exception.Message
    }
    if ($null -eq $message) { throw 'ASSERTION FAILED: expected command to fail.' }
    if (-not [string]::IsNullOrWhiteSpace($Contains) -and $message -notlike "*$Contains*") {
        throw "ASSERTION FAILED: failure did not contain expected text '$Contains'. Actual: $message"
    }
    return $message
}

function Initialize-GitIdentity {
    param([string]$Root)
    Invoke-Git -Root $Root -Arguments @('config', 'user.name', 'AI Context Test') | Out-Null
    Invoke-Git -Root $Root -Arguments @('config', 'user.email', 'ai-context-test@example.invalid') | Out-Null
}

function New-TestEnvironment {
    param([string]$Name)

    $base = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-context-test-$Name-" + [guid]::NewGuid().ToString('N'))
    $contextBare = Join-Path $base 'context.git'
    $contextSeed = Join-Path $base 'context-seed'
    $memberBare = Join-Path $base 'member.git'
    $memberSeed = Join-Path $base 'member-seed'
    $memberClone = Join-Path $base 'member-clone'

    New-Item -ItemType Directory -Path $base -Force | Out-Null
    & git init --bare --initial-branch=main $contextBare | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize context bare repo.' }

    & git init --initial-branch=main $contextSeed | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize context seed repo.' }
    Initialize-GitIdentity -Root $contextSeed

    $requiredFiles = @{
        'AI_CONTEXT.md' = "# Test Central Context`n"
        'project/authority.md' = "# Authority`nSource outranks context.`n"
        'state/current.md' = "# Current`nTest state.`n"
        'state/next-action.md' = "# Next`nContinue.`n"
        'state/open-questions.md' = "# Open Questions`nNone.`n"
        'state/pending-decisions.md' = "# Pending Decisions`nNone.`n"
        'repositories/repositories.yaml' = "project: test-project`nexcluded_directories:`n  - Docs`n  - worktrees`nrepositories:`n  test-member:`n    path: ../member-clone`n    role: implementation-owner`n    authority:`n      - implementation`n      - tests`n    publish: true`n    notes: Project-owned metadata remains outside membership semantics.`n"
    }
    foreach ($entry in $requiredFiles.GetEnumerator()) {
        $target = Join-Path $contextSeed $entry.Key
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Set-Content -LiteralPath $target -Value $entry.Value -Encoding UTF8
    }
    New-Item -ItemType Directory -Path (Join-Path $contextSeed 'tooling') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $contextSeed 'tests') -Force | Out-Null
    Copy-Item -LiteralPath $centralTool -Destination (Join-Path $contextSeed 'tooling/context-lifecycle.ps1')
    Copy-Item -LiteralPath $centralContinuityTool -Destination (Join-Path $contextSeed 'tooling/context-continuity.ps1')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'context-lifecycle.tests.ps1') -Destination (Join-Path $contextSeed 'tests/context-lifecycle.tests.ps1')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'context-lifecycle.tests.sh') -Destination (Join-Path $contextSeed 'tests/context-lifecycle.tests.sh')
    Invoke-Git -Root $contextSeed -Arguments @('add', '--all') | Out-Null
    Invoke-Git -Root $contextSeed -Arguments @('commit', '-m', 'seed context') | Out-Null
    Invoke-Git -Root $contextSeed -Arguments @('remote', 'add', 'origin', $contextBare) | Out-Null
    Invoke-Git -Root $contextSeed -Arguments @('push', '-u', 'origin', 'main') | Out-Null

    & git init --bare --initial-branch=main $memberBare | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize member bare repo.' }
    & git init --initial-branch=main $memberSeed | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize member seed repo.' }
    Initialize-GitIdentity -Root $memberSeed

    $contextDir = Join-Path $memberSeed '.ai/context'
    New-Item -ItemType Directory -Path $contextDir -Force | Out-Null
    Copy-Item -LiteralPath $templateLauncher -Destination (Join-Path $contextDir 'context.ps1')
    Copy-Item -LiteralPath $templateTransferHelper -Destination (Join-Path $contextDir 'context-transfer.ps1')
    @{
        schemaVersion = 1
        project = 'test-project'
        repository = 'test-member'
        context = @{
            remote = $contextBare
            branch = 'main'
            cachePath = '.ai/context/cache/project-context'
        }
        behavior = @{
            ensureOnStart = $true
            refreshOnStart = $true
            loadOnStart = $true
            checkpointAfterValidation = $true
            checkpointBeforeHandoff = $true
            commitContext = $true
            pushContext = $true
        }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $contextDir 'config.json') -Encoding UTF8
    "cache/`nruntime/`n" | Set-Content -LiteralPath (Join-Path $contextDir '.gitignore') -Encoding UTF8
    New-Item -ItemType Directory -Path (Join-Path $memberSeed '.ai-bridge') -Force | Out-Null
    "*`n!.gitignore`n!README.md`n" | Set-Content -LiteralPath (Join-Path $memberSeed '.ai-bridge/.gitignore') -Encoding UTF8
    "# AI Bridge`n" | Set-Content -LiteralPath (Join-Path $memberSeed '.ai-bridge/README.md') -Encoding UTF8
    "# Member`n" | Set-Content -LiteralPath (Join-Path $memberSeed 'README.md') -Encoding UTF8
    Invoke-Git -Root $memberSeed -Arguments @('add', '--all') | Out-Null
    Invoke-Git -Root $memberSeed -Arguments @('commit', '-m', 'seed member automation') | Out-Null
    Invoke-Git -Root $memberSeed -Arguments @('remote', 'add', 'origin', $memberBare) | Out-Null
    Invoke-Git -Root $memberSeed -Arguments @('push', '-u', 'origin', 'main') | Out-Null

    & git clone $memberBare $memberClone | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to clone member test repo.' }
    Initialize-GitIdentity -Root $memberClone

    return [pscustomobject]@{
        Base = $base
        ContextBare = $contextBare
        ContextSeed = $contextSeed
        MemberBare = $memberBare
        MemberSeed = $memberSeed
        MemberClone = $memberClone
        Launcher = (Join-Path $memberClone '.ai/context/context.ps1')
        Cache = (Join-Path $memberClone '.ai/context/cache/project-context')
        Checkpoint = (Join-Path $memberClone '.ai-bridge/context-checkpoint.json')
    }
}

function Invoke-Launcher {
    param([object]$Env, [string]$Action)
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $powerShellHost -NoProfile -ExecutionPolicy Bypass -File $Env.Launcher $Action 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($code -ne 0) { throw "Launcher action failed: $Action`n$($output -join "`n")" }
    if ($output.Count -gt 0) { $output | ForEach-Object { Write-Host ([string]$_) } }
}

function Invoke-LauncherAllowFailure {
    param([object]$Env, [string]$Action)
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $powerShellHost -NoProfile -ExecutionPolicy Bypass -File $Env.Launcher $Action 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return [pscustomobject]@{ ExitCode = $code; Output = ($output -join "`n") }
}

function Write-ValidCheckpoint {
    param([object]$Env, [string]$Status = 'VALIDATED', [string]$Objective = 'Validate context lifecycle')
    @{
        schemaVersion = 1
        repository = 'test-member'
        scope = 'context-lifecycle'
        status = $Status
        objective = $Objective
        confirmedFindings = @('Context was loaded automatically.')
        decisions = @('Keep central context non-authoritative.')
        rejectedApproaches = @()
        validation = @('Local integration test passed.')
        openQuestions = @()
        nextAction = 'Continue with the next task.'
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Env.Checkpoint -Encoding UTF8
}

function Write-TrackedCheckpoint {
    param([object]$Env, [string]$ValidationId = 'VAL-1')
    [ordered]@{
        schemaVersion = 2
        repository = 'test-member'
        scope = 'continuity-v2'
        status = 'IN_PROGRESS'
        objective = 'Preserve the exact active workstream across sessions.'
        confirmedFindings = @('Structured workstream state is available.')
        decisions = @('Never drop unresolved work items implicitly.')
        rejectedApproaches = @('Free-form nextAction as the only continuity state.')
        validation = @('Continuity fixture prepared.')
        openQuestions = @()
        nextAction = 'Finish WS-1.'
        continuity = [ordered]@{
            mode = 'tracked'
            workstream = [ordered]@{
                id = 'landing-polish'
                title = 'Landing polish backlog'
                status = 'IN_PROGRESS'
                objective = 'Finish the durable landing backlog without losing pending work.'
                repositories = @(
                    [ordered]@{ repository = 'test-member'; role = 'implementation-owner' },
                    [ordered]@{ repository = 'test-contracts'; role = 'contract-reference' }
                )
                cursor = [ordered]@{
                    currentItemId = 'WS-1'
                    lastCompletedItemId = $null
                    phase = 'implementation'
                    lastCompletedAction = $null
                    nextAction = 'Finish WS-1.'
                }
                items = @(
                    [ordered]@{
                        id = 'WS-1'; title = 'Implement structured backlog'; status = 'IN_PROGRESS'; priority = 'HIGH'
                        scope = @('tooling/context-lifecycle')
                        acceptanceCriteria = @('Workstream survives checkpoint and start.')
                        dependsOn = @(); blockedBy = @(); validationRequirements = @('lifecycle-e2e'); notes = @()
                    },
                    [ordered]@{
                        id = 'WS-2'; title = 'Validate offline resume'; status = 'PENDING'; priority = 'HIGH'
                        scope = @('tests/context-lifecycle')
                        acceptanceCriteria = @('Fresh session can identify the exact next item.')
                        dependsOn = @('WS-1'); blockedBy = @(); validationRequirements = @('offline-resume-e2e'); notes = @()
                    }
                )
            }
            validationLedger = @(
                [ordered]@{
                    id = $ValidationId
                    kind = 'integration'
                    result = 'PASS'
                    repository = 'test-member'
                    scope = 'continuity-v2'
                    summary = 'Initial tracked continuity fixture passed.'
                    timestamp = '2026-08-25T20:00:00+03:30'
                    command = 'context checkpoint fixture'
                    evidenceRefs = @()
                }
            )
        }
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Env.Checkpoint -Encoding UTF8
}

$tests = @()
$tests += @{ Name = 'fresh clone start auto-clones context and generates runtime bundle'; Run = {
    $env = New-TestEnvironment -Name 'fresh-start'
    try {
        Assert-True -Condition (-not (Test-Path -LiteralPath $env.Cache)) -Message 'Context cache should not exist before start.'
        Invoke-Launcher -Env $env -Action 'start'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $env.Cache '.git')) -Message 'Context cache should be cloned inside member repo.'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $env.MemberClone '.ai-bridge/context-runtime.md')) -Message 'Runtime Markdown bundle should exist.'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $env.MemberClone '.ai-bridge/context-runtime.json')) -Message 'Runtime JSON should exist.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'relative sibling context source resolves portably'; Run = {
    $env = New-TestEnvironment -Name 'relative-source'
    try {
        $configPath = Join-Path $env.MemberClone '.ai/context/config.json'
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $config.context.remote = '../context.git'
        $config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding UTF8
        Invoke-Launcher -Env $env -Action 'start'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $env.Cache '.git')) -Message 'Relative context source should clone into the member cache.'
        $actualRemote = Invoke-Git -Root $env.Cache -Arguments @('remote', 'get-url', 'origin')
        Assert-True -Condition ([System.IO.Path]::GetFullPath($actualRemote).TrimEnd([char[]]@('\','/')) -eq [System.IO.Path]::GetFullPath($env.ContextBare).TrimEnd([char[]]@('\','/'))) -Message 'Relative context source should resolve to the expected sibling repository.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'clean cache origin migrates to a newly configured remote'; Run = {
    $env = New-TestEnvironment -Name 'remote-migration'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        $replacementBare = Join-Path $env.Base 'replacement-context.git'
        & git clone --bare $env.ContextBare $replacementBare | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to create replacement context remote.' }

        $configPath = Join-Path $env.MemberClone '.ai/context/config.json'
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $config.context.remote = $replacementBare
        $config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding UTF8

        Invoke-Launcher -Env $env -Action 'start'
        $actualRemote = Invoke-Git -Root $env.Cache -Arguments @('remote', 'get-url', 'origin')
        Assert-True -Condition ([System.IO.Path]::GetFullPath($actualRemote).TrimEnd([char[]]@(92,47)) -eq [System.IO.Path]::GetFullPath($replacementBare).TrimEnd([char[]]@(92,47))) -Message 'Clean context cache should migrate origin to the newly configured remote.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'dirty cache refuses automatic origin migration'; Run = {
    $env = New-TestEnvironment -Name 'dirty-remote-migration'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        $replacementBare = Join-Path $env.Base 'replacement-context.git'
        & git clone --bare $env.ContextBare $replacementBare | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to create replacement context remote.' }

        Set-Content -LiteralPath (Join-Path $env.Cache 'local-dirty-marker.txt') -Value 'preserve me' -Encoding UTF8
        $configPath = Join-Path $env.MemberClone '.ai/context/config.json'
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $config.context.remote = $replacementBare
        $config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding UTF8

        $result = Invoke-LauncherAllowFailure -Env $env -Action 'start'
        Assert-True -Condition ($result.ExitCode -ne 0) -Message 'Dirty context cache must refuse automatic origin migration.'
        Assert-True -Condition ($result.Output -like '*automatic origin migration was refused*') -Message 'Dirty origin migration failure should be explicit.'
        $actualRemote = Invoke-Git -Root $env.Cache -Arguments @('remote', 'get-url', 'origin')
        Assert-True -Condition ([System.IO.Path]::GetFullPath($actualRemote).TrimEnd([char[]]@(92,47)) -eq [System.IO.Path]::GetFullPath($env.ContextBare).TrimEnd([char[]]@(92,47))) -Message 'Dirty migration refusal must preserve the previous origin.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'start fast-forwards a clean stale context cache'; Run = {
    $env = New-TestEnvironment -Name 'fast-forward'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        $before = Invoke-Git -Root $env.Cache -Arguments @('rev-parse', 'HEAD')
        Set-Content -LiteralPath (Join-Path $env.ContextSeed 'state/current.md') -Value "# Current`nUpdated remote state.`n" -Encoding UTF8
        Invoke-Git -Root $env.ContextSeed -Arguments @('add', 'state/current.md') | Out-Null
        Invoke-Git -Root $env.ContextSeed -Arguments @('commit', '-m', 'advance context') | Out-Null
        Invoke-Git -Root $env.ContextSeed -Arguments @('push', 'origin', 'main') | Out-Null
        Invoke-Launcher -Env $env -Action 'start'
        $after = Invoke-Git -Root $env.Cache -Arguments @('rev-parse', 'HEAD')
        Assert-True -Condition ($before -ne $after) -Message 'Clean cache should fast-forward to newer remote context.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'diverged cache is preserved and reported read-only'; Run = {
    $env = New-TestEnvironment -Name 'diverged-start'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        Initialize-GitIdentity -Root $env.Cache
        Set-Content -LiteralPath (Join-Path $env.Cache 'local-ahead.md') -Value 'local commit' -Encoding UTF8
        Invoke-Git -Root $env.Cache -Arguments @('add', 'local-ahead.md') | Out-Null
        Invoke-Git -Root $env.Cache -Arguments @('commit', '-m', 'local ahead') | Out-Null
        $localHead = Invoke-Git -Root $env.Cache -Arguments @('rev-parse', 'HEAD')
        Set-Content -LiteralPath (Join-Path $env.ContextSeed 'state/current.md') -Value "# Current`nRemote divergent state.`n" -Encoding UTF8
        Invoke-Git -Root $env.ContextSeed -Arguments @('add', 'state/current.md') | Out-Null
        Invoke-Git -Root $env.ContextSeed -Arguments @('commit', '-m', 'remote diverge') | Out-Null
        Invoke-Git -Root $env.ContextSeed -Arguments @('push', 'origin', 'main') | Out-Null
        Invoke-Launcher -Env $env -Action 'start'
        $afterHead = Invoke-Git -Root $env.Cache -Arguments @('rev-parse', 'HEAD')
        Assert-True -Condition ($afterHead -eq $localHead) -Message 'Diverged cache must preserve the local commit.'
        $runtime = Get-Content -LiteralPath (Join-Path $env.MemberClone '.ai-bridge/context-runtime.json') -Raw | ConvertFrom-Json
        Assert-True -Condition ($runtime.context.freshness -eq 'DIVERGED_LOCAL_CONTEXT') -Message 'Diverged cache must be reported as DIVERGED_LOCAL_CONTEXT.'
        Assert-True -Condition ($runtime.context.dirty -eq $false) -Message 'Clean diverged cache should not be mislabeled dirty.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'start does not overwrite dirty context cache'; Run = {
    $env = New-TestEnvironment -Name 'dirty-start'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        $marker = Join-Path $env.Cache 'local-dirty-marker.txt'
        Set-Content -LiteralPath $marker -Value 'preserve me' -Encoding UTF8
        Invoke-Launcher -Env $env -Action 'start'
        Assert-True -Condition (Test-Path -LiteralPath $marker) -Message 'Dirty context content must be preserved.'
        $runtime = Get-Content -LiteralPath (Join-Path $env.MemberClone '.ai-bridge/context-runtime.json') -Raw | ConvertFrom-Json
        Assert-True -Condition ($runtime.context.dirty -eq $true) -Message 'Runtime must report dirty central context cache.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'invalid checkpoint missing required fields is rejected'; Run = {
    $env = New-TestEnvironment -Name 'missing-field'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        '{"schemaVersion":1,"repository":"test-member"}' | Set-Content -LiteralPath $env.Checkpoint -Encoding UTF8
        $result = Invoke-LauncherAllowFailure -Env $env -Action 'checkpoint'
        Assert-True -Condition ($result.ExitCode -ne 0) -Message 'Missing required checkpoint fields must fail.'
        Assert-True -Condition ($result.Output -like '*missing required field*') -Message 'Missing-field failure should be explicit.'
        Assert-True -Condition (Test-Path -LiteralPath $env.Checkpoint) -Message 'Rejected checkpoint should remain for inspection/correction.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'disallowed checkpoint status is rejected'; Run = {
    $env = New-TestEnvironment -Name 'bad-status'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        Write-ValidCheckpoint -Env $env -Status 'DONE'
        $result = Invoke-LauncherAllowFailure -Env $env -Action 'checkpoint'
        Assert-True -Condition ($result.ExitCode -ne 0) -Message 'Disallowed status must fail.'
        Assert-True -Condition ($result.Output -like '*status is not allowed*') -Message 'Disallowed status failure should be explicit.'
        Assert-True -Condition (Test-Path -LiteralPath $env.Checkpoint) -Message 'Rejected checkpoint should remain.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'secret-like material is rejected without committing'; Run = {
    $env = New-TestEnvironment -Name 'secret'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        $secretLike = 'Bear' + 'er ' + 'abcdefghijklmnopqrstuvwxyz'
        Write-ValidCheckpoint -Env $env -Objective $secretLike
        $result = Invoke-LauncherAllowFailure -Env $env -Action 'checkpoint'
        Assert-True -Condition ($result.ExitCode -ne 0) -Message 'Secret-like content must fail.'
        Assert-True -Condition ($result.Output -like '*secret-like material*') -Message 'Secret failure should be explicit without echoing the secret.'
        Assert-True -Condition ($result.Output -notlike '*abcdefghijklmnopqrstuvwxyz*') -Message 'Secret failure must not echo the secret value.'
        Assert-True -Condition (Test-Path -LiteralPath $env.Checkpoint) -Message 'Rejected checkpoint should remain.'
        $count = [int](Invoke-Git -Root $env.Cache -Arguments @('rev-list', '--count', 'HEAD'))
        Assert-True -Condition ($count -eq 1) -Message 'Secret rejection must not create a context commit.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'checkpoint writes repository scoped artifacts commits and pushes'; Run = {
    $env = New-TestEnvironment -Name 'checkpoint'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        Initialize-GitIdentity -Root $env.Cache
        Write-ValidCheckpoint -Env $env
        Invoke-Launcher -Env $env -Action 'checkpoint'
        Assert-True -Condition (-not (Test-Path -LiteralPath $env.Checkpoint)) -Message 'Successful checkpoint must clear replay file.'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $env.Cache 'state/repositories/test-member.md')) -Message 'Repository state should be generated.'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $env.Cache 'handoffs/repositories/test-member.md')) -Message 'Repository handoff should be generated.'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $env.Cache 'manifests/repositories/test-member.json')) -Message 'Repository manifest should be generated.'
        $localHead = Invoke-Git -Root $env.Cache -Arguments @('rev-parse', 'HEAD')
        $remoteHead = (& git --git-dir $env.ContextBare rev-parse refs/heads/main).Trim()
        Assert-True -Condition ($localHead -eq $remoteHead) -Message 'Checkpoint commit must be pushed to context remote.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'checkpoint refuses pre-existing dirty context work'; Run = {
    $env = New-TestEnvironment -Name 'dirty-checkpoint'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        Set-Content -LiteralPath (Join-Path $env.Cache 'unexpected.txt') -Value 'dirty' -Encoding UTF8
        Write-ValidCheckpoint -Env $env
        $result = Invoke-LauncherAllowFailure -Env $env -Action 'checkpoint'
        Assert-True -Condition ($result.ExitCode -ne 0) -Message 'Dirty cache checkpoint must fail.'
        Assert-True -Condition ($result.Output -like '*pre-existing uncommitted changes*') -Message 'Dirty-cache failure should be explicit.'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $env.Cache 'unexpected.txt')) -Message 'Dirty file must not be destroyed.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'v2 tracked checkpoint persists workstream validation ledger and runtime cursor'; Run = {
    $env = New-TestEnvironment -Name 'v2-tracked'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        Initialize-GitIdentity -Root $env.Cache
        Write-TrackedCheckpoint -Env $env
        Invoke-Launcher -Env $env -Action 'checkpoint'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $env.Cache 'workstreams/active/landing-polish.json')) -Message 'Tracked workstream must be stored as a durable active workstream.'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $env.Cache 'validation/repositories/test-member.json')) -Message 'Validation ledger must be persisted.'
        $manifest = Get-Content -LiteralPath (Join-Path $env.Cache 'manifests/repositories/test-member.json') -Raw | ConvertFrom-Json
        $expectedSessionYear = [DateTime]::Now.Year.ToString('0000',[Globalization.CultureInfo]::InvariantCulture)
        Assert-True -Condition ([string]$manifest.session -like "sessions/$expectedSessionYear/*") -Message 'Checkpoint session path must use the Gregorian year regardless of host culture.'
        Assert-True -Condition ($manifest.continuity.workstreamId -eq 'landing-polish') -Message 'Repository manifest must point to the tracked workstream.'
        Assert-True -Condition ($manifest.continuity.currentItemId -eq 'WS-1') -Message 'Repository manifest must persist the execution cursor.'
        Invoke-Launcher -Env $env -Action 'start'
        $runtime = Get-Content -LiteralPath (Join-Path $env.MemberClone '.ai-bridge/context-runtime.json') -Raw | ConvertFrom-Json
        Assert-True -Condition ($runtime.continuity.workstreamId -eq 'landing-polish') -Message 'Fresh start must recover the active workstream id.'
        Assert-True -Condition ($runtime.continuity.currentItemId -eq 'WS-1') -Message 'Fresh start must recover the exact current item.'
        Assert-True -Condition ($runtime.continuity.validation.freshEntries -eq 1) -Message 'Validation recorded for unchanged worktree must be fresh.'
        $runtimeText = Get-Content -LiteralPath (Join-Path $env.MemberClone '.ai-bridge/context-runtime.md') -Raw
        Assert-True -Condition ($runtimeText -like '*WS-2 - Validate offline resume*') -Message 'Runtime Markdown must expose pending backlog items.'
        Assert-True -Condition ($runtimeText -like '*Workstream survives checkpoint and start*') -Message 'Runtime Markdown must expose acceptance criteria.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'v2 checkpoint rejects silent work item loss and preserves durable context'; Run = {
    $env = New-TestEnvironment -Name 'v2-loss'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        Initialize-GitIdentity -Root $env.Cache
        Write-TrackedCheckpoint -Env $env
        Invoke-Launcher -Env $env -Action 'checkpoint'
        $before = Invoke-Git -Root $env.Cache -Arguments @('rev-parse', 'HEAD')
        Write-TrackedCheckpoint -Env $env -ValidationId 'VAL-2'
        $checkpoint = Get-Content -LiteralPath $env.Checkpoint -Raw | ConvertFrom-Json
        $checkpoint.continuity.workstream.items = @($checkpoint.continuity.workstream.items | Where-Object id -ne 'WS-2')
        $checkpoint | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $env.Checkpoint -Encoding UTF8
        $result = Invoke-LauncherAllowFailure -Env $env -Action 'checkpoint'
        Assert-True -Condition ($result.ExitCode -ne 0) -Message 'Dropping a previously tracked work item must fail closed.'
        Assert-True -Condition ($result.Output -like '*would lose existing work items*WS-2*') -Message 'Loss-prevention failure must identify the lost item.'
        $after = Invoke-Git -Root $env.Cache -Arguments @('rev-parse', 'HEAD')
        Assert-True -Condition ($after -eq $before) -Message 'Rejected loss checkpoint must not mutate central context history.'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $env.Cache 'workstreams/active/landing-polish.json')) -Message 'Existing tracked workstream must remain intact.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'v2 checkpoint accepts explicit item transition and moves execution cursor'; Run = {
    $env = New-TestEnvironment -Name 'v2-transition'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        Initialize-GitIdentity -Root $env.Cache
        Write-TrackedCheckpoint -Env $env
        Invoke-Launcher -Env $env -Action 'checkpoint'
        Write-TrackedCheckpoint -Env $env -ValidationId 'VAL-2'
        $checkpoint = Get-Content -LiteralPath $env.Checkpoint -Raw | ConvertFrom-Json
        $checkpoint.nextAction = 'Finish WS-2.'
        $checkpoint.continuity.workstream.cursor.currentItemId = 'WS-2'
        $checkpoint.continuity.workstream.cursor.lastCompletedItemId = 'WS-1'
        $checkpoint.continuity.workstream.cursor.lastCompletedAction = 'Implemented structured backlog.'
        $checkpoint.continuity.workstream.cursor.nextAction = 'Finish WS-2.'
        $checkpoint.continuity.workstream.items[0].status = 'COMPLETED'
        $checkpoint.continuity.workstream.items[1].status = 'IN_PROGRESS'
        $checkpoint | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $env.Checkpoint -Encoding UTF8
        Invoke-Launcher -Env $env -Action 'checkpoint'
        $workstream = Get-Content -LiteralPath (Join-Path $env.Cache 'workstreams/active/landing-polish.json') -Raw | ConvertFrom-Json
        Assert-True -Condition ($workstream.cursor.currentItemId -eq 'WS-2') -Message 'Explicit cursor transition must be persisted.'
        Assert-True -Condition ($workstream.items[0].status -eq 'COMPLETED') -Message 'Completed work item transition must be persisted.'
        Assert-True -Condition ($workstream.items[1].status -eq 'IN_PROGRESS') -Message 'Next work item must be explicitly in progress.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'v2 validation ledger becomes stale when member worktree changes'; Run = {
    $env = New-TestEnvironment -Name 'v2-stale-validation'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        Initialize-GitIdentity -Root $env.Cache
        Write-TrackedCheckpoint -Env $env
        Invoke-Launcher -Env $env -Action 'checkpoint'
        Add-Content -LiteralPath (Join-Path $env.MemberClone 'README.md') -Value 'product drift'
        Invoke-Launcher -Env $env -Action 'start'
        $runtime = Get-Content -LiteralPath (Join-Path $env.MemberClone '.ai-bridge/context-runtime.json') -Raw | ConvertFrom-Json
        Assert-True -Condition ($runtime.continuity.validation.freshEntries -eq 0) -Message 'Validation must not remain fresh after member worktree changes.'
        Assert-True -Condition ($runtime.continuity.validation.staleEntries -eq 1) -Message 'Changed worktree must mark the previous validation stale.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'legacy v1 checkpoint cannot erase an unresolved v2 workstream'; Run = {
    $env = New-TestEnvironment -Name 'v2-v1-loss'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        Initialize-GitIdentity -Root $env.Cache
        Write-TrackedCheckpoint -Env $env
        Invoke-Launcher -Env $env -Action 'checkpoint'
        Write-ValidCheckpoint -Env $env
        $result = Invoke-LauncherAllowFailure -Env $env -Action 'checkpoint'
        Assert-True -Condition ($result.ExitCode -ne 0) -Message 'Legacy checkpoint must not silently erase an active v2 workstream.'
        Assert-True -Condition ($result.Output -like '*would lose an active tracked workstream*') -Message 'Legacy loss rejection must be explicit.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'v2 dependency cycle is rejected'; Run = {
    $env = New-TestEnvironment -Name 'v2-cycle'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        Initialize-GitIdentity -Root $env.Cache
        Write-TrackedCheckpoint -Env $env
        $checkpoint = Get-Content -LiteralPath $env.Checkpoint -Raw | ConvertFrom-Json
        $checkpoint.continuity.workstream.items[0].dependsOn = @('WS-2')
        $checkpoint | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $env.Checkpoint -Encoding UTF8
        $result = Invoke-LauncherAllowFailure -Env $env -Action 'checkpoint'
        Assert-True -Condition ($result.ExitCode -ne 0) -Message 'Dependency cycle must fail closed.'
        Assert-True -Condition ($result.Output -like '*dependency cycle*') -Message 'Dependency-cycle rejection must be explicit.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'v2 duplicate validation ledger id is rejected'; Run = {
    $env = New-TestEnvironment -Name 'v2-duplicate-validation'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        Initialize-GitIdentity -Root $env.Cache
        Write-TrackedCheckpoint -Env $env
        Invoke-Launcher -Env $env -Action 'checkpoint'
        $before = Invoke-Git -Root $env.Cache -Arguments @('rev-parse', 'HEAD')
        Write-TrackedCheckpoint -Env $env -ValidationId 'VAL-1'
        $result = Invoke-LauncherAllowFailure -Env $env -Action 'checkpoint'
        Assert-True -Condition ($result.ExitCode -ne 0) -Message 'Duplicate immutable validation id must fail.'
        Assert-True -Condition ($result.Output -like '*immutable and already exist*VAL-1*') -Message 'Duplicate validation rejection must identify the id.'
        $after = Invoke-Git -Root $env.Cache -Arguments @('rev-parse', 'HEAD')
        Assert-True -Condition ($after -eq $before) -Message 'Duplicate validation rejection must not mutate context history.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'v2 snapshot cannot erase an unresolved tracked workstream'; Run = {
    $env = New-TestEnvironment -Name 'v2-snapshot-loss'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        Initialize-GitIdentity -Root $env.Cache
        Write-TrackedCheckpoint -Env $env
        Invoke-Launcher -Env $env -Action 'checkpoint'
        [ordered]@{
            schemaVersion = 2; repository = 'test-member'; scope = 'snapshot-loss'; status = 'VALIDATED'
            objective = 'Attempt unsafe snapshot.'; confirmedFindings = @(); decisions = @(); rejectedApproaches = @()
            validation = @(); openQuestions = @(); nextAction = 'Continue.'
            continuity = [ordered]@{ mode = 'snapshot'; workstream = $null; validationLedger = @() }
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env.Checkpoint -Encoding UTF8
        $result = Invoke-LauncherAllowFailure -Env $env -Action 'checkpoint'
        Assert-True -Condition ($result.ExitCode -ne 0) -Message 'Snapshot must not erase unresolved tracked work.'
        Assert-True -Condition ($result.Output -like '*Snapshot checkpoint would lose an active tracked workstream*') -Message 'Snapshot-loss rejection must be explicit.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'v2 completed workstream moves from active to archive'; Run = {
    $env = New-TestEnvironment -Name 'v2-archive'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        Initialize-GitIdentity -Root $env.Cache
        Write-TrackedCheckpoint -Env $env
        Invoke-Launcher -Env $env -Action 'checkpoint'

        Write-TrackedCheckpoint -Env $env -ValidationId 'VAL-2'
        $checkpoint = Get-Content -LiteralPath $env.Checkpoint -Raw | ConvertFrom-Json
        $checkpoint.nextAction = 'Finish WS-2.'
        $checkpoint.continuity.workstream.cursor.currentItemId = 'WS-2'
        $checkpoint.continuity.workstream.cursor.lastCompletedItemId = 'WS-1'
        $checkpoint.continuity.workstream.cursor.lastCompletedAction = 'Finished WS-1.'
        $checkpoint.continuity.workstream.cursor.nextAction = 'Finish WS-2.'
        $checkpoint.continuity.workstream.items[0].status = 'COMPLETED'
        $checkpoint.continuity.workstream.items[1].status = 'IN_PROGRESS'
        $checkpoint | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $env.Checkpoint -Encoding UTF8
        Invoke-Launcher -Env $env -Action 'checkpoint'

        Write-TrackedCheckpoint -Env $env -ValidationId 'VAL-3'
        $checkpoint = Get-Content -LiteralPath $env.Checkpoint -Raw | ConvertFrom-Json
        $checkpoint.status = 'VALIDATED'
        $checkpoint.nextAction = 'Workstream complete.'
        $checkpoint.continuity.workstream.status = 'COMPLETED'
        $checkpoint.continuity.workstream.cursor.currentItemId = $null
        $checkpoint.continuity.workstream.cursor.lastCompletedItemId = 'WS-2'
        $checkpoint.continuity.workstream.cursor.lastCompletedAction = 'Validated offline resume.'
        $checkpoint.continuity.workstream.cursor.nextAction = 'Workstream complete.'
        $checkpoint.continuity.workstream.items[0].status = 'COMPLETED'
        $checkpoint.continuity.workstream.items[1].status = 'COMPLETED'
        $checkpoint | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $env.Checkpoint -Encoding UTF8
        Invoke-Launcher -Env $env -Action 'checkpoint'

        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $env.Cache 'workstreams/active/landing-polish.json'))) -Message 'Completed workstream must leave active storage.'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $env.Cache 'workstreams/archive/landing-polish.json')) -Message 'Completed workstream must be archived durably.'
        $manifest = Get-Content -LiteralPath (Join-Path $env.Cache 'manifests/repositories/test-member.json') -Raw | ConvertFrom-Json
        Assert-True -Condition ($manifest.continuity.workstreamStatus -eq 'COMPLETED') -Message 'Manifest must record terminal workstream status.'
        Assert-True -Condition ($manifest.continuity.workstreamPath -eq 'workstreams/archive/landing-polish.json') -Message 'Manifest must point to archived workstream.'
        Assert-True -Condition ($null -eq $manifest.continuity.currentItemId) -Message 'Completed workstream must clear current item.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'offline export import resumes exact workstream without remote access and supports offline checkpoint'; Run = {
    $env = New-TestEnvironment -Name 'offline-roundtrip'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        Initialize-GitIdentity -Root $env.Cache
        Write-TrackedCheckpoint -Env $env
        Invoke-Launcher -Env $env -Action 'checkpoint'
        Invoke-Launcher -Env $env -Action 'export'

        $transfer = Join-Path $env.MemberClone '.ai-bridge/context-transfer'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $transfer 'manifest.json')) -Message 'Offline export must create a manifest.'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $transfer 'context.bundle')) -Message 'Offline export must create a Git bundle.'

        $consumerRoot = Join-Path $env.Base 'member-offline'
        & git clone $env.MemberBare $consumerRoot | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to clone offline consumer member repository.' }
        Initialize-GitIdentity -Root $consumerRoot
        $consumerTransfer = Join-Path $consumerRoot '.ai-bridge/context-transfer'
        New-Item -ItemType Directory -Path (Split-Path -Parent $consumerTransfer) -Force | Out-Null
        Copy-Item -LiteralPath $transfer -Destination $consumerTransfer -Recurse

        $offlineRemote = "$($env.ContextBare).offline"
        Move-Item -LiteralPath $env.ContextBare -Destination $offlineRemote

        $consumer = [pscustomobject]@{
            Base = $env.Base
            MemberClone = $consumerRoot
            Launcher = (Join-Path $consumerRoot '.ai/context/context.ps1')
            Cache = (Join-Path $consumerRoot '.ai/context/cache/project-context')
            Checkpoint = (Join-Path $consumerRoot '.ai-bridge/context-checkpoint.json')
        }
        Invoke-Launcher -Env $consumer -Action 'import'
        Initialize-GitIdentity -Root $consumer.Cache
        Invoke-Launcher -Env $consumer -Action 'start'
        $runtime = Get-Content -LiteralPath (Join-Path $consumerRoot '.ai-bridge/context-runtime.json') -Raw | ConvertFrom-Json
        Assert-True -Condition ($runtime.context.freshness -eq 'OFFLINE_IMPORTED_CONTEXT') -Message 'Offline start must explicitly report imported offline context.'
        Assert-True -Condition ($runtime.continuity.workstreamId -eq 'landing-polish') -Message 'Offline import must recover the active workstream.'
        Assert-True -Condition ($runtime.continuity.currentItemId -eq 'WS-1') -Message 'Offline import must recover the exact execution cursor.'

        $beforeOfflineCheckpoint = Invoke-Git -Root $consumer.Cache -Arguments @('rev-parse', 'HEAD')
        Write-TrackedCheckpoint -Env $consumer -ValidationId 'VAL-OFFLINE-2'
        $checkpoint = Get-Content -LiteralPath $consumer.Checkpoint -Raw | ConvertFrom-Json
        $checkpoint.nextAction = 'Finish WS-2.'
        $checkpoint.continuity.workstream.cursor.currentItemId = 'WS-2'
        $checkpoint.continuity.workstream.cursor.lastCompletedItemId = 'WS-1'
        $checkpoint.continuity.workstream.cursor.lastCompletedAction = 'Finished WS-1 offline.'
        $checkpoint.continuity.workstream.cursor.nextAction = 'Finish WS-2.'
        $checkpoint.continuity.workstream.items[0].status = 'COMPLETED'
        $checkpoint.continuity.workstream.items[1].status = 'IN_PROGRESS'
        $checkpoint | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $consumer.Checkpoint -Encoding UTF8
        Invoke-Launcher -Env $consumer -Action 'checkpoint'
        $afterOfflineCheckpoint = Invoke-Git -Root $consumer.Cache -Arguments @('rev-parse', 'HEAD')
        Assert-True -Condition ($afterOfflineCheckpoint -ne $beforeOfflineCheckpoint) -Message 'Offline checkpoint must commit continuity locally.'
        $marker = Get-Content -LiteralPath (Join-Path $consumerRoot '.ai-bridge/context-offline.json') -Raw | ConvertFrom-Json
        Assert-True -Condition ($marker.currentContextHead -eq $afterOfflineCheckpoint) -Message 'Offline marker must advance to the local checkpoint HEAD.'
        Invoke-Launcher -Env $consumer -Action 'start'
        $runtime2 = Get-Content -LiteralPath (Join-Path $consumerRoot '.ai-bridge/context-runtime.json') -Raw | ConvertFrom-Json
        Assert-True -Condition ($runtime2.continuity.currentItemId -eq 'WS-2') -Message 'Offline resume after local checkpoint must recover the new current item.'

        Move-Item -LiteralPath $offlineRemote -Destination $env.ContextBare
        Invoke-Launcher -Env $consumer -Action 'reconnect'
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $consumerRoot '.ai-bridge/context-offline.json'))) -Message 'Successful reconnect must clear the offline marker.'
        $remoteHead = (& git --git-dir $env.ContextBare rev-parse refs/heads/main).Trim()
        Assert-True -Condition ($remoteHead -eq $afterOfflineCheckpoint) -Message 'Reconnect must publish offline context commits with a normal push.'
        Invoke-Launcher -Env $consumer -Action 'start'
        $runtime3 = Get-Content -LiteralPath (Join-Path $consumerRoot '.ai-bridge/context-runtime.json') -Raw | ConvertFrom-Json
        Assert-True -Condition ($runtime3.context.freshness -eq 'CURRENT_OR_FETCHED') -Message 'After reconnect, lifecycle must return to ordinary online freshness.'
        Assert-True -Condition ($runtime3.continuity.currentItemId -eq 'WS-2') -Message 'Reconnect must preserve the exact workstream cursor.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'offline import rejects tampered bundle before cache creation'; Run = {
    $env = New-TestEnvironment -Name 'offline-tamper'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        Initialize-GitIdentity -Root $env.Cache
        Write-TrackedCheckpoint -Env $env
        Invoke-Launcher -Env $env -Action 'checkpoint'
        Invoke-Launcher -Env $env -Action 'export'
        Remove-Item -LiteralPath $env.Cache -Recurse -Force
        Add-Content -LiteralPath (Join-Path $env.MemberClone '.ai-bridge/context-transfer/context.bundle') -Value 'tampered'
        $result = Invoke-LauncherAllowFailure -Env $env -Action 'import'
        Assert-True -Condition ($result.ExitCode -ne 0) -Message 'Tampered transfer bundle must be rejected.'
        Assert-True -Condition (($result.Output -like '*bundle size does not match*') -or ($result.Output -like '*SHA-256 does not match*')) -Message 'Tampered bundle rejection must be integrity-specific.'
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $env.Cache '.git'))) -Message 'Rejected tampered transfer must not create an imported cache.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'offline import rejects conflicting existing context head without reconciliation'; Run = {
    $env = New-TestEnvironment -Name 'offline-conflict'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        Initialize-GitIdentity -Root $env.Cache
        Write-TrackedCheckpoint -Env $env
        Invoke-Launcher -Env $env -Action 'checkpoint'
        Invoke-Launcher -Env $env -Action 'export'
        Set-Content -LiteralPath (Join-Path $env.Cache 'local-conflict.md') -Value 'independent offline writer' -Encoding UTF8
        Invoke-Git -Root $env.Cache -Arguments @('add', 'local-conflict.md') | Out-Null
        Invoke-Git -Root $env.Cache -Arguments @('commit', '-m', 'local conflicting context') | Out-Null
        $conflictHead = Invoke-Git -Root $env.Cache -Arguments @('rev-parse', 'HEAD')
        $result = Invoke-LauncherAllowFailure -Env $env -Action 'import'
        Assert-True -Condition ($result.ExitCode -ne 0) -Message 'Import over a different clean context HEAD must fail closed.'
        Assert-True -Condition ($result.Output -like '*conflicts with the existing context cache HEAD*') -Message 'Offline writer conflict must be explicit.'
        Assert-True -Condition ((Invoke-Git -Root $env.Cache -Arguments @('rev-parse', 'HEAD')) -eq $conflictHead) -Message 'Conflict rejection must preserve the existing context HEAD.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'offline export rejects secret-like tracked context material'; Run = {
    $env = New-TestEnvironment -Name 'offline-secret'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        Initialize-GitIdentity -Root $env.Cache
        $secretLike = 'Bear' + 'er ' + 'abcdefghijklmnop'
        Set-Content -LiteralPath (Join-Path $env.Cache 'secret-fixture.md') -Value $secretLike -Encoding UTF8
        Invoke-Git -Root $env.Cache -Arguments @('add', 'secret-fixture.md') | Out-Null
        Invoke-Git -Root $env.Cache -Arguments @('commit', '-m', 'secret fixture') | Out-Null
        $result = Invoke-LauncherAllowFailure -Env $env -Action 'export'
        Assert-True -Condition ($result.ExitCode -ne 0) -Message 'Secret-like tracked context must block offline export.'
        Assert-True -Condition ($result.Output -like '*refused secret-like material*secret-fixture.md*') -Message 'Secret export rejection must identify the tracked context path.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'offline reconnect rejects divergent local and remote writers without mutation'; Run = {
    $env = New-TestEnvironment -Name 'offline-reconnect-diverged'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        Initialize-GitIdentity -Root $env.Cache
        Write-TrackedCheckpoint -Env $env
        Invoke-Launcher -Env $env -Action 'checkpoint'
        Invoke-Launcher -Env $env -Action 'export'
        $remoteDisabled = "$($env.ContextBare).offline"
        Move-Item -LiteralPath $env.ContextBare -Destination $remoteDisabled

        $consumerRoot = Join-Path $env.Base 'member-offline-diverged'
        & git clone $env.MemberBare $consumerRoot | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to clone divergent offline consumer.' }
        Initialize-GitIdentity -Root $consumerRoot
        Copy-Item -LiteralPath (Join-Path $env.MemberClone '.ai-bridge/context-transfer') -Destination (Join-Path $consumerRoot '.ai-bridge/context-transfer') -Recurse
        $consumer = [pscustomobject]@{
            Base = $env.Base
            MemberClone = $consumerRoot
            Launcher = (Join-Path $consumerRoot '.ai/context/context.ps1')
            Cache = (Join-Path $consumerRoot '.ai/context/cache/project-context')
            Checkpoint = (Join-Path $consumerRoot '.ai-bridge/context-checkpoint.json')
        }
        Invoke-Launcher -Env $consumer -Action 'import'
        Initialize-GitIdentity -Root $consumer.Cache
        Write-TrackedCheckpoint -Env $consumer -ValidationId 'VAL-DIVERGED-2'
        $checkpoint = Get-Content -LiteralPath $consumer.Checkpoint -Raw | ConvertFrom-Json
        $checkpoint.nextAction = 'Finish WS-2.'
        $checkpoint.continuity.workstream.cursor.currentItemId = 'WS-2'
        $checkpoint.continuity.workstream.cursor.lastCompletedItemId = 'WS-1'
        $checkpoint.continuity.workstream.cursor.lastCompletedAction = 'Finished WS-1 offline.'
        $checkpoint.continuity.workstream.cursor.nextAction = 'Finish WS-2.'
        $checkpoint.continuity.workstream.items[0].status = 'COMPLETED'
        $checkpoint.continuity.workstream.items[1].status = 'IN_PROGRESS'
        $checkpoint | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $consumer.Checkpoint -Encoding UTF8
        Invoke-Launcher -Env $consumer -Action 'checkpoint'
        $localHead = Invoke-Git -Root $consumer.Cache -Arguments @('rev-parse', 'HEAD')

        Move-Item -LiteralPath $remoteDisabled -Destination $env.ContextBare
        $remoteWriter = Join-Path $env.Base 'remote-writer'
        & git clone --branch main --single-branch $env.ContextBare $remoteWriter | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to clone remote writer.' }
        Initialize-GitIdentity -Root $remoteWriter
        Set-Content -LiteralPath (Join-Path $remoteWriter 'remote-independent.md') -Value 'remote writer' -Encoding UTF8
        Invoke-Git -Root $remoteWriter -Arguments @('add', 'remote-independent.md') | Out-Null
        Invoke-Git -Root $remoteWriter -Arguments @('commit', '-m', 'remote independent context') | Out-Null
        Invoke-Git -Root $remoteWriter -Arguments @('push', 'origin', 'main') | Out-Null
        $remoteHead = (& git --git-dir $env.ContextBare rev-parse refs/heads/main).Trim()

        $result = Invoke-LauncherAllowFailure -Env $consumer -Action 'reconnect'
        Assert-True -Condition ($result.ExitCode -ne 0) -Message 'Divergent offline/remote context must fail reconnect.'
        Assert-True -Condition ($result.Output -like '*offline reconciliation conflict*') -Message 'Divergence rejection must be explicit.'
        Assert-True -Condition ((Invoke-Git -Root $consumer.Cache -Arguments @('rev-parse','HEAD')) -eq $localHead) -Message 'Reconnect conflict must preserve local context HEAD.'
        Assert-True -Condition ((& git --git-dir $env.ContextBare rev-parse refs/heads/main).Trim() -eq $remoteHead) -Message 'Reconnect conflict must preserve remote context HEAD.'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $consumerRoot '.ai-bridge/context-offline.json')) -Message 'Reconnect conflict must preserve offline marker for explicit reconciliation.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'unregistered member start status and checkpoint fail closed'; Run = {
    $env = New-TestEnvironment -Name 'unregistered-member'
    try {
        Set-Content -LiteralPath (Join-Path $env.ContextSeed 'repositories/repositories.yaml') -Value "project: test-project`nrepositories: {}`n" -Encoding UTF8
        Invoke-Git -Root $env.ContextSeed -Arguments @('add', 'repositories/repositories.yaml') | Out-Null
        Invoke-Git -Root $env.ContextSeed -Arguments @('commit', '-m', 'remove member registration') | Out-Null
        Invoke-Git -Root $env.ContextSeed -Arguments @('push', 'origin', 'main') | Out-Null

        $start = Invoke-LauncherAllowFailure -Env $env -Action 'start'
        Assert-True -Condition ($start.ExitCode -ne 0) -Message 'Unregistered member start must fail.'
        Assert-True -Condition ($start.Output -like '*not registered*') -Message 'Unregistered start error must be actionable.'
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $env.MemberClone '.ai-bridge/context-runtime.json'))) -Message 'Failed start must not report usable runtime context.'

        $status = Invoke-LauncherAllowFailure -Env $env -Action 'status'
        Assert-True -Condition ($status.ExitCode -ne 0) -Message 'Unregistered member status must be unhealthy.'
        Assert-True -Condition ($status.Output -like '*"registered":  false*' -or $status.Output -like '*"registered": false*') -Message 'Status must expose unregistered membership.'

        Write-ValidCheckpoint -Env $env
        $checkpoint = Invoke-LauncherAllowFailure -Env $env -Action 'checkpoint'
        Assert-True -Condition ($checkpoint.ExitCode -ne 0) -Message 'Unregistered checkpoint must fail.'
        Assert-True -Condition (Test-Path -LiteralPath $env.Checkpoint) -Message 'Rejected checkpoint artifact must remain for recovery.'
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $env.Cache 'state/repositories/test-member.md'))) -Message 'Rejected unregistered checkpoint must not write durable repository state.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'membership audit reports candidates without mutation'; Run = {
    $env = New-TestEnvironment -Name 'membership-audit'
    try {
        $candidate = Join-Path $env.Base 'test-project-docs'
        & git init --initial-branch=main $candidate | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize audit candidate.' }
        Initialize-GitIdentity -Root $candidate
        Set-Content -LiteralPath (Join-Path $candidate 'AI_CONTEXT.md') -Value '# Candidate' -Encoding UTF8
        Invoke-Git -Root $candidate -Arguments @('add', 'AI_CONTEXT.md') | Out-Null
        Invoke-Git -Root $candidate -Arguments @('commit', '-m', 'candidate') | Out-Null
        $contextAlias = Join-Path $env.Base 'local-context-alias'
        & git clone --branch main --single-branch $env.ContextBare $contextAlias | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to clone context alias.' }
        $before = (& git --git-dir $env.ContextBare rev-parse refs/heads/main).Trim()
        $audit = Invoke-LauncherAllowFailure -Env $env -Action 'audit'
        $after = (& git --git-dir $env.ContextBare rev-parse refs/heads/main).Trim()
        Assert-True -Condition ($audit.ExitCode -eq 0) -Message ("Membership audit must succeed read-only. Output: " + $audit.Output)
        Assert-True -Condition ($audit.Output -like '*test-project-docs*') -Message 'Audit must report unregistered candidate.'
        Assert-True -Condition ($audit.Output -notlike '*local-context-alias*') -Message 'Audit must exclude a sibling clone of the central context remote even when its folder name differs.'
        Assert-True -Condition ($before -eq $after) -Message 'Audit must not mutate central context history.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'online checkpoint divergence rejects without rebase'; Run = {
    $env = New-TestEnvironment -Name 'online-divergence'
    try {
        Invoke-Launcher -Env $env -Action 'start'
        Initialize-GitIdentity -Root $env.Cache
        $remoteWriter = Join-Path $env.Base 'remote-writer-online'
        & git clone --branch main --single-branch $env.ContextBare $remoteWriter | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to clone online remote writer.' }
        Initialize-GitIdentity -Root $remoteWriter
        $writerPath = $remoteWriter.Replace([char]92, [char]47)
        $hook = Join-Path $env.Cache '.git/hooks/pre-push'
        $hookText = @"
#!/usr/bin/env bash
rm -f -- "`$0"
printf 'remote race\n' >'$writerPath/online-race-remote.md'
git -C '$writerPath' add online-race-remote.md
git -C '$writerPath' commit -m 'remote online race' >/dev/null
git -C '$writerPath' push origin main >/dev/null
"@
        [System.IO.File]::WriteAllText($hook, $hookText, [System.Text.UTF8Encoding]::new($false))
        & git -C $env.Cache update-index --refresh | Out-Null
        if (Get-Command bash -ErrorAction SilentlyContinue) { & bash -lc "chmod +x '$($hook.Replace([char]92,[char]47))'" | Out-Null }
        Write-ValidCheckpoint -Env $env
        $result = Invoke-LauncherAllowFailure -Env $env -Action 'checkpoint'
        Assert-True -Condition ($result.ExitCode -ne 0) -Message 'Concurrent divergent checkpoint must fail.'
        Assert-True -Condition ($result.Output -like '*histories diverged*') -Message 'Divergence failure must be explicit.'
        Assert-True -Condition (Test-Path -LiteralPath $env.Checkpoint) -Message 'Rejected checkpoint artifact must remain.'
        $localHead = Invoke-Git -Root $env.Cache -Arguments @('rev-parse', 'HEAD')
        $remoteHead = (& git --git-dir $env.ContextBare rev-parse refs/heads/main).Trim()
        Assert-True -Condition ($localHead -ne $remoteHead) -Message 'Divergent histories must remain distinct.'
        & git -C $env.Cache merge-base --is-ancestor $localHead $remoteHead 2>$null; $localAncestor = $LASTEXITCODE -eq 0
        & git -C $env.Cache merge-base --is-ancestor $remoteHead $localHead 2>$null; $remoteAncestor = $LASTEXITCODE -eq 0
        Assert-True -Condition (-not $localAncestor -and -not $remoteAncestor) -Message 'Both divergent histories must be preserved.'
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $env.Cache '.git/rebase-merge')) -and -not (Test-Path -LiteralPath (Join-Path $env.Cache '.git/rebase-apply'))) -Message 'No rebase state may be created.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$tests += @{ Name = 'cache path traversal outside member repository is rejected'; Run = {
    $env = New-TestEnvironment -Name 'cache-escape'
    try {
        $configPath = Join-Path $env.MemberClone '.ai/context/config.json'
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $config.context.cachePath = '../../../escaped-cache'
        $config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding UTF8
        $result = Invoke-LauncherAllowFailure -Env $env -Action 'start'
        Assert-True -Condition ($result.ExitCode -ne 0) -Message 'Escaping cachePath must fail.'
        Assert-True -Condition ($result.Output -like '*cachePath must remain inside the member repository*') -Message 'Escaping cachePath failure should be explicit.'
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $env.Base 'escaped-cache'))) -Message 'Escaping cachePath must not create filesystem content outside the member repository.'
    } finally { Remove-Item -LiteralPath $env.Base -Recurse -Force -ErrorAction SilentlyContinue }
} }

$selectedTests = @($tests)
if (-not [string]::IsNullOrWhiteSpace($env:AI_CONTEXT_TEST_FILTER)) {
    $selectedTests = @($tests | Where-Object { $_.Name -like "*$($env:AI_CONTEXT_TEST_FILTER)*" })
    if ($selectedTests.Count -eq 0) { throw "No context lifecycle tests matched AI_CONTEXT_TEST_FILTER." }
}

$failures = 0
foreach ($test in $selectedTests) {
    try {
        & $test.Run
        Write-Host "PASS $($test.Name)"
    } catch {
        $failures++
        Write-Host "FAIL $($test.Name): $($_.Exception.Message)"
    }
}

if ($failures -gt 0) {
    throw "$failures context lifecycle test(s) failed."
}
Write-Host "PASS all $($selectedTests.Count) selected context lifecycle tests"
