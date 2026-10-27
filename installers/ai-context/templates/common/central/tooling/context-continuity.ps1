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

function Get-ContinuityNormalizedMemberRoot {
    param([string]$MemberRoot)
    if ([string]::IsNullOrWhiteSpace($MemberRoot)) { throw 'An explicit owning MemberRoot is required for Worktree continuity.' }
    return [IO.Path]::GetFullPath($MemberRoot).TrimEnd([char[]]@([char]92,[char]47)).Replace([char]92,[char]47).ToLowerInvariant()
}

function Get-ContinuityRecordPaths {
    param([string]$Repository, [string]$MemberRoot)
    $repo = Assert-ContinuityId -Value $Repository -Label 'Repository id'
    $normalized = Get-ContinuityNormalizedMemberRoot -MemberRoot $MemberRoot
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $id = 'wt-' + $digest.Substring(0,32)
    return [pscustomobject]@{
        WorktreeId = $id
        Manifest = "manifests/worktrees/$repo/$id.json"
        State = "state/worktrees/$repo/$id.md"
        Handoff = "handoffs/worktrees/$repo/$id.md"
        LegacyManifest = "manifests/repositories/$repo.json"
        LegacyState = "state/repositories/$repo.md"
        LegacyHandoff = "handoffs/repositories/$repo.md"
    }
}

function Get-ContinuityTransferFileHash {
    param([string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-ContinuityTransferSource {
    param([string]$ContextRoot, [string]$Repository, [object]$Transfer)
    $source = $Transfer.source
    if ([int]$Transfer.schemaVersion -ne 2 -or [string]$Transfer.kind -cne 'qbit-ai-context-transfer' -or
        [string]$Transfer.repository -cne $Repository -or [string]$Transfer.transferId -cnotmatch '^[0-9a-f]{32}$' -or
        [string]$source.contextHead -cnotmatch '^[0-9a-f]{40,64}$' -or [string]$source.memberHead -cnotmatch '^[0-9a-f]{40,64}$' -or
        [string]$source.worktreeFingerprint -cnotmatch '^[0-9a-f]{64}$') { throw 'Offline transfer source provenance is invalid.' }
    $paths = Get-ContinuityRecordPaths -Repository $Repository -MemberRoot ([string]$source.memberWorktree)
    if ([string]$source.worktreeId -cne $paths.WorktreeId) { throw 'Offline transfer source Worktree identity is invalid.' }
    if ($null -eq $source.receipt) {
        if ($null -ne $Transfer.continuity) { throw 'Offline transfer continuity requires an owning source receipt.' }
        $anchoredReceipt = (Invoke-ContinuityGitText -Root $ContextRoot -Arguments ('ls-tree --name-only '+[string]$source.contextHead+' -- '+$paths.Manifest)).Trim()
        if ($anchoredReceipt) { throw 'Offline transfer omitted an existing owning source receipt; preserve its continuation.' }
        return [pscustomobject]@{ Manifest=$null; Paths=$paths }
    }
    $receipt = $source.receipt
    if ([string]$receipt.manifest -cne $paths.Manifest -or [string]$receipt.state -cne $paths.State -or [string]$receipt.handoff -cne $paths.Handoff -or
        [string]$receipt.session -cnotmatch '^sessions/[0-9]{4}/[0-9]{2}/[A-Za-z0-9._-]+\.md$') { throw 'Offline transfer source receipt paths are invalid.' }
    $anchor = [string]$source.contextHead
    foreach ($pair in @(@($paths.Manifest,'manifestBlob'),@($paths.State,'stateBlob'),@($paths.Handoff,'handoffBlob'),@([string]$receipt.session,'sessionBlob'))) {
        $blob = (Invoke-ContinuityGitText -Root $ContextRoot -Arguments ("rev-parse ${anchor}:"+$pair[0])).Trim()
        if ($blob -cne [string]$receipt.($pair[1])) { throw 'Offline transfer source receipt blob does not match its Git anchor.' }
        # Anchored source records must still be present, unchanged. An unrelated
        # sibling summary may advance; it is never the transfer authority.
        Invoke-ContinuityGitText -Root $ContextRoot -Arguments ("diff --quiet $anchor -- "+$pair[0]) | Out-Null
        $currentPath = Join-Path $ContextRoot $pair[0]
        if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) { throw 'Offline transfer source receipt is missing.' }
    }
    $manifestText = Invoke-ContinuityGitText -Root $ContextRoot -Arguments ("show ${anchor}:"+$paths.Manifest)
    $manifest = $manifestText | ConvertFrom-Json
    if ([string]$manifest.repository -cne $Repository -or [string]$manifest.worktreeId -cne $paths.WorktreeId -or
        (Get-ContinuityNormalizedMemberRoot -MemberRoot ([string]$manifest.memberWorktree)) -cne (Get-ContinuityNormalizedMemberRoot -MemberRoot ([string]$source.memberWorktree)) -or
        [string]$manifest.receiptPaths.manifest -cne $paths.Manifest -or [string]$manifest.receiptPaths.state -cne $paths.State -or [string]$manifest.receiptPaths.handoff -cne $paths.Handoff -or
        [string]$manifest.commit -cne [string]$source.memberHead -or [string]$manifest.branch -cne [string]$source.memberBranch -or
        [string]$manifest.worktreeFingerprint -cne [string]$source.worktreeFingerprint -or [string]$manifest.session -cne [string]$receipt.session -or
        [string]$manifest.checkpointId -cne [string]$receipt.checkpointId -or [string]$manifest.checkpointPayloadSha256 -cne [string]$receipt.payloadSha256) { throw 'Offline transfer source Manifest identity does not match its provenance.' }
    $meta = if ($manifest.PSObject.Properties.Name -contains 'continuity') { $manifest.continuity } else { $null }
    if (($meta | ConvertTo-Json -Depth 12 -Compress) -cne ($Transfer.continuity | ConvertTo-Json -Depth 12 -Compress)) { throw 'Offline transfer continuity does not match the anchored owning Manifest.' }
    $session = Invoke-ContinuityGitText -Root $ContextRoot -Arguments ("show ${anchor}:"+[string]$receipt.session)
    if (-not $session.Contains('Checkpoint ID: '+[string]$manifest.checkpointId) -or
        -not $session.Contains('Checkpoint payload SHA256: '+[string]$manifest.checkpointPayloadSha256)) { throw 'Offline transfer Session does not match the owning checkpoint.' }
    return [pscustomobject]@{ Manifest=$manifest; Paths=$paths }
}

function New-ContinuityOfflineOwnershipTransfer {
    param([string]$ContextRoot, [string]$Repository, [string]$MemberRoot, [object]$Transfer, [string]$ManifestPath, [string]$BundlePath, [switch]$Importing)
    $source = Get-ContinuityTransferSource -ContextRoot $ContextRoot -Repository $Repository -Transfer $Transfer
    $target = Get-ContinuityRecordPaths -Repository $Repository -MemberRoot $MemberRoot
    if ($Importing) {
        $memberHead = (Invoke-ContinuityGitText -Root $MemberRoot -Arguments 'rev-parse HEAD').Trim()
        $memberBranch = (Invoke-ContinuityGitText -Root $MemberRoot -Arguments 'rev-parse --abbrev-ref HEAD').Trim()
        if ($memberHead -cne [string]$Transfer.source.memberHead -or $memberBranch -cne [string]$Transfer.source.memberBranch -or
            (Get-ContinuityFingerprint -Root $MemberRoot) -cne [string]$Transfer.source.worktreeFingerprint) { throw 'Offline transfer target source HEAD/branch/fingerprint does not match the exported owner.' }
    }
    if ($null -eq $source.Manifest -or $target.WorktreeId -ceq $source.Paths.WorktreeId) { return $null }
    if ($Importing -and (Test-Path -LiteralPath (Join-Path $ContextRoot $target.Manifest))) { throw 'Offline transfer cannot replace an established target Worktree receipt.' }
    return [pscustomobject][ordered]@{
        schemaVersion=1; kind='qbit-ai-context-worktree-transfer'; transferId=[string]$Transfer.transferId; repository=$Repository
        transferManifestSha256=(Get-ContinuityTransferFileHash -Path $ManifestPath); bundleSha256=(Get-ContinuityTransferFileHash -Path $BundlePath)
        sourceContextHead=[string]$Transfer.source.contextHead; sourceMemberHead=[string]$Transfer.source.memberHead; sourceMemberBranch=[string]$Transfer.source.memberBranch
        sourceMemberWorktree=[string]$Transfer.source.memberWorktree; sourceWorktreeId=$source.Paths.WorktreeId
        sourceManifest=$source.Paths.Manifest; sourceSession=[string]$source.Manifest.session
        targetMemberWorktree=[IO.Path]::GetFullPath($MemberRoot); targetWorktreeId=$target.WorktreeId
    }
}

function Get-ContinuityOfflineOwnershipTransfer {
    param([string]$ContextRoot, [string]$Repository, [string]$MemberRoot)
    $markerPath = Join-Path $MemberRoot '.ai-bridge/context-offline.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $null }
    $marker = Read-ContinuityJson -Path $markerPath
    if ([int]$marker.schemaVersion -eq 1) { return $null }
    if ([int]$marker.schemaVersion -ne 2 -or [string]$marker.kind -cne 'qbit-ai-context-offline' -or
        [string]$marker.repository -cne $Repository -or -not ($marker.PSObject.Properties.Name -contains 'ownershipTransfer')) { throw 'Offline transfer marker mapping is invalid.' }
    $transferRoot = Join-Path $MemberRoot '.ai-bridge/context-transfer'
    $manifestPath = Join-Path $transferRoot 'manifest.json'; $bundlePath = Join-Path $transferRoot 'context.bundle'
    foreach ($path in @($markerPath,$transferRoot,$manifestPath,$bundlePath)) {
        if (-not (Test-Path -LiteralPath $path) -or (((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Offline transfer mapping requires retained regular transfer files.' }
    }
    $transfer = Read-ContinuityJson -Path $manifestPath
    if ([string]$marker.sourceContextHead -cnotmatch '^[0-9a-f]{40,64}$' -or
        [string]$marker.currentContextHead -cnotmatch '^[0-9a-f]{40,64}$' -or
        [string]$marker.contextBranch -notmatch '^[A-Za-z0-9._/-]+$' -or [string]$marker.contextBranch -match '\.\.|//|^/|/$') { throw 'Offline transfer marker Git identity is invalid.' }
    # The launcher checks exact marker HEAD before invocation and advances it
    # after a successful offline commit. Runtime generation inside that commit
    # must also accept its non-destructive descendant before the marker update.
    Invoke-ContinuityGitText -Root $ContextRoot -Arguments ('merge-base --is-ancestor '+[string]$marker.currentContextHead+' HEAD') | Out-Null
    if ([string]$transfer.project -cne [string]$marker.project -or [string]$transfer.contextBranch -cne [string]$marker.contextBranch -or
        [string]$transfer.contextRemote -cne [string]$marker.contextRemote -or [string]$transfer.source.contextHead -cne [string]$marker.sourceContextHead -or
        [string]$transfer.bundle.sha256 -cne [string]$marker.bundleSha256 -or
        (Get-ContinuityTransferFileHash -Path $bundlePath) -cne [string]$marker.bundleSha256 -or (Get-Item -LiteralPath $bundlePath).Length -ne [long]$transfer.bundle.bytes) { throw 'Offline transfer mapping does not match its retained bundle/manifest.' }
    Invoke-ContinuityGitText -Root $MemberRoot -Arguments ('bundle verify "'+$bundlePath+'"') | Out-Null
    $heads = (Invoke-ContinuityGitText -Root $MemberRoot -Arguments ('bundle list-heads "'+$bundlePath+'" refs/heads/'+[string]$marker.contextBranch)).Trim() -split '\s+'
    if ($heads.Count -ne 2 -or $heads[0] -cne [string]$marker.sourceContextHead -or $heads[1] -cne ('refs/heads/'+[string]$marker.contextBranch)) { throw 'Offline transfer bundle branch does not match its source anchor.' }
    Invoke-ContinuityGitText -Root $ContextRoot -Arguments ('merge-base --is-ancestor '+[string]$marker.sourceContextHead+' HEAD') | Out-Null
    $expected = New-ContinuityOfflineOwnershipTransfer -ContextRoot $ContextRoot -Repository $Repository -MemberRoot $MemberRoot -Transfer $transfer -ManifestPath $manifestPath -BundlePath $bundlePath
    $actual = $marker.ownershipTransfer
    if (($null -eq $expected) -ne ($null -eq $actual)) { throw 'Offline transfer ownership mapping is missing or unexpected.' }
    if ($null -ne $expected) {
        if (@($actual.PSObject.Properties).Count -ne @($expected.PSObject.Properties).Count) { throw 'Offline transfer ownership mapping shape is invalid.' }
        foreach ($property in $expected.PSObject.Properties) {
            if (-not ($actual.PSObject.Properties.Name -contains $property.Name) -or [string]$actual.($property.Name) -cne [string]$property.Value) { throw 'Offline transfer ownership mapping does not match its verified source and target.' }
        }
    }
    return $expected
}

function Get-ContinuityPrevious {
    param([string]$ContextRoot, [string]$Repository, [string]$MemberRoot)
    $paths = Get-ContinuityRecordPaths -Repository $Repository -MemberRoot $MemberRoot
    $transfer = Get-ContinuityOfflineOwnershipTransfer -ContextRoot $ContextRoot -Repository $Repository -MemberRoot $MemberRoot
    $receiptMemberRoot = $MemberRoot
    foreach ($relative in @($paths.Manifest,$paths.LegacyManifest,$paths.State,$paths.Handoff,'workstreams/active')) {
        $checkedPath = [IO.Path]::GetFullPath($ContextRoot)
        foreach ($segment in $relative.Split('/')) {
            $checkedPath = Join-Path $checkedPath $segment
            if ((Test-Path -LiteralPath $checkedPath) -and
                (((Get-Item -LiteralPath $checkedPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Worktree Manifest path must not traverse a reparse point.' }
        }
    }
    $manifest = Read-ContinuityJson -Path (Join-Path $ContextRoot $paths.Manifest)
    $source = 'scoped'
    if ($null -eq $manifest) {
        # A sibling's latest summary is not evidence that this Worktree never
        # checkpointed. Preserve incomplete owning records rather than permit
        # a fresh snapshot to silently drop its unresolved continuation.
        foreach ($relative in @($paths.State,$paths.Handoff)) {
            if (Test-Path -LiteralPath (Join-Path $ContextRoot $relative)) {
                throw 'Scoped Worktree Context Manifest is missing while owning continuity records remain; preserve them and recover the authoritative receipt.'
            }
        }
        $activeRoot = Join-Path $ContextRoot 'workstreams/active'
        if (Test-Path -LiteralPath $activeRoot -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $activeRoot -Filter '*.json' -File)) {
                if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Active Workstream path must not traverse a reparse point.' }
                $active = Read-ContinuityJson -Path $file.FullName
                if ($null -eq $active -or -not ($active.PSObject.Properties.Name -contains 'lastCheckpoint') -or $null -eq $active.lastCheckpoint) { continue }
                $owner = $active.lastCheckpoint
                if ([string]$owner.repository -cne $Repository) { continue }
                $matchesId = ($owner.PSObject.Properties.Name -contains 'worktreeId') -and [string]$owner.worktreeId -ceq $paths.WorktreeId
                $matchesRoot = ($owner.PSObject.Properties.Name -contains 'memberWorktree') -and
                    -not [string]::IsNullOrWhiteSpace([string]$owner.memberWorktree) -and
                    (Get-ContinuityNormalizedMemberRoot -MemberRoot ([string]$owner.memberWorktree)) -ceq (Get-ContinuityNormalizedMemberRoot -MemberRoot $MemberRoot)
                if ($matchesId -or $matchesRoot) {
                    throw 'Scoped Worktree Context Manifest is missing while an owning active Workstream remains; preserve it and recover the authoritative receipt.'
                }
            }
        }
        $source = 'none'
        if ($null -ne $transfer) {
            $manifest = Read-ContinuityJson -Path (Join-Path $ContextRoot $transfer.sourceManifest)
            $source = 'offline-transfer'
            $receiptMemberRoot = [string]$transfer.sourceMemberWorktree
        }
        $legacy = Read-ContinuityJson -Path (Join-Path $ContextRoot $paths.LegacyManifest)
        if ($null -eq $manifest -and $null -ne $legacy) {
            if ($legacy.PSObject.Properties.Name -contains 'memberWorktree' -and -not [string]::IsNullOrWhiteSpace([string]$legacy.memberWorktree)) {
                if ((Get-ContinuityNormalizedMemberRoot -MemberRoot ([string]$legacy.memberWorktree)) -ceq (Get-ContinuityNormalizedMemberRoot -MemberRoot $MemberRoot)) {
                    if (($legacy.PSObject.Properties.Name -contains 'worktreeId') -or ($legacy.PSObject.Properties.Name -contains 'receiptPaths')) {
                        throw 'Scoped Worktree Context Manifest is missing; a repository summary cannot replace the authoritative receipt.'
                    }
                    $manifest = $legacy; $source = 'bound-legacy'
                }
            } elseif ($legacy.PSObject.Properties.Name -contains 'continuity' -and $null -ne $legacy.continuity -and
                [string]$legacy.continuity.mode -eq 'tracked' -and $script:ContinuityTerminalWorkstreamStatuses -notcontains [string]$legacy.continuity.workstreamStatus) {
                throw 'Legacy active Context has no owning Worktree binding; preserve it and perform an explicitly reviewed mapping before continuation.'
            }
        }
    }
    if ($null -ne $manifest) {
        if ([string]$manifest.repository -cne $Repository -or
            (Get-ContinuityNormalizedMemberRoot -MemberRoot ([string]$manifest.memberWorktree)) -cne (Get-ContinuityNormalizedMemberRoot -MemberRoot $receiptMemberRoot)) { throw 'Worktree Context Manifest owner does not match the selected repository/root.' }
        if ($source -eq 'scoped' -and ([string]$manifest.worktreeId -cne $paths.WorktreeId -or
            [string]$manifest.receiptPaths.manifest -cne $paths.Manifest -or [string]$manifest.receiptPaths.state -cne $paths.State -or [string]$manifest.receiptPaths.handoff -cne $paths.Handoff)) { throw 'Worktree Context Manifest receipt paths do not match the canonical owning scope.' }
    }
    if ($null -eq $manifest -or -not ($manifest.PSObject.Properties.Name -contains 'continuity') -or $null -eq $manifest.continuity) {
        return [pscustomobject]@{ Manifest = $manifest; Workstream = $null; ReceiptSource = $source }
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
        if (-not ($workstream.PSObject.Properties.Name -contains 'lastCheckpoint') -or [string]$workstream.lastCheckpoint.repository -cne $Repository) { throw 'Previous workstream checkpoint owner does not match its Manifest.' }
        if ([string]$workstream.lastCheckpoint.session -cne [string]$manifest.session) { throw 'Previous workstream Session does not match its Manifest.' }
        if ($workstream.lastCheckpoint.PSObject.Properties.Name -contains 'memberWorktree') {
            $receiptPaths = Get-ContinuityRecordPaths -Repository $Repository -MemberRoot $receiptMemberRoot
            if ((Get-ContinuityNormalizedMemberRoot -MemberRoot ([string]$workstream.lastCheckpoint.memberWorktree)) -cne (Get-ContinuityNormalizedMemberRoot -MemberRoot $receiptMemberRoot) -or [string]$workstream.lastCheckpoint.worktreeId -cne $receiptPaths.WorktreeId) { throw 'Previous workstream belongs to another owning Worktree.' }
        }
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$manifest.continuity.workstreamId)) {
        throw 'Previous workstream manifest declares an id without a canonical path.'
    }
    return [pscustomobject]@{ Manifest = $manifest; Workstream = $workstream; ReceiptSource = $source }
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
    param([string]$ContextRoot, [string]$Id, [string]$Repository, [string]$MemberRoot)
    $ownerPaths = Get-ContinuityRecordPaths -Repository $Repository -MemberRoot $MemberRoot
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
        if ($record.lastCheckpoint.PSObject.Properties.Name -contains 'memberWorktree') {
            if ((Get-ContinuityNormalizedMemberRoot -MemberRoot ([string]$record.lastCheckpoint.memberWorktree)) -cne (Get-ContinuityNormalizedMemberRoot -MemberRoot $MemberRoot) -or
                [string]$record.lastCheckpoint.worktreeId -cne $ownerPaths.WorktreeId) {
                $transfer = Get-ContinuityOfflineOwnershipTransfer -ContextRoot $ContextRoot -Repository $Repository -MemberRoot $MemberRoot
                if ($null -eq $transfer -or [string]$record.lastCheckpoint.repository -cne [string]$transfer.repository -or
                    [string]$record.lastCheckpoint.worktreeId -cne [string]$transfer.sourceWorktreeId -or
                    (Get-ContinuityNormalizedMemberRoot -MemberRoot ([string]$record.lastCheckpoint.memberWorktree)) -cne (Get-ContinuityNormalizedMemberRoot -MemberRoot ([string]$transfer.sourceMemberWorktree)) -or
                    [string]$record.lastCheckpoint.session -cne [string]$transfer.sourceSession) { throw 'Global workstream id belongs to another owning Worktree; preserve it and use an explicitly reviewed distinct id.' }
            }
        } else {
            $bound = Get-ContinuityPrevious -ContextRoot $ContextRoot -Repository $Repository -MemberRoot $MemberRoot
            if ($null -eq $bound.Manifest -or [string]$bound.Manifest.session -cne [string]$record.lastCheckpoint.session) { throw 'Legacy global workstream owner is unbound; preserve it for an explicitly reviewed Worktree mapping.' }
        }
        $found += $record
    }
    if ($found.Count -gt 1) { throw 'Global workstream id exists in both active and archive; manual reconciliation is required.' }
    if ($found.Count -eq 1) { return $found[0] }
    return $null
}

function Assert-ContinuityTransition {
    param([string]$ContextRoot, [object]$Checkpoint, [string]$Repository, [string]$MemberRoot)
    if ([int]$Checkpoint.schemaVersion -eq 2) {
        $ledger = Get-ContinuityValidationLedger -ContextRoot $ContextRoot -Repository $Repository
        $existing = @{}
        foreach ($entry in @($ledger.entries)) { $existing[[string]$entry.id] = $true }
        $duplicates = @($Checkpoint.continuity.validationLedger | Where-Object { $existing.ContainsKey([string]$_.id) } | ForEach-Object { [string]$_.id })
        if ($duplicates.Count -gt 0) { throw ('Validation ledger entry ids are immutable and already exist: ' + ($duplicates -join ', ')) }
    }
    $previous = Get-ContinuityPrevious -ContextRoot $ContextRoot -Repository $Repository -MemberRoot $MemberRoot
    if ([int]$Checkpoint.schemaVersion -eq 2 -and $null -ne $Checkpoint.continuity.workstream) {
        $target = Get-ContinuityGlobalWorkstream -ContextRoot $ContextRoot -Id ([string]$Checkpoint.continuity.workstream.id) -Repository $Repository -MemberRoot $MemberRoot
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
    param([string]$ContextRoot, [object]$Checkpoint, [object]$MemberState, [string]$GeneratedAt, [string]$SessionRelative, [string]$MemberRoot)
    if ([int]$Checkpoint.schemaVersion -ne 2) { return [pscustomobject]@{ Metadata = $null; Paths = @() } }
    $repository = [string]$Checkpoint.repository
    # Validate previous provenance before any ledger or Workstream writes.
    $pathsForOwner = Get-ContinuityRecordPaths -Repository $repository -MemberRoot $MemberRoot
    $previous = Get-ContinuityPrevious -ContextRoot $ContextRoot -Repository $repository -MemberRoot $MemberRoot
    $previousRelative = if ($null -ne $previous.Manifest -and $previous.Manifest.PSObject.Properties.Name -contains 'continuity') { [string]$previous.Manifest.continuity.workstreamPath } else { '' }
    $ledgerRelative = Get-ContinuityValidationLedgerPath -Repository $repository
    $ledger = Get-ContinuityValidationLedger -ContextRoot $ContextRoot -Repository $repository
    $entries = @()
    foreach ($entry in @($ledger.entries)) { $entries += $entry }
    foreach ($source in @($Checkpoint.continuity.validationLedger)) {
        $stored = [ordered]@{}
        foreach ($property in $source.PSObject.Properties) { $stored[$property.Name] = $property.Value }
        $stored['recordedAt'] = $GeneratedAt
        $stored['validFor'] = [ordered]@{ head = $MemberState.head; dirty = $MemberState.dirty; fingerprint = $MemberState.fingerprint; memberWorktree = $MemberRoot; worktreeId = $pathsForOwner.WorktreeId }
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
        $storedWorkstream['lastCheckpoint'] = [ordered]@{ repository = $repository; memberWorktree = $MemberRoot; worktreeId = $pathsForOwner.WorktreeId; branch = $MemberState.branch; head = $MemberState.head; dirty = $MemberState.dirty; fingerprint = $MemberState.fingerprint; session = $SessionRelative }
        $ownershipTransfer = Get-ContinuityOfflineOwnershipTransfer -ContextRoot $ContextRoot -Repository $repository -MemberRoot $MemberRoot
        if ($null -ne $ownershipTransfer) { $storedWorkstream['lastCheckpoint']['ownershipTransfer'] = $ownershipTransfer }
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
    param([string]$ContextRoot, [string]$Repository, [object]$MemberState, [string]$MemberRoot)
    $ownerPaths = Get-ContinuityRecordPaths -Repository $Repository -MemberRoot $MemberRoot
    $previous = Get-ContinuityPrevious -ContextRoot $ContextRoot -Repository $Repository -MemberRoot $MemberRoot
    $meta = if ($null -ne $previous.Manifest -and $previous.Manifest.PSObject.Properties.Name -contains 'continuity') { $previous.Manifest.continuity } else { $null }
    $ledger = Get-ContinuityValidationLedger -ContextRoot $ContextRoot -Repository $Repository
    $fresh = 0
    $stale = 0
    foreach ($entry in @($ledger.entries)) {
        if ($entry.PSObject.Properties.Name -contains 'validFor' -and [string]$entry.validFor.fingerprint -eq [string]$MemberState.fingerprint -and
            $entry.validFor.PSObject.Properties.Name -contains 'worktreeId' -and [string]$entry.validFor.worktreeId -ceq $ownerPaths.WorktreeId) { $fresh++ } else { $stale++ }
    }
    $ownEntries = @($ledger.entries | Where-Object {
        $_.PSObject.Properties.Name -contains 'validFor' -and $_.validFor.PSObject.Properties.Name -contains 'worktreeId' -and
        [string]$_.validFor.worktreeId -ceq $ownerPaths.WorktreeId
    })
    $mostRecent = if ($ownEntries.Count -gt 0) { $ownEntries[-1] } else { $null }
    return [pscustomobject]@{
        mode = if ($null -ne $meta) { [string]$meta.mode } else { 'legacy' }
        workstreamId = if ($null -ne $meta) { $meta.workstreamId } else { $null }
        workstreamStatus = if ($null -ne $meta) { $meta.workstreamStatus } else { $null }
        currentItemId = if ($null -ne $meta) { $meta.currentItemId } else { $null }
        workstreamPath = if ($null -ne $meta) { $meta.workstreamPath } else { $null }
        workstream = $previous.Workstream
        worktreeId = $ownerPaths.WorktreeId
        receiptPaths = if ($previous.ReceiptSource -eq 'offline-transfer') { $previous.Manifest.receiptPaths } else { [pscustomobject]@{manifest=$ownerPaths.Manifest;state=$ownerPaths.State;handoff=$ownerPaths.Handoff} }
        receiptSource = $previous.ReceiptSource
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
