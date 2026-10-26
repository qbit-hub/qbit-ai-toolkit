Set-StrictMode -Version Latest

$script:ContinuityTerminalWorkstreamStatuses = @('COMPLETED', 'CANCELLED', 'SUPERSEDED')
$script:ContinuityTerminalItemStatuses = @('COMPLETED', 'CANCELLED', 'SUPERSEDED')
$script:ContinuityItemTransitions = @{
    PENDING = @('PENDING', 'IN_PROGRESS', 'BLOCKED', 'CANCELLED', 'SUPERSEDED')
    IN_PROGRESS = @('IN_PROGRESS', 'BLOCKED', 'COMPLETED', 'CANCELLED', 'SUPERSEDED')
    BLOCKED = @('BLOCKED', 'IN_PROGRESS', 'CANCELLED', 'SUPERSEDED')
    COMPLETED = @('COMPLETED')
    CANCELLED = @('CANCELLED')
    SUPERSEDED = @('SUPERSEDED')
}

function Assert-ContinuityId {
    param([object]$Value, [string]$Label)
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text) -or $text -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z') {
        throw "$Label must use a stable alphanumeric/dot/underscore/hyphen identifier."
    }
    return $text
}

function Assert-ContinuityStringArray {
    param([object]$Value, [string]$Label)
    if ($null -eq $Value -or $Value -is [string]) { throw "$Label must be an array of non-empty strings." }
    $items = @($Value)
    foreach ($item in $items) {
        if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$item)) {
            throw "$Label must be an array of non-empty strings."
        }
    }
    if (@($items | Group-Object | Where-Object Count -gt 1).Count -gt 0) { throw "$Label must not contain duplicate values." }
    return $items
}

# Windows PowerShell 5.1 prepends a UTF-8 BOM when piping text to some native
# applications. Git then tries to hash a path beginning with U+FEFF and the
# entire batch fails. Write raw UTF-8 without BOM, and concurrently drain both
# output pipes to prevent deadlock on large repositories.
function Invoke-ContinuityHashBatch {
    param([string]$Root, [string[]]$Paths)
    if ($Paths.Count -eq 0) {
        return [pscustomobject]@{ ExitCode = 0; Hashes = @() }
    }
    $git = (Get-Command git.exe -ErrorAction Stop).Source
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $git
    $start.Arguments = '-c core.longpaths=true -C "' + $Root + '" hash-object --no-filters --stdin-paths'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    # .NET Framework creates the redirected StandardInput writer using the
    # process Console.InputEncoding; force a no-BOM encoding before it is made.
    $previousInputEncoding = [Console]::InputEncoding
    [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        # --stdin-paths accepts Git C-quoted names. Quote every path so literal
        # quotes, backslashes and control characters cannot split the batch.
        $quotedPaths = @($Paths | ForEach-Object {
            '"' + $_.Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n').Replace("`r", '\r').Replace("`t", '\t') + '"'
        })
        $bytes = ([System.Text.UTF8Encoding]::new($false)).GetBytes(($quotedPaths -join "`n") + "`n")
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(30000)) { throw 'Timed out hashing source files for the context fingerprint.' }
        $output = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $hashes = @($output -split "`r?`n" | Where-Object { $_ -ne '' })
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Hashes = $hashes; ErrorText = $stderr }
    } finally {
        if (-not $process.HasExited) { $process.Kill() }
        $process.Dispose()
        [Console]::InputEncoding = $previousInputEncoding
    }
}

function Invoke-ContinuityGitText {
    param([string]$Root, [string]$Arguments)
    # Native pipelines in Windows PowerShell can decode Git's UTF-8 paths using
    # an OEM encoding. Preserve NUL delimiters and UTF-8 explicitly instead.
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = (Get-Command git.exe -ErrorAction Stop).Source
    $start.Arguments = '-c core.longpaths=true -C "' + $Root + '" ' + $Arguments
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false, $true)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { throw 'Timed out enumerating source state for the context fingerprint.' }
        $output = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'Unable to enumerate source state for the context fingerprint.' }
        return $output
    } finally {
        if (-not $process.HasExited) { $process.Kill() }
        $process.Dispose()
    }
}

function Get-ContinuityFingerprint {
    param([string]$Root)
    $head = (Invoke-ContinuityGitText -Root $Root -Arguments 'rev-parse HEAD').Trim()
    $porcelain = Invoke-ContinuityGitText -Root $Root -Arguments 'status --porcelain=v1 -z --untracked-files=all'
    $changed = Invoke-ContinuityGitText -Root $Root -Arguments 'diff --name-only -z HEAD --'
    $untracked = Invoke-ContinuityGitText -Root $Root -Arguments 'ls-files -z --others --exclude-standard'
    $index = Invoke-ContinuityGitText -Root $Root -Arguments 'ls-files --stage -z'
    $pathSet = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($relative in (($changed + $untracked).Split([char]0))) {
        if ($relative.Length -gt 0) { [void]$pathSet.Add($relative) }
    }
    $paths = @($pathSet)
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add('fingerprint-v2')
    $parts.Add("head=$head")
    $parts.Add($porcelain)
    $parts.Add($index)
    # Hash every existing path in one process, including Unicode/space names.
    # A failed batch is not a deletion and must not silently degrade to success.
    $batch = @($paths | Where-Object {
        Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf
    })
    $hashes = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
    if ($batch.Count -gt 0) {
        $result = Invoke-ContinuityHashBatch -Root $Root -Paths $batch
        $values = @($result.Hashes)
        if ($result.ExitCode -ne 0 -or $values.Count -ne $batch.Count) {
            throw 'Unable to hash source files for the context fingerprint; source state may have changed during capture.'
        }
        for ($i = 0; $i -lt $batch.Count; $i++) {
            if ([string]$values[$i] -cnotmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') { throw 'Invalid source hash in context fingerprint.' }
            $hashes[[string]$batch[$i]] = [string]$values[$i]
        }
    }
    foreach ($relative in $paths) {
        $parts.Add($relative)
        if ($hashes.ContainsKey([string]$relative)) {
            $parts.Add($hashes[[string]$relative])
        } else {
            $parts.Add('DELETED')
        }
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        # Length-prefix fields because porcelain itself contains NUL and file
        # names can contain newlines on supported filesystems.
        $payload = [System.Text.Encoding]::UTF8.GetBytes((($parts | ForEach-Object { [string]$_.Length + ':' + $_ }) -join ''))
        return (-join ($sha.ComputeHash($payload) | ForEach-Object { $_.ToString('x2') }))
    } finally {
        $sha.Dispose()
    }
}

function Read-ContinuityJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-ContinuityValidationLedgerPath {
    param([string]$Repository)
    return "validation/repositories/$Repository.json"
}

function Get-ContinuityValidationLedger {
    param([string]$ContextRoot, [string]$Repository)
    $relative = Get-ContinuityValidationLedgerPath -Repository $Repository
    $ledger = Read-ContinuityJson -Path (Join-Path $ContextRoot $relative)
    if ($null -eq $ledger) {
        return [pscustomobject]@{ schemaVersion = 2; repository = $Repository; entries = @() }
    }
    if ([int]$ledger.schemaVersion -ne 2 -or [string]$ledger.repository -ne $Repository) { throw "Validation ledger is invalid for repository $Repository." }
    return $ledger
}

function Get-ContinuityPrevious {
    param([string]$ContextRoot, [string]$Repository)
    $manifest = Read-ContinuityJson -Path (Join-Path $ContextRoot "manifests/repositories/$Repository.json")
    if ($null -eq $manifest -or -not ($manifest.PSObject.Properties.Name -contains 'continuity') -or $null -eq $manifest.continuity) {
        return [pscustomobject]@{ Manifest = $manifest; Workstream = $null }
    }
    $relative = [string]$manifest.continuity.workstreamPath
    $workstream = $null
    if (-not [string]::IsNullOrWhiteSpace($relative)) {
        # Persisted manifests are input, not permission to read/remove arbitrary
        # files. Bind the canonical bucket and filename to their declared ID.
        $id = Assert-ContinuityId -Value $manifest.continuity.workstreamId -Label 'Previous workstream id'
        $bucket = if ($script:ContinuityTerminalWorkstreamStatuses -contains [string]$manifest.continuity.workstreamStatus) { 'archive' } else { 'active' }
        if ($relative -cne "workstreams/$bucket/$id.json") { throw 'Previous workstream path must match its canonical bucket and id.' }
        $current = [IO.Path]::GetFullPath($ContextRoot)
        foreach ($segment in $relative.Split('/')) {
            $current = Join-Path $current $segment
            if (Test-Path -LiteralPath $current) {
                if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Previous workstream path must not traverse a reparse point.' }
            }
        }
        $workstream = Read-ContinuityJson -Path (Join-Path $ContextRoot $relative)
        if ($null -eq $workstream -or [string]$workstream.id -cne $id -or
            [string]$workstream.status -cne [string]$manifest.continuity.workstreamStatus) { throw 'Previous workstream identity/status does not match its manifest.' }
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$manifest.continuity.workstreamId)) {
        throw 'Previous workstream manifest declares an id without a canonical path.'
    }
    return [pscustomobject]@{ Manifest = $manifest; Workstream = $workstream }
}

function Test-ContinuityWorkstreamUnresolved {
    param([object]$Workstream)
    if ($null -eq $Workstream) { return $false }
    if ($script:ContinuityTerminalWorkstreamStatuses -contains [string]$Workstream.status) { return $false }
    return @($Workstream.items | Where-Object { $script:ContinuityTerminalItemStatuses -notcontains [string]$_.status }).Count -gt 0
}

function Assert-ContinuityWorkstream {
    param([object]$Workstream, [string]$ExpectedRepository, [string]$CheckpointNextAction)
    foreach ($field in @('id', 'title', 'status', 'objective', 'repositories', 'cursor', 'items')) {
        if (-not ($Workstream.PSObject.Properties.Name -contains $field)) { throw "Continuity workstream is missing required field: $field" }
    }
    $workstreamId = Assert-ContinuityId -Value $Workstream.id -Label 'Workstream id'
    if ([string]::IsNullOrWhiteSpace([string]$Workstream.title) -or [string]::IsNullOrWhiteSpace([string]$Workstream.objective)) { throw 'Continuity workstream title/objective must not be empty.' }
    if (@('PROPOSED', 'IN_PROGRESS', 'BLOCKED', 'COMPLETED', 'CANCELLED', 'SUPERSEDED') -notcontains [string]$Workstream.status) { throw 'Continuity workstream status is not allowed.' }

    $repositories = @($Workstream.repositories)
    if ($repositories.Count -eq 0) { throw 'Continuity workstream repositories must be a non-empty array.' }
    $repoIds = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $repositories) {
        $repoIds.Add((Assert-ContinuityId -Value $entry.repository -Label 'Workstream repository'))
        if ([string]::IsNullOrWhiteSpace([string]$entry.role)) { throw 'Continuity workstream repository role must not be empty.' }
    }
    if (@($repoIds | Group-Object | Where-Object Count -gt 1).Count -gt 0) { throw 'Continuity workstream repositories must not contain duplicates.' }
    if ($repoIds -notcontains $ExpectedRepository) { throw 'Tracked workstream must include the active repository in repositories[].' }

    $itemMap = @{}
    foreach ($item in @($Workstream.items)) {
        foreach ($field in @('id', 'title', 'status', 'priority', 'scope', 'acceptanceCriteria', 'dependsOn', 'blockedBy', 'validationRequirements', 'notes')) {
            if (-not ($item.PSObject.Properties.Name -contains $field)) { throw "Continuity work item is missing required field: $field" }
        }
        $itemId = Assert-ContinuityId -Value $item.id -Label 'Work item id'
        if ($itemMap.ContainsKey($itemId)) { throw "Duplicate continuity work item id: $itemId" }
        if ([string]::IsNullOrWhiteSpace([string]$item.title)) { throw "Work item $itemId title must not be empty." }
        if (@('PENDING', 'IN_PROGRESS', 'BLOCKED', 'COMPLETED', 'CANCELLED', 'SUPERSEDED') -notcontains [string]$item.status) { throw "Work item $itemId status is not allowed." }
        if (@('CRITICAL', 'HIGH', 'MEDIUM', 'LOW') -notcontains [string]$item.priority) { throw "Work item $itemId priority is not allowed." }
        foreach ($field in @('scope', 'acceptanceCriteria', 'dependsOn', 'blockedBy', 'validationRequirements', 'notes')) {
            Assert-ContinuityStringArray -Value $item.$field -Label "Work item $itemId $field" | Out-Null
        }
        $itemMap[$itemId] = $item
    }
    foreach ($itemId in @($itemMap.Keys)) {
        $item = $itemMap[$itemId]
        foreach ($reference in @($item.dependsOn) + @($item.blockedBy)) {
            if (-not $itemMap.ContainsKey([string]$reference)) { throw "Work item $itemId references unknown work item: $reference" }
            if ([string]$reference -eq $itemId) { throw "Work item $itemId must not depend on or block itself." }
        }
        if ([string]$item.status -eq 'BLOCKED' -and @($item.blockedBy).Count -eq 0) { throw "Blocked work item $itemId must declare blockedBy item ids." }
    }

    $visiting = @{}
    $visited = @{}
    function Visit-ContinuityDependency {
        param([string]$ItemId)
        if ($visited.ContainsKey($ItemId)) { return }
        if ($visiting.ContainsKey($ItemId)) { throw "Workstream $workstreamId contains a dependency cycle at $ItemId." }
        $visiting[$ItemId] = $true
        foreach ($dependency in @($itemMap[$ItemId].dependsOn)) { Visit-ContinuityDependency -ItemId ([string]$dependency) }
        $visiting.Remove($ItemId)
        $visited[$ItemId] = $true
    }
    foreach ($itemId in @($itemMap.Keys)) { Visit-ContinuityDependency -ItemId $itemId }

    $cursor = $Workstream.cursor
    foreach ($field in @('currentItemId', 'lastCompletedItemId', 'phase', 'lastCompletedAction', 'nextAction')) {
        if (-not ($cursor.PSObject.Properties.Name -contains $field)) { throw "Continuity cursor is missing required field: $field" }
    }
    if ([string]::IsNullOrWhiteSpace([string]$cursor.nextAction)) { throw 'Continuity cursor nextAction must not be empty.' }
    if ([string]$cursor.nextAction -ne $CheckpointNextAction) { throw 'Continuity cursor nextAction must match checkpoint nextAction exactly.' }
    $currentItemId = $null
    if ($null -ne $cursor.currentItemId) {
        $currentItemId = Assert-ContinuityId -Value $cursor.currentItemId -Label 'Continuity cursor currentItemId'
        if (-not $itemMap.ContainsKey($currentItemId)) { throw 'Continuity cursor currentItemId does not reference a work item.' }
        if (@('IN_PROGRESS', 'BLOCKED') -notcontains [string]$itemMap[$currentItemId].status) { throw 'Continuity cursor currentItemId must reference an IN_PROGRESS or BLOCKED item.' }
    }
    if ($null -ne $cursor.lastCompletedItemId) {
        $lastCompletedItemId = Assert-ContinuityId -Value $cursor.lastCompletedItemId -Label 'Continuity cursor lastCompletedItemId'
        if (-not $itemMap.ContainsKey($lastCompletedItemId) -or [string]$itemMap[$lastCompletedItemId].status -ne 'COMPLETED') { throw 'Continuity cursor lastCompletedItemId must reference a COMPLETED item.' }
    }
    $unresolved = @($itemMap.Values | Where-Object { $script:ContinuityTerminalItemStatuses -notcontains [string]$_.status })
    if (@('IN_PROGRESS', 'BLOCKED') -contains [string]$Workstream.status -and $unresolved.Count -gt 0 -and $null -eq $currentItemId) { throw 'Active/blocked workstream with unresolved items must declare cursor.currentItemId.' }
    if ($script:ContinuityTerminalWorkstreamStatuses -contains [string]$Workstream.status) {
        if ($unresolved.Count -gt 0) { throw 'Terminal workstream cannot retain unresolved work items.' }
        if ($null -ne $currentItemId) { throw 'Terminal workstream cursor.currentItemId must be null.' }
    }
}

function Assert-ContinuityValidationEntries {
    param([object]$Entries, [string]$ExpectedRepository)
    if ($null -eq $Entries -or $Entries -is [string]) { throw 'Continuity validationLedger must be an array.' }
    $seen = @{}
    foreach ($entry in @($Entries)) {
        foreach ($field in @('id', 'kind', 'result', 'repository', 'scope', 'summary', 'timestamp', 'command', 'evidenceRefs')) {
            if (-not ($entry.PSObject.Properties.Name -contains $field)) { throw "Continuity validation entry is missing required field: $field" }
        }
        $entryId = Assert-ContinuityId -Value $entry.id -Label 'Validation entry id'
        if ($seen.ContainsKey($entryId)) { throw "Duplicate continuity validation entry id: $entryId" }
        $seen[$entryId] = $true
        if ((Assert-ContinuityId -Value $entry.repository -Label 'Validation repository') -ne $ExpectedRepository) { throw 'Checkpoint may only append validation ledger entries for the active repository.' }
        if (@('PASS', 'FAIL', 'INCONCLUSIVE', 'SKIPPED') -notcontains [string]$entry.result) { throw "Validation entry $entryId result is not allowed." }
        foreach ($field in @('kind', 'scope', 'summary', 'timestamp')) {
            if ([string]::IsNullOrWhiteSpace([string]$entry.$field)) { throw "Validation entry $entryId $field must not be empty." }
        }
        if ($null -ne $entry.command -and $entry.command -isnot [string]) { throw "Validation entry $entryId command must be a string or null." }
        Assert-ContinuityStringArray -Value $entry.evidenceRefs -Label "Validation entry $entryId evidenceRefs" | Out-Null
    }
}

function Assert-ContinuityCheckpointShape {
    param([object]$Checkpoint, [string]$ExpectedRepository)
    if ([int]$Checkpoint.schemaVersion -eq 1) {
        if ($Checkpoint.PSObject.Properties.Name -contains 'continuity') { throw 'schemaVersion 1 checkpoints must not include continuity; use schemaVersion 2.' }
        return
    }
    if ([int]$Checkpoint.schemaVersion -ne 2) { throw 'Unsupported checkpoint schemaVersion.' }
    if (-not ($Checkpoint.PSObject.Properties.Name -contains 'continuity') -or $null -eq $Checkpoint.continuity) { throw 'schemaVersion 2 checkpoint requires continuity object.' }
    $mode = [string]$Checkpoint.continuity.mode
    if (@('snapshot', 'tracked') -notcontains $mode) { throw 'Continuity mode must be snapshot or tracked.' }
    Assert-ContinuityValidationEntries -Entries $Checkpoint.continuity.validationLedger -ExpectedRepository $ExpectedRepository
    if ($mode -eq 'snapshot') {
        if ($null -ne $Checkpoint.continuity.workstream) { throw 'Snapshot continuity mode must use workstream: null.' }
        if (@('PROPOSED', 'IN_PROGRESS', 'IMPLEMENTED', 'BLOCKED') -contains [string]$Checkpoint.status) { throw 'Active checkpoint statuses require tracked continuity mode.' }
    } else {
        if ($null -eq $Checkpoint.continuity.workstream) { throw 'Tracked continuity mode requires a workstream object.' }
        Assert-ContinuityWorkstream -Workstream $Checkpoint.continuity.workstream -ExpectedRepository $ExpectedRepository -CheckpointNextAction ([string]$Checkpoint.nextAction)
    }
}

function Get-ContinuityGlobalWorkstream {
    param([string]$ContextRoot, [string]$Id, [string]$Repository)
    $safeId = Assert-ContinuityId -Value $Id -Label 'Workstream id'
    $found = @()
    foreach ($bucket in @('active','archive')) {
        $relative = "workstreams/$bucket/$safeId.json"
        $path = [IO.Path]::GetFullPath($ContextRoot)
        foreach ($segment in $relative.Split('/')) {
            $path = Join-Path $path $segment
            if ((Test-Path -LiteralPath $path) -and
                (((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                throw 'Global workstream path must not traverse a reparse point.'
            }
        }
        $record = Read-ContinuityJson -Path $path
        if ($null -eq $record) { continue }
        if ([string]$record.id -cne $safeId -or (Get-ContinuityWorkstreamRelativePath -Workstream $record) -cne $relative) {
            throw 'Global workstream identity/status does not match its canonical path.'
        }
        # A globally stable ID has one publishing owner. Other repositories may
        # be collaborators, but their own checkpoint cannot silently replace it.
        if (-not ($record.PSObject.Properties.Name -contains 'lastCheckpoint') -or
            [string]$record.lastCheckpoint.repository -cne $Repository) {
            throw 'Global workstream id belongs to another checkpoint owner; preserve it and use an explicitly reviewed distinct id.'
        }
        $found += $record
    }
    if ($found.Count -gt 1) { throw 'Global workstream id exists in both active and archive; manual reconciliation is required.' }
    if ($found.Count -eq 1) { return $found[0] }
    return $null
}

function Assert-ContinuityTransition {
    param([string]$ContextRoot, [object]$Checkpoint, [string]$Repository)
    if ([int]$Checkpoint.schemaVersion -eq 2) {
        $ledger = Get-ContinuityValidationLedger -ContextRoot $ContextRoot -Repository $Repository
        $existing = @{}
        foreach ($entry in @($ledger.entries)) { $existing[[string]$entry.id] = $true }
        $duplicates = @($Checkpoint.continuity.validationLedger | Where-Object { $existing.ContainsKey([string]$_.id) } | ForEach-Object { [string]$_.id })
        if ($duplicates.Count -gt 0) { throw ('Validation ledger entry ids are immutable and already exist: ' + ($duplicates -join ', ')) }
    }
    $previous = Get-ContinuityPrevious -ContextRoot $ContextRoot -Repository $Repository
    if ([int]$Checkpoint.schemaVersion -eq 2 -and $null -ne $Checkpoint.continuity.workstream) {
        $target = Get-ContinuityGlobalWorkstream -ContextRoot $ContextRoot -Id ([string]$Checkpoint.continuity.workstream.id) -Repository $Repository
        if ($null -ne $target) {
            if ($null -ne $previous.Workstream -and [string]$previous.Workstream.id -cne [string]$target.id -and
                (Test-ContinuityWorkstreamUnresolved -Workstream $previous.Workstream)) {
                throw 'Cannot switch workstream ids while the previous tracked workstream still has unresolved items.'
            }
            # Even after a snapshot or a different cursor, the global record is
            # transition authority for this ID; an old archive cannot be reopened.
            $previous = [pscustomobject]@{ Manifest = $previous.Manifest; Workstream = $target }
        }
    }
    if ($null -eq $previous.Workstream) { return }
    if ([int]$Checkpoint.schemaVersion -eq 1) {
        if (Test-ContinuityWorkstreamUnresolved -Workstream $previous.Workstream) { throw 'Legacy schemaVersion 1 checkpoint would lose an active tracked workstream; use schemaVersion 2 and carry every work item forward.' }
        return
    }
    $current = $Checkpoint.continuity.workstream
    if ($null -eq $current) {
        if (Test-ContinuityWorkstreamUnresolved -Workstream $previous.Workstream) { throw 'Snapshot checkpoint would lose an active tracked workstream; close or supersede its work items explicitly first.' }
        return
    }
    if ([string]$current.id -ne [string]$previous.Workstream.id) {
        if (Test-ContinuityWorkstreamUnresolved -Workstream $previous.Workstream) { throw 'Cannot switch workstream ids while the previous tracked workstream still has unresolved items.' }
        return
    }
    if ($script:ContinuityTerminalWorkstreamStatuses -contains [string]$previous.Workstream.status -and [string]$current.status -ne [string]$previous.Workstream.status) { throw 'Terminal workstream status is immutable; start a new workstream instead of reopening it.' }
    $currentMap = @{}
    foreach ($item in @($current.items)) { $currentMap[[string]$item.id] = $item }
    foreach ($beforeItem in @($previous.Workstream.items)) {
        $itemId = [string]$beforeItem.id
        if (-not $currentMap.ContainsKey($itemId)) { throw "Checkpoint would lose existing work items: $itemId" }
        $before = [string]$beforeItem.status
        $after = [string]$currentMap[$itemId].status
        if ($script:ContinuityItemTransitions[$before] -notcontains $after) { throw "Invalid work item status transition for $itemId`: $before -> $after" }
    }
}

function Get-ContinuityWorkstreamRelativePath {
    param([object]$Workstream)
    $bucket = if ($script:ContinuityTerminalWorkstreamStatuses -contains [string]$Workstream.status) { 'archive' } else { 'active' }
    return "workstreams/$bucket/$($Workstream.id).json"
}

function Write-ContinuityJson {
    param([string]$Path, [object]$Value, [int]$Depth = 20)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Write-ContinuityState {
    param([string]$ContextRoot, [object]$Checkpoint, [object]$MemberState, [string]$GeneratedAt, [string]$SessionRelative)
    if ([int]$Checkpoint.schemaVersion -ne 2) { return [pscustomobject]@{ Metadata = $null; Paths = @() } }
    $repository = [string]$Checkpoint.repository
    # Validate previous provenance before any ledger or Workstream writes.
    $previous = Get-ContinuityPrevious -ContextRoot $ContextRoot -Repository $repository
    $previousRelative = if ($null -ne $previous.Manifest -and $previous.Manifest.PSObject.Properties.Name -contains 'continuity') { [string]$previous.Manifest.continuity.workstreamPath } else { '' }
    $ledgerRelative = Get-ContinuityValidationLedgerPath -Repository $repository
    $ledger = Get-ContinuityValidationLedger -ContextRoot $ContextRoot -Repository $repository
    $entries = @()
    foreach ($entry in @($ledger.entries)) { $entries += $entry }
    foreach ($source in @($Checkpoint.continuity.validationLedger)) {
        $stored = [ordered]@{}
        foreach ($property in $source.PSObject.Properties) { $stored[$property.Name] = $property.Value }
        $stored['recordedAt'] = $GeneratedAt
        $stored['validFor'] = [ordered]@{ head = $MemberState.head; dirty = $MemberState.dirty; fingerprint = $MemberState.fingerprint }
        $entries += [pscustomobject]$stored
    }
    $ledgerOut = [ordered]@{ schemaVersion = 2; repository = $repository; entries = @($entries); updatedAt = $GeneratedAt }
    Write-ContinuityJson -Path (Join-Path $ContextRoot $ledgerRelative) -Value $ledgerOut
    $paths = @($ledgerRelative)

    $workstream = $Checkpoint.continuity.workstream
    $workstreamRelative = $null
    if ($null -ne $workstream) {
        $workstreamRelative = Get-ContinuityWorkstreamRelativePath -Workstream $workstream
        $storedWorkstream = [ordered]@{}
        foreach ($property in $workstream.PSObject.Properties) { $storedWorkstream[$property.Name] = $property.Value }
        $storedWorkstream['schemaVersion'] = 2
        $storedWorkstream['updatedAt'] = $GeneratedAt
        $storedWorkstream['lastCheckpoint'] = [ordered]@{ repository = $repository; branch = $MemberState.branch; head = $MemberState.head; dirty = $MemberState.dirty; fingerprint = $MemberState.fingerprint; session = $SessionRelative }
        Write-ContinuityJson -Path (Join-Path $ContextRoot $workstreamRelative) -Value $storedWorkstream
        $paths += $workstreamRelative
    }
    # Only the same Workstream's explicit active -> archive transition retires
    # its active file. Completed archives remain durable after future snapshots
    # and new Workstreams; changing the current cursor never deletes history.
    if ($null -ne $previous.Workstream -and $null -ne $workstream -and
        [string]$previous.Workstream.id -ceq [string]$workstream.id -and
        $previousRelative -ceq "workstreams/active/$($workstream.id).json" -and
        $workstreamRelative -ceq "workstreams/archive/$($workstream.id).json") {
        $previousPath = Join-Path $ContextRoot $previousRelative
        if (Test-Path -LiteralPath $previousPath -PathType Leaf) {
            Remove-Item -LiteralPath $previousPath -Force
            $paths += $previousRelative
        }
    }
    $metadata = [ordered]@{
        schemaVersion = 2
        mode = [string]$Checkpoint.continuity.mode
        workstreamId = if ($null -ne $workstream) { [string]$workstream.id } else { $null }
        workstreamStatus = if ($null -ne $workstream) { [string]$workstream.status } else { $null }
        workstreamPath = $workstreamRelative
        currentItemId = if ($null -ne $workstream) { $workstream.cursor.currentItemId } else { $null }
        validationLedgerPath = $ledgerRelative
    }
    return [pscustomobject]@{ Metadata = [pscustomobject]$metadata; Paths = @($paths) }
}

function Get-ContinuityRuntime {
    param([string]$ContextRoot, [string]$Repository, [object]$MemberState)
    $previous = Get-ContinuityPrevious -ContextRoot $ContextRoot -Repository $Repository
    $meta = if ($null -ne $previous.Manifest -and $previous.Manifest.PSObject.Properties.Name -contains 'continuity') { $previous.Manifest.continuity } else { $null }
    $ledger = Get-ContinuityValidationLedger -ContextRoot $ContextRoot -Repository $Repository
    $fresh = 0
    $stale = 0
    foreach ($entry in @($ledger.entries)) {
        if ($entry.PSObject.Properties.Name -contains 'validFor' -and [string]$entry.validFor.fingerprint -eq [string]$MemberState.fingerprint) { $fresh++ } else { $stale++ }
    }
    $mostRecent = if (@($ledger.entries).Count -gt 0) { @($ledger.entries)[-1] } else { $null }
    return [pscustomobject]@{
        mode = if ($null -ne $meta) { [string]$meta.mode } else { 'legacy' }
        workstreamId = if ($null -ne $meta) { $meta.workstreamId } else { $null }
        workstreamStatus = if ($null -ne $meta) { $meta.workstreamStatus } else { $null }
        currentItemId = if ($null -ne $meta) { $meta.currentItemId } else { $null }
        workstreamPath = if ($null -ne $meta) { $meta.workstreamPath } else { $null }
        workstream = $previous.Workstream
        validation = [pscustomobject]@{ path = (Get-ContinuityValidationLedgerPath -Repository $Repository); entries = @($ledger.entries).Count; freshEntries = $fresh; staleEntries = $stale; mostRecent = $mostRecent }
    }
}

function Convert-ContinuityWorkstreamToMarkdown {
    param([object]$Workstream)
    if ($null -eq $Workstream) { return '' }
    $cursor = $Workstream.cursor
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Workstream - $($Workstream.title)")
    $lines.Add('')
    $lines.Add("ID: ``$($Workstream.id)``")
    $lines.Add("Status: ``$($Workstream.status)``")
    $lines.Add("Current item: ``$(if ($null -ne $cursor.currentItemId) { $cursor.currentItemId } else { 'none' })``")
    $lines.Add("Last completed item: ``$(if ($null -ne $cursor.lastCompletedItemId) { $cursor.lastCompletedItemId } else { 'none' })``")
    $lines.Add("Phase: ``$(if ($null -ne $cursor.phase) { $cursor.phase } else { 'unspecified' })``")
    $lines.Add('')
    $lines.Add('## Objective')
    $lines.Add('')
    $lines.Add([string]$Workstream.objective)
    $lines.Add('')
    $lines.Add('## Execution Cursor')
    $lines.Add('')
    $lines.Add("Last completed action: $(if ($null -ne $cursor.lastCompletedAction) { $cursor.lastCompletedAction } else { 'None.' })")
    $lines.Add("Next action: $($cursor.nextAction)")
    $lines.Add('')
    $lines.Add('## Work Items')
    $lines.Add('')
    if (@($Workstream.items).Count -eq 0) { $lines.Add('- None.') }
    foreach ($item in @($Workstream.items)) {
        $lines.Add("### $($item.id) - $($item.title)")
        $lines.Add('')
        $lines.Add("Status: ``$($item.status)`` | Priority: ``$($item.priority)``")
        $lines.Add("Depends on: $(if (@($item.dependsOn).Count -gt 0) { @($item.dependsOn) -join ', ' } else { 'none' })")
        $lines.Add("Blocked by: $(if (@($item.blockedBy).Count -gt 0) { @($item.blockedBy) -join ', ' } else { 'none' })")
        $lines.Add('')
        $lines.Add('Acceptance criteria:')
        $lines.Add((Convert-ToBullets -Items @($item.acceptanceCriteria)))
        $lines.Add('')
        $lines.Add('Validation requirements:')
        $lines.Add((Convert-ToBullets -Items @($item.validationRequirements)))
        $lines.Add('')
    }
    return ($lines -join "`r`n")
}
