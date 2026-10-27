param([string]$FixtureRoot = (Join-Path ([IO.Path]::GetTempPath()) 'qbit-context-recovery-agent'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot '../../install.ps1'
$hostExe = (Get-Command powershell -ErrorAction Stop).Source
$runRoot = Join-Path $FixtureRoot ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
$passed = 0
$results = New-Object Collections.Generic.List[object]
function WriteUtf8([string]$Path,[string]$Text) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($false)))
}
function Git([string]$Root,[string[]]$GitArguments) {
    $old=$ErrorActionPreference; $ErrorActionPreference='Continue'
    try { $output=@(& git.exe -c core.longpaths=true -C $Root @GitArguments 2>&1); $code=$LASTEXITCODE }
    finally { $ErrorActionPreference=$old }
    if($code -ne 0){throw ('Fixture Git failed: '+($GitArguments -join ' ')+': '+($output -join "`n"))}
    return ($output -join "`n").Trim()
}
function InitRepo([string]$Root) {
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    Git $Root @('init','-q','-b','main') | Out-Null
    Git $Root @('config','user.name','Recovery Fixture') | Out-Null
    Git $Root @('config','user.email','recovery@example.invalid') | Out-Null
    WriteUtf8 (Join-Path $Root 'source.txt') "source`n"
    Git $Root @('add','source.txt') | Out-Null
    Git $Root @('commit','-q','-m','bootstrap') | Out-Null
}
function Run([string]$Script,[string[]]$Arguments) {
    $old=$ErrorActionPreference; $ErrorActionPreference='Continue'
    try { $output=@(& $hostExe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1); $code=$LASTEXITCODE }
    finally { $ErrorActionPreference=$old }
    $text=$output -join "`n"
    Add-Content -LiteralPath (Join-Path $runRoot 'commands.log') -Value ($Script+' '+($Arguments -join ' ')+"`nexit="+$code+"`n"+$text)
    return [pscustomobject]@{Code=$code;Text=$text}
}
function Assert([bool]$Ok,[string]$Message) { if(-not $Ok){throw $Message} }
function Case([string]$Name,[scriptblock]$Body) {
    & $Body
    $script:passed++
    $results.Add([pscustomobject]@{name=$Name;result='PASS'})
    Write-Host ('PASS '+$Name)
}
function Payload([string]$Scope) {
    $value=[ordered]@{schemaVersion=2;repository='recovery-member';scope=$Scope;status='VALIDATED';objective='Verify durable checkpoint recovery.';confirmedFindings=@('Installed lifecycle and real Git.');decisions=@();rejectedApproaches=@();validation=@('Recovery integration fixture.');openQuestions=@();nextAction='Review recovery evidence.';continuity=@{mode='snapshot';workstream=$null;validationLedger=@()}}
    WriteUtf8 $checkpoint ($value | ConvertTo-Json -Depth 12)
}
function ReadJournal { Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json }
function RemoteHead { Git $bare @('rev-parse','refs/heads/main') }
function Sessions { @(Git $cache @('ls-tree','-r','--name-only','HEAD','--','sessions') | Where-Object {$_} | ForEach-Object {$_ -split "`n"} | Where-Object {$_ -match '^sessions/\d{4}/\d{2}/'}) }
$exit=0
try {
    $bare=Join-Path $runRoot 'context.git'
    New-Item -ItemType Directory -Force -Path $bare | Out-Null
    Git $bare @('init','--bare','-q','--initial-branch=main') | Out-Null
    $central=Join-Path $runRoot 'central'
    InitRepo $central
    $installed=Run $installer @('-Operation','install','-Mode','central','-Target',$central,'-ProjectId','recovery','-RepositoryId','recovery-context','-ContextRemote',$bare)
    Assert ($installed.Code -eq 0) 'Central installation failed.'
    WriteUtf8 (Join-Path $central 'repositories/repositories.yaml') "project: recovery`nrepositories:`n  recovery-member:`n    role: test-member`n"
    Git $central @('add','--all') | Out-Null
    Git $central @('commit','-q','-m','installed central') | Out-Null
    Git $central @('remote','add','origin',$bare) | Out-Null
    Git $central @('push','-q','-u','origin','main') | Out-Null
    $member=Join-Path $runRoot 'member'
    InitRepo $member
    $installed=Run $installer @('-Operation','install','-Mode','member','-Target',$member,'-ProjectId','recovery','-RepositoryId','recovery-member','-ContextRemote',$bare)
    Assert ($installed.Code -eq 0) 'Member installation failed.'
    $launcher=Join-Path $member '.ai/context/context.ps1'
    $cache=Join-Path $member '.ai/context/cache/project-context'
    $checkpoint=Join-Path $member '.ai-bridge/context-checkpoint.json'
    $journalPath=Join-Path $member '.ai-bridge/context-checkpoint-pending.json'
    Case 'installed Start and ignored recovery storage' {
        $started=Run $launcher @('start')
        Assert ($started.Code -eq 0) $started.Text
        Git $cache @('config','user.name','Recovery Fixture') | Out-Null
        Git $cache @('config','user.email','recovery@example.invalid') | Out-Null
        WriteUtf8 (Join-Path $member '.ai-bridge/ignored-probe') 'probe'
        Assert ((Git $member @('check-ignore','.ai-bridge/ignored-probe')) -eq '.ai-bridge/ignored-probe') 'Recovery journal directory is not ignored.'
    }
    Case 'push failure preserves immutable committed operation' {
        WriteUtf8 (Join-Path $bare 'hooks/pre-receive') "#!/bin/sh`nexit 1`n"
        Payload 'push-retry'
        $script:originalPayload=[IO.File]::ReadAllText($checkpoint)
        $before=RemoteHead
        $failed=Run $launcher @('checkpoint')
        Assert ($failed.Code -ne 0) 'Rejected push reported success.'
        $receipt=ReadJournal
        Assert ($receipt.phase -eq 'committed' -and $receipt.commit -eq (Git $cache @('rev-parse','HEAD'))) 'Committed checkpoint identity was not retained.'
        Assert ((RemoteHead) -eq $before -and (Test-Path $checkpoint)) 'Rejected publication lost payload or changed remote.'
        $script:pendingId=$receipt.id
        $script:pendingSession=$receipt.session
    }
    Case 'different pending payload blocks without replacement' {
        $before=[IO.File]::ReadAllText($journalPath)
        Payload 'different-operation'
        $failed=Run $launcher @('checkpoint')
        Assert ($failed.Code -ne 0) 'Different operation overwrote pending checkpoint.'
        Assert ([IO.File]::ReadAllText($journalPath) -ceq $before) 'Pending journal changed on rejected retry.'
        WriteUtf8 $checkpoint $originalPayload
    }
    Case 'same operation retry publishes one checkpoint' {
        Remove-Item -LiteralPath (Join-Path $bare 'hooks/pre-receive')
        $before=@(Sessions).Count
        $retry=Run $launcher @('checkpoint')
        Assert ($retry.Code -eq 0) $retry.Text
        $receipt=ReadJournal
        Assert ($receipt.phase -eq 'completed' -and $receipt.id -eq $pendingId -and $receipt.session -eq $pendingSession) 'Retry replaced logical checkpoint identity.'
        Assert (@(Sessions).Count -eq $before -and (RemoteHead) -eq $receipt.commit) 'Retry generated a duplicate session or did not publish.'
    }
    Case 'completed identical payload is idempotent' {
        $before=RemoteHead
        WriteUtf8 $checkpoint $originalPayload
        $retry=Run $launcher @('checkpoint')
        Assert ($retry.Code -eq 0 -and (RemoteHead) -eq $before) $retry.Text
    }
    Case 'interruption between commit and journal update recovers exact commit' {
        $value=ReadJournal
        $before=RemoteHead
        $value.phase='prepared'
        $value.commit=''
        WriteUtf8 $journalPath ($value|ConvertTo-Json -Depth 20)
        WriteUtf8 $checkpoint $originalPayload
        $retry=Run $launcher @('checkpoint')
        Assert ($retry.Code -eq 0 -and (ReadJournal).phase -eq 'completed' -and (RemoteHead) -eq $before) $retry.Text
    }
    Case 'superseded checkpoint receipt cannot replay as current' {
        $oldJournal=[IO.File]::ReadAllText($journalPath)
        Payload 'newer-member-checkpoint'
        $newer=Run $launcher @('checkpoint')
        Assert ($newer.Code -eq 0) $newer.Text
        $newJournal=[IO.File]::ReadAllText($journalPath)
        WriteUtf8 $journalPath $oldJournal
        WriteUtf8 $checkpoint $originalPayload
        $failed=Run $launcher @('checkpoint')
        Assert ($failed.Code -ne 0 -and (Test-Path $checkpoint)) 'Superseded receipt reported current success or discarded payload.'
        WriteUtf8 $journalPath $newJournal
        Remove-Item -LiteralPath $checkpoint
    }
    Case 'UTF8 without BOM checkpoint preserves Unicode decisions' {
        Payload 'unicode-roundtrip'
        $value=Get-Content $checkpoint -Raw -Encoding UTF8 | ConvertFrom-Json
        $expected=[string][char]0x0628+[char]0x0644+[char]0x0648+[char]0x0637+' '+[char]0x4E2D+[char]0x6587
        $value.objective=$expected
        $value.decisions=@($expected)
        WriteUtf8 $checkpoint ($value|ConvertTo-Json -Depth 12)
        $result=Run $launcher @('checkpoint')
        Assert ($result.Code -eq 0) $result.Text
        $session=Get-Content (Join-Path $cache (ReadJournal).session) -Raw -Encoding UTF8
        $handoff=Get-Content (Join-Path $cache 'handoffs/repositories/recovery-member.md') -Raw -Encoding UTF8
        Assert ($session.Contains($expected) -and $handoff.Contains($expected)) 'Unicode checkpoint content was corrupted.'
    }
    Case 'commit failure preserves prepared files for guarded retry' {
        WriteUtf8 (Join-Path $cache '.git/hooks/pre-commit') "#!/bin/sh`nexit 1`n"
        Payload 'commit-retry'
        $failed=Run $launcher @('checkpoint')
        Assert ($failed.Code -ne 0 -and (ReadJournal).phase -eq 'prepared') 'Commit failure did not preserve prepared operation.'
        $script:preparedPayload=[IO.File]::ReadAllText($checkpoint)
        $script:preparedJournal=[IO.File]::ReadAllText($journalPath)
        $script:preparedId=(ReadJournal).id
    }
    Case 'unrelated cache change blocks prepared retry and survives' {
        WriteUtf8 (Join-Path $cache 'unrelated-user.txt') 'must survive'
        $failed=Run $launcher @('checkpoint')
        Assert ($failed.Code -ne 0) 'Prepared retry accepted unrelated dirty file.'
        Assert ([IO.File]::ReadAllText((Join-Path $cache 'unrelated-user.txt')) -eq 'must survive') 'Unrelated file was changed.'
        Assert ([IO.File]::ReadAllText($journalPath) -ceq $preparedJournal) 'Rejected retry changed journal.'
        Remove-Item -LiteralPath (Join-Path $cache 'unrelated-user.txt')
    }
    Case 'forged journal cannot authorize unrelated dirty path' {
        WriteUtf8 (Join-Path $cache 'unrelated-user.txt') 'must survive unstaged'
        $saved=[IO.File]::ReadAllText($journalPath)
        $value=ReadJournal
        $value.files+=@([pscustomobject]@{path='unrelated-user.txt';blob=(Git $cache @('hash-object','unrelated-user.txt'))})
        WriteUtf8 $journalPath ($value|ConvertTo-Json -Depth 20)
        $failed=Run $launcher @('checkpoint')
        Assert ($failed.Code -ne 0 -and $failed.Text -match 'unauthorized file scope') 'Forged journal expanded checkpoint commit scope.'
        Assert ((Git $cache @('diff','--cached','--name-only')) -notmatch 'unrelated-user.txt') 'Forged journal staged unrelated user file.'
        Assert ([IO.File]::ReadAllText((Join-Path $cache 'unrelated-user.txt')) -eq 'must survive unstaged') 'Unrelated file was overwritten.'
        WriteUtf8 $journalPath $saved
        Remove-Item -LiteralPath (Join-Path $cache 'unrelated-user.txt')
    }
    Case 'prepared retry commits unchanged recorded blobs only' {
        Remove-Item -LiteralPath (Join-Path $cache '.git/hooks/pre-commit')
        $retry=Run $launcher @('checkpoint')
        Assert ($retry.Code -eq 0) $retry.Text
        Assert ((ReadJournal).id -eq $preparedId -and (ReadJournal).phase -eq 'completed') 'Prepared retry duplicated logical operation.'
    }
    Case 'source changed during publication fails closed and preserves recovery' {
        $source=Join-Path $member 'source.txt'
        $savedSource=[IO.File]::ReadAllText($source)
        $shellSource=$source.Replace('\','/')
        WriteUtf8 (Join-Path $bare 'hooks/pre-receive') ("#!/bin/sh`nprintf changed > '"+$shellSource+"'`nexit 0`n")
        Payload 'source-race'
        $failed=Run $launcher @('checkpoint')
        Assert ($failed.Code -ne 0 -and $failed.Text -match 'source changed during checkpoint') 'Source race was not rejected.'
        Assert ([IO.File]::ReadAllText($source) -eq 'changed' -and (Test-Path $checkpoint)) 'Source race recovery discarded user changes or payload.'
        $before=RemoteHead
        Remove-Item -LiteralPath (Join-Path $bare 'hooks/pre-receive')
        WriteUtf8 $source $savedSource
        $retry=Run $launcher @('checkpoint')
        Assert ($retry.Code -eq 0 -and (RemoteHead) -eq $before) $retry.Text
    }
    Case 'new ignored payload during publication is preserved and rejected' {
        Payload 'payload-race'
        $savedPayload=[IO.File]::ReadAllText($checkpoint)
        $shellCheckpoint=$checkpoint.Replace('\','/')
        WriteUtf8 (Join-Path $bare 'hooks/pre-receive') ("#!/bin/sh`nprintf '%s' '{changed-payload}' > '"+$shellCheckpoint+"'`nexit 0`n")
        $failed=Run $launcher @('checkpoint')
        Assert ($failed.Code -ne 0 -and $failed.Text -match 'checkpoint payload changed during publication') 'Ignored checkpoint payload race did not fail closed.'
        Assert ([IO.File]::ReadAllText($checkpoint) -eq '{changed-payload}' -and (ReadJournal).phase -eq 'committed') 'New durable decisions or prior journal were discarded.'
        $before=RemoteHead
        Remove-Item -LiteralPath (Join-Path $bare 'hooks/pre-receive')
        WriteUtf8 $checkpoint $savedPayload
        $retry=Run $launcher @('checkpoint')
        Assert ($retry.Code -eq 0 -and (RemoteHead) -eq $before) $retry.Text
    }
    Case 'publication success runtime failure preserves payload and recovers' {
        $runtime=Join-Path $member '.ai-bridge/context-runtime.json'
        Remove-Item -LiteralPath $runtime
        New-Item -ItemType Directory -Path $runtime | Out-Null
        Payload 'runtime-retry'
        $failed=Run $launcher @('checkpoint')
        Assert ($failed.Code -ne 0 -and (Test-Path $checkpoint)) 'Runtime failure discarded recovery payload.'
        $receipt=ReadJournal
        Assert ((RemoteHead) -eq $receipt.commit -and $receipt.phase -eq 'committed') 'Published checkpoint receipt was not preserved.'
        $before=RemoteHead
        Remove-Item -LiteralPath $runtime
        $retry=Run $launcher @('checkpoint')
        Assert ($retry.Code -eq 0 -and (RemoteHead) -eq $before) $retry.Text
    }
    Case 'exclusive checkpoint lock fails closed and releases safely' {
        Payload 'lock-retry'
        $lock=[IO.File]::Open((Join-Path $cache '.git/qbit-context-checkpoint.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try { $failed=Run $launcher @('checkpoint'); Assert ($failed.Code -ne 0 -and $failed.Text -match 'another checkpoint owns') 'Concurrent cache writer was not blocked.' }
        finally { $lock.Dispose() }
        $retry=Run $launcher @('checkpoint')
        Assert ($retry.Code -eq 0) $retry.Text
    }
    Case 'immutable session GUID prevents same-second scope collisions' {
        $clockWrapper=Join-Path $runRoot 'fixed-clock.ps1'
        WriteUtf8 $clockWrapper "param([string]`$Launcher)`nfunction global:Get-Date { [DateTime]::Parse('2026-10-26T12:34:56',[Globalization.CultureInfo]::InvariantCulture) }`n& `$Launcher checkpoint`nexit `$LASTEXITCODE`n"
        Payload 'same-second-scope'
        $first=Run $clockWrapper @($launcher)
        Assert ($first.Code -eq 0) $first.Text
        $firstSession=(ReadJournal).session
        # Completed checkpoints consume their input: recreate a distinct payload
        # with the same scope and fixed clock, preserving the source fingerprint.
        Payload 'same-second-scope'
        $different=Get-Content $checkpoint -Raw -Encoding UTF8|ConvertFrom-Json
        $different.objective='A second distinct milestone with exactly the same clock second.'
        WriteUtf8 $checkpoint ($different|ConvertTo-Json -Depth 12)
        $second=Run $clockWrapper @($launcher)
        Assert ($second.Code -eq 0) $second.Text
        $secondSession=(ReadJournal).session
        Assert ($firstSession -ne $secondSession -and $firstSession.Contains('2026-10-26-123456') -and $secondSession.Contains('2026-10-26-123456')) 'Same-second same-scope sessions collided.'
        $sessions=@(Sessions)
        Assert (@($sessions | Select-Object -Unique).Count -eq $sessions.Count) 'Session paths collided.'
        foreach($session in $sessions){ Assert ($session -match '-[0-9a-f]{32}\.md$') 'Session lacks collision-safe identity.' }
        $manifest=Get-Content (Join-Path $cache 'manifests/repositories/recovery-member.json') -Raw | ConvertFrom-Json
        Assert ($manifest.checkpointId -match '^[0-9a-f]{32}$' -and $manifest.project -eq 'recovery' -and $manifest.memberWorktree -eq $member) 'Manifest lost checkpoint/worktree/project identity.'
    }
    Case 'interrupted preparation fails closed preserving evidence' {
        $manifest=Get-Content (Join-Path $cache 'manifests/repositories/recovery-member.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Payload ([string]$manifest.scope)
        $saved=[IO.File]::ReadAllText($journalPath)
        $value=ReadJournal
        $value.phase='preparing'
        $value.payloadSha256=(Get-FileHash $checkpoint -Algorithm SHA256).Hash.ToLowerInvariant()
        WriteUtf8 $journalPath ($value | ConvertTo-Json -Depth 20)
        $before=RemoteHead
        $failed=Run $launcher @('checkpoint')
        Assert ($failed.Code -ne 0 -and $failed.Text -match 'interrupted checkpoint preparation preserved' -and (Test-Path $checkpoint) -and (RemoteHead) -eq $before) 'Interrupted preparation was overwritten or falsely succeeded.'
        WriteUtf8 $journalPath $saved
    }
    Case 'conflicting writer preserves both histories and pending checkpoint' {
        WriteUtf8 (Join-Path $bare 'hooks/pre-receive') "#!/bin/sh`nexit 1`n"
        Payload 'writer-conflict'
        $failed=Run $launcher @('checkpoint')
        Assert ($failed.Code -ne 0 -and (ReadJournal).phase -eq 'committed') 'Fixture publication was not interrupted.'
        $pending=ReadJournal
        Remove-Item -LiteralPath (Join-Path $bare 'hooks/pre-receive')
        Git $central @('pull','--ff-only','origin','main') | Out-Null
        WriteUtf8 (Join-Path $central 'concurrent-writer.txt') 'independent valid writer'
        Git $central @('add','concurrent-writer.txt') | Out-Null
        Git $central @('commit','-q','-m','concurrent writer') | Out-Null
        Git $central @('push','-q','origin','main') | Out-Null
        $remote=RemoteHead
        $failed=Run $launcher @('checkpoint')
        Assert ($failed.Code -ne 0) 'Divergent writers silently succeeded.'
        Assert ((Git $cache @('rev-parse','HEAD')) -eq $pending.commit -and (RemoteHead) -eq $remote -and (Test-Path $checkpoint)) 'Conflicting histories or pending work were overwritten.'
    }
} catch {
    $exit=1
    $results.Add([pscustomobject]@{name='failure';result='FAIL';detail=$_.Exception.Message})
    Write-Host ('FAIL '+$_.Exception.Message)
} finally {
    $summary=[ordered]@{suite='checkpoint-recovery';powershell=$PSVersionTable.PSVersion.ToString();host=$hostExe;passed=$passed;failed=$exit;skipped=0;exitCode=$exit;fixtureRoot=$runRoot;results=@($results.ToArray())}
    WriteUtf8 (Join-Path $runRoot 'results.json') ($summary | ConvertTo-Json -Depth 12)
    Write-Host ('CHECKPOINT_RECOVERY passed='+$passed+' failed='+$exit+' skipped=0 evidence='+$runRoot)
}
exit $exit
