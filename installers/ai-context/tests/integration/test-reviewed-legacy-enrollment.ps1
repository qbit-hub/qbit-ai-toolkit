#requires -Version 5.1
param([string]$FixtureRoot=(Join-Path ([IO.Path]::GetTempPath()) 'qbit-worktree-receipts'),[ValidateSet('Proposed','TerminalContributor')][string]$LegacyKind='Proposed')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$installerRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$toolkitRoot=(Resolve-Path (Join-Path $installerRoot '../..')).Path
$hostExe=(Get-Command powershell.exe -ErrorAction Stop).Source
$runRoot=Join-Path ([IO.Path]::GetFullPath($FixtureRoot)) ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $runRoot|Out-Null
$started=[DateTimeOffset]::UtcNow;$passed=0;$failed=0;$exitCode=0
$results=New-Object 'Collections.Generic.List[object]'
function WriteUtf8([string]$Path,[string]$Value){New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)|Out-Null;[IO.File]::WriteAllText($Path,$Value,[Text.UTF8Encoding]::new($false))}
function Git([string]$Root,[string[]]$Arguments){
  $old=$ErrorActionPreference;$ErrorActionPreference='Continue'
  try{$out=@(& git.exe -c core.longpaths=true -C $Root @Arguments 2>&1);$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
  if($code -ne 0){throw ('Fixture Git failed: '+($Arguments -join ' ')+': '+($out -join "`n"))}
  return ($out -join "`n").Trim()
}
function Run([string]$Script,[string[]]$Arguments){
  $old=$ErrorActionPreference;$ErrorActionPreference='Continue'
  try{$out=@(& $hostExe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1);$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
  $value=[pscustomobject]@{Code=$code;Text=($out -join "`n")}
  Add-Content -LiteralPath (Join-Path $runRoot 'commands.log') -Encoding UTF8 -Value ($Script+' '+($Arguments -join ' ')+"`nexit="+$code+"`n"+$value.Text)
  return $value
}
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Case([string]$Name,[scriptblock]$Body){& $Body;$script:passed++;$results.Add([pscustomobject]@{name=$Name;result='PASS'});Write-Output ('PASS '+$Name)}
function InitRepo([string]$Root){New-Item -ItemType Directory -Force -Path $Root|Out-Null;Git $Root @('init','-q','-b','main')|Out-Null;Git $Root @('config','user.name','Worktree Fixture')|Out-Null;Git $Root @('config','user.email','worktree@example.invalid')|Out-Null;Git $Root @('config','core.autocrlf','false')|Out-Null;WriteUtf8 (Join-Path $Root 'source.txt') 'initial';Git $Root @('add','source.txt')|Out-Null;Git $Root @('commit','-q','-m','bootstrap')|Out-Null}
function Gate([string]$Root,[string]$Mode){return Run (Join-Path $Root '.ai/context/context-sync-gate.ps1') @('-MemberPath',$Root,'-Mode',$Mode,'-TimeoutSeconds','60')}
function Cache([string]$Root){return Join-Path $Root '.ai/context/cache/project-context'}
function Runtime([string]$Root){return Get-Content -LiteralPath (Join-Path $Root '.ai-bridge/context-runtime.json') -Raw -Encoding UTF8|ConvertFrom-Json}
function ExpectedId([string]$Root){$normalized=[IO.Path]::GetFullPath($Root).TrimEnd('\','/').Replace('\','/').ToLowerInvariant();$sha=[Security.Cryptography.SHA256]::Create();try{$hex=-join($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized))|ForEach-Object{$_.ToString('x2')});return 'wt-'+$hex.Substring(0,32)}finally{$sha.Dispose()}}
function Payload([string]$Root,[string]$Id,[string]$Scope,[bool]$Terminal=$false){
  $next=if($Terminal){'Review archived '+$Id+'.'}else{'Continue '+$Id+'-1.'}
  $cp=[ordered]@{schemaVersion=2;repository='same-member';scope=$Scope;status=if($Terminal){'VALIDATED'}else{'IN_PROGRESS'};objective='Preserve independent continuation across linked Worktrees.';confirmedFindings=@('Real installed lifecycle, linked Git Worktrees and disposable published Context.');decisions=@('Each owning Worktree retains separate receipt and global Workstream ownership.');rejectedApproaches=@('Using latest repository summary as another Worktree receipt.');validation=@('Worktree receipt isolation integration.');openQuestions=@();nextAction=$next;continuity=@{mode='tracked';validationLedger=@();workstream=[ordered]@{id=$Id;title=$Id;status=if($Terminal){'COMPLETED'}else{'IN_PROGRESS'};objective='Continue this exact Worktree.';repositories=@(@{repository='same-member';role='owning-repository'});cursor=@{currentItemId=if($Terminal){$null}else{$Id+'-1'};lastCompletedItemId=if($Terminal){$Id+'-1'}else{$null};phase='verification';lastCompletedAction=$null;nextAction=$next};items=@(@{id=$Id+'-1';title='Preserve owner '+$Id;status=if($Terminal){'COMPLETED'}else{'IN_PROGRESS'};priority='HIGH';scope=@('continuity');acceptanceCriteria=@('Owner receipt remains independently recoverable.');dependsOn=@();blockedBy=@();validationRequirements=@('installed-real-Git');notes=@()})}}}
  WriteUtf8 (Join-Path $Root '.ai-bridge/context-checkpoint.json') ($cp|ConvertTo-Json -Depth 20)
}
function Publish([string]$Root,[string]$Id,[string]$Scope,[bool]$Terminal=$false){$r=Gate $Root 'Start';Assert ($r.Code -eq 0) $r.Text;Payload $Root $Id $Scope $Terminal;$r=Gate $Root 'Checkpoint';Assert ($r.Code -eq 0) $r.Text;$r=Gate $Root 'Verify';Assert ($r.Code -eq 0) $r.Text}
function Manifest([string]$Root){$rt=Runtime $Root;return Get-Content -LiteralPath (Join-Path (Cache $Root) ([string]$rt.continuity.receiptPaths.manifest)) -Raw -Encoding UTF8|ConvertFrom-Json}
function SourceReceipt([string]$Root){$paths=@((Git $Root @('-c','core.quotePath=false','ls-files','--cached','--others','--exclude-standard')) -split "`r?`n"|Where-Object {$_});$paths+=@('.ai-bridge/context-checkpoint.json','.ai-bridge/context-checkpoint-pending.json','.ai-bridge/context-checkpoint-pending.json.previous');$values=[ordered]@{};foreach($p in @($paths|Sort-Object -Unique)){$f=Join-Path $Root $p;$values[$p]=if(Test-Path -LiteralPath $f -PathType Leaf){(Get-FileHash -LiteralPath $f).Hash}else{'ABSENT'}};return ($values|ConvertTo-Json -Compress)}
try{
  $bare=Join-Path $runRoot 'context.git';New-Item -ItemType Directory -Force -Path $bare|Out-Null;Git $bare @('init','--bare','-q','--initial-branch=main')|Out-Null
  $central=Join-Path $runRoot 'central';InitRepo $central;$install=Join-Path $installerRoot 'install.ps1'
  $r=Run $install @('-Operation','install','-Mode','central','-Target',$central,'-ProjectId','isolation','-RepositoryId','isolation-context','-ContextRemote',$bare);Assert ($r.Code -eq 0) $r.Text
  WriteUtf8 (Join-Path $central 'repositories/repositories.yaml') "project: isolation`nrepositories:`n  same-member:`n    role: disposable-owner`n"
  Git $central @('remote','add','origin',$bare)|Out-Null;Git $central @('add','--all')|Out-Null;Git $central @('commit','-q','-m','installed central')|Out-Null;Git $central @('push','-q','-u','origin','main')|Out-Null
  $a=Join-Path $runRoot 'a';$b=Join-Path $runRoot 'b';$c=Join-Path $runRoot 'c';InitRepo $a
  Git $a @('worktree','add','-q','-b','feature/b',$b)|Out-Null;Git $a @('worktree','add','-q','-b','feature/c',$c)|Out-Null
  foreach($root in @($a,$b,$c)) {
    $r=Run $install @('-Operation','install','-Mode','member','-Target',$root,'-ProjectId','isolation','-RepositoryId','same-member','-ContextRemote',$bare);Assert ($r.Code -eq 0) $r.Text
    $r=Gate $root 'Start';Assert ($r.Code -eq 0) $r.Text
    Git (Cache $root) @('config','user.name','Enrollment Fixture')|Out-Null;Git (Cache $root) @('config','user.email','enrollment@example.invalid')|Out-Null
  }
  Payload $a 'LEGACY' 'fixture'
  $cp=Get-Content -LiteralPath (Join-Path $a '.ai-bridge/context-checkpoint.json') -Raw|ConvertFrom-Json
  $old=$cp.continuity.workstream;$old.status='PROPOSED';$old.cursor.currentItemId=$null;$old.cursor.nextAction='Do not resume the proposed evaluation without an explicit user request.';$old.items[0].status='PENDING'
  $old|Add-Member -NotePropertyName schemaVersion -NotePropertyValue 2
  $old|Add-Member -NotePropertyName lastCheckpoint -NotePropertyValue ([ordered]@{repository='same-member';session='sessions/2026/01/legacy.md';branch='historical-unknown-root';head=(Git $a @('rev-parse','HEAD'));dirty=$true;fingerprint='historical'})
  $legacyPaths=@('manifests/repositories/same-member.json','state/repositories/same-member.md','handoffs/repositories/same-member.md')
  if($LegacyKind -eq 'TerminalContributor'){
    $old.status='COMPLETED';$old.cursor.currentItemId=$null;$old.cursor.lastCompletedItemId='LEGACY-1';$old.cursor.nextAction='Preserve completed work; do not reopen historical items.';$old.items[0].status='COMPLETED';$old.lastCheckpoint.repository='other-contributor'
  }
  $wsPath=if($LegacyKind -eq 'TerminalContributor'){'workstreams/archive/LEGACY.json'}else{'workstreams/active/LEGACY.json'};WriteUtf8 (Join-Path $central $wsPath) ($old|ConvertTo-Json -Depth 25)
  $manifest=[ordered]@{schemaVersion=1;repository='same-member';session='sessions/2026/01/legacy.md';continuity=@{schemaVersion=2;mode='tracked';workstreamId='LEGACY';workstreamStatus='PROPOSED';workstreamPath=$wsPath;currentItemId=$null}}
  WriteUtf8 (Join-Path $central $legacyPaths[0]) ($manifest|ConvertTo-Json -Depth 20)
  WriteUtf8 (Join-Path $central $legacyPaths[1]) "Original unknown-root state.`r`nPreserve original unresolved contributor intent.`r`n"
  WriteUtf8 (Join-Path $central $legacyPaths[2]) "Original unknown-root handoff.`r`nDo not migrate or rebind.`r`n"
  WriteUtf8 (Join-Path $central 'sessions/2026/01/legacy.md') 'Original legacy intent; not a current receipt.'
  Git $central @('add','--all')|Out-Null;Git $central @('commit','-q','-m','historical unbound proposed records')|Out-Null;Git $central @('push','-q','origin','main')|Out-Null
  $base=Git $central @('rev-parse','HEAD');$protected=@($legacyPaths|ForEach-Object {[pscustomobject]@{path=$_;blob=(Git $central @('rev-parse',($base+':'+$_)))}})
  $oldBlob=Git $central @('rev-parse',($base+':'+$wsPath))
  $protectedRaw=@{};foreach($path in @($legacyPaths)+@($wsPath)){$protectedRaw[$path]=(Get-FileHash -LiteralPath (Join-Path $central $path)).Hash}
  $disposition=if($LegacyKind -eq 'TerminalContributor'){'historical-contributor-superseded'}else{'preserved-unbound-proposed'}
  $expectedLegacyStatus=[string]$old.status;$expectedLegacyItemStatus=[string]$old.items[0].status
  $recordRelative='references/continuity-reconciliations/same-member.json';$recordPath=Join-Path $central $recordRelative
  $review=[ordered]@{schemaVersion=1;kind='independent-root-enrollment';project='isolation';repository='same-member';contextRemote=$bare;baseCommit=$base;review=@{decision='preserve-unbound-and-enroll-independent-roots';authority='Explicit fixture owner review';provenance=@('Fixture user decision to enroll A and B independently; historical owner stays unknown.')};legacy=$protected;workstream=@{id='LEGACY';sourceCommit=$base;path=$wsPath;blob=$oldBlob;disposition=$disposition};enrollments=@(@{memberWorktree=$a;worktreeId=(ExpectedId $a);scope='enrolled-a';workstreamId='NEW-A'},@{memberWorktree=$b;worktreeId=(ExpectedId $b);scope='enrolled-b';workstreamId='NEW-B'})}
  function CentralPublish([string]$Message){Git $central @('add','--all')|Out-Null;Git $central @('commit','-q','-m',$Message)|Out-Null;Git $central @('push','-q','origin','main')|Out-Null}
  function ProtectedUnchanged([string]$Root){foreach($entry in $protected){Assert ((Git (Cache $Root) @('rev-parse',('HEAD:'+$entry.path))) -ceq $entry.blob) ('Legacy bytes lost: '+$entry.path)};Assert ((Git (Cache $Root) @('rev-parse',('HEAD:'+$wsPath))) -ceq $oldBlob) 'Original Workstream changed';foreach($path in @($legacyPaths)+@($wsPath)){Assert ((Get-FileHash -LiteralPath (Join-Path (Cache $Root) $path)).Hash -ceq $protectedRaw[$path]) ('Original raw legacy bytes changed: '+$path)}}
  Case 'unreviewed original root still fails without source or remote mutation' {
    $before=SourceReceipt $a;$remote=Git $bare @('rev-parse','main');$r=Gate $a 'Start';Assert ($r.Code -eq 3) 'Unbound legacy silently admitted';Assert ((SourceReceipt $a) -ceq $before -and (Git $bare @('rev-parse','main')) -ceq $remote) 'Rejected enrollment changed source or remote'
  }
  Case 'uncommitted local review cannot grant admission' {
    WriteUtf8 (Join-Path (Cache $a) $recordRelative) ($review|ConvertTo-Json -Depth 25)
    $r=Gate $a 'Start';Assert ($r.Code -eq 3) 'Uncommitted review admitted';Remove-Item -LiteralPath (Join-Path (Cache $a) $recordRelative)
  }
  WriteUtf8 $recordPath ($review|ConvertTo-Json -Depth 25);CentralPublish 'review independent roots without historical owner mapping'
  $reviewCommit=Git $central @('rev-parse','HEAD');$reviewBlob=Git $central @('rev-parse',('HEAD:'+$recordRelative))
  foreach($memberRoot in @($a,$b,$c)){Git (Cache $memberRoot) @('config','core.autocrlf','true')|Out-Null}
  Case 'committed exact review admits only listed roots and is not a receipt' {
    $r=Gate $a 'Start';Assert ($r.Code -eq 0) $r.Text;$rt=Runtime $a
    Assert ($rt.continuity.receiptSource -eq 'reviewed-independent-root' -and $null -eq $rt.continuity.workstream) 'Legacy became an owning receipt'
    Assert ($rt.continuity.legacyEvidence.workstream.items[0].status -eq $expectedLegacyItemStatus -and $rt.continuity.legacyEvidence.receipt -eq $false) 'Pending legacy intent lost'
    Assert ([IO.File]::ReadAllText((Join-Path $a '.ai-bridge/context-runtime.md')).Contains([string]$old.cursor.nextAction)) 'Runtime hid preserved intent'
    $r=Gate $a 'Verify';Assert ($r.Code -eq 3) 'Enrollment fabricated published receipt'
    $r=Gate $c 'Start';Assert ($r.Code -eq 3) 'Unlisted sibling admitted'
  }
  Case 'wrong first scope snapshot and old global ID cannot consume enrollment' {
    foreach($mode in @('wrong-scope','snapshot','old-global')) {
      Payload $a 'NEW-A' 'enrolled-a';$file=Join-Path $a '.ai-bridge/context-checkpoint.json';$value=Get-Content $file -Raw|ConvertFrom-Json
      if($mode -eq 'wrong-scope'){$value.scope='another-scope'}
      if($mode -eq 'snapshot'){$value.status='VALIDATED';$value.continuity.mode='snapshot';$value.continuity.workstream=$null}
      if($mode -eq 'old-global'){$value.continuity.workstream.id='LEGACY'}
      WriteUtf8 $file ($value|ConvertTo-Json -Depth 25);$before=SourceReceipt $a;$remote=Git $bare @('rev-parse','main');$r=Gate $a 'Checkpoint';Assert ($r.Code -eq 3) ('Unapproved first checkpoint admitted: '+$mode);Assert ((SourceReceipt $a) -ceq $before -and (Git $bare @('rev-parse','main')) -ceq $remote) 'Rejected checkpoint changed decisions or remote'
    }
  }
  Case 'first genuine scoped checkpoint preserves all unknown legacy bytes' {
    Publish $a 'NEW-A' 'enrolled-a';ProtectedUnchanged $a;$m=Manifest $a
    Assert ($m.legacyPreservation.reviewBlob -ceq $reviewBlob -and $m.legacyPreservation.reviewCommit -ceq $reviewCommit) 'Receipt does not bind immutable review'
    $journal=Get-Content -LiteralPath (Join-Path $a '.ai-bridge/context-checkpoint-pending.json') -Raw|ConvertFrom-Json
    Assert (@($journal.files).Count -eq 9 -and @($journal.legacyPreservation.files).Count -eq 3) 'Ordinary nine-path journal contract was relaxed'
    $changed=(Git (Cache $a) @('diff-tree','--no-commit-id','--name-only','-r',$journal.commit)) -split "`r?`n"
    Assert ($changed.Count -eq 6) 'Protected legacy summaries were rewritten as new scoped output'
    Assert ((Runtime $a).continuity.legacyEvidence.workstream.status -eq $expectedLegacyStatus) 'Proposed intent disappeared after checkpoint'
  }
  Case 'second root and repeated checkpoint preserve original intent and scoped siblings' {
    Publish $b 'NEW-B' 'enrolled-b';ProtectedUnchanged $b
    Publish $a 'NEW-A' 'a-next';ProtectedUnchanged $a
    $r=Gate $b 'Start';Assert ($r.Code -eq 0) $r.Text;$r=Gate $b 'Verify';Assert ($r.Code -eq 0) $r.Text
    Assert ((Runtime $b).continuity.legacyEvidence.workstream.items[0].status -eq $expectedLegacyItemStatus) 'Sibling checkpoint consumed unknown proposed item'
  }
  Case 'scoped receipt loss cannot be bypassed by enrollment' {
    Git $central @('pull','-q','--ff-only','origin','main')|Out-Null;$restore=Git $central @('rev-parse','HEAD');$m=Manifest $a;$path=$m.receiptPaths.manifest
    Git $central @('rm','--',$path)|Out-Null;CentralPublish 'fixture missing owning manifest'
    $r=Gate $a 'Start';Assert ($r.Code -eq 3) 'Enrollment bypassed scoped remnants'
    Git $central @('restore',('--source='+$restore),'--staged','--worktree','--',$path)|Out-Null;CentralPublish 'restore exact owning receipt'
  }
  Case 'protected bytes and immutable review replacement fail closed' {
    foreach($path in @($legacyPaths[1],$wsPath,$recordRelative)) {
      Git $central @('pull','-q','--ff-only','origin','main')|Out-Null;$restore=Git $central @('rev-parse','HEAD');$file=Join-Path $central $path
      [IO.File]::AppendAllText($file,"`n ",[Text.UTF8Encoding]::new($false));CentralPublish 'fixture altered protected evidence'
      $r=Gate $a 'Start';Assert ($r.Code -eq 3) ('Altered protected input admitted: '+$path)
      Git $central @('restore',('--source='+$restore),'--staged','--worktree','--',$path)|Out-Null;CentralPublish 'restore exact reviewed evidence'
    }
    $r=Gate $a 'Start';Assert ($r.Code -eq 0) $r.Text;ProtectedUnchanged $a
  }
  Case 'pending committed operation replay preserves bound review and original bytes' {
    WriteUtf8 (Join-Path $bare 'hooks/pre-receive') "#!/bin/sh`nexit 1`n";Payload $a 'NEW-A' 'a-replay';$file=Join-Path $a '.ai-bridge/context-checkpoint.json';$payload=[IO.File]::ReadAllText($file)
    $r=Gate $a 'Checkpoint';Assert ($r.Code -eq 3) 'Push rejection falsely passed';$jp=Join-Path $a '.ai-bridge/context-checkpoint-pending.json';$j=Get-Content $jp -Raw|ConvertFrom-Json;Assert ($j.phase -eq 'committed') 'Immutable pending operation not retained';$id=$j.id
    $saved=[IO.File]::ReadAllText($jp);$j.legacyPreservation.reviewBlob=('0'*40);WriteUtf8 $jp ($j|ConvertTo-Json -Depth 25)
    $before=SourceReceipt $a;$r=Gate $a 'Checkpoint';Assert ($r.Code -eq 3 -and (SourceReceipt $a) -ceq $before) 'Tampered journal proof was rewritten or accepted';WriteUtf8 $jp $saved
    Remove-Item -LiteralPath (Join-Path $bare 'hooks/pre-receive');$r=Gate $a 'Checkpoint';Assert ($r.Code -eq 0) $r.Text
    Assert ((Get-Content $jp -Raw|ConvertFrom-Json).id -ceq $id) 'Replay manufactured a different checkpoint';ProtectedUnchanged $a
    # Simulate interruption after commit but before the journal update.
    $j=Get-Content $jp -Raw|ConvertFrom-Json;$j.phase='prepared';$j.commit='';WriteUtf8 $jp ($j|ConvertTo-Json -Depth 25);WriteUtf8 $file $payload
    $r=Gate $a 'Checkpoint';Assert ($r.Code -eq 0) $r.Text;ProtectedUnchanged $a
  }
  Case 'old global ID remains unavailable after genuine enrollment publication' {
    Payload $a 'LEGACY' 'old-takeover';$before=SourceReceipt $a;$remote=Git $bare @('rev-parse','main');$r=Gate $a 'Checkpoint';Assert ($r.Code -eq 3 -and (SourceReceipt $a) -ceq $before -and (Git $bare @('rev-parse','main')) -ceq $remote) 'Unknown global owner was rebound'
  }
  Case 'shared validator source and installed gate remain exact' {
    $source=[IO.File]::ReadAllText((Join-Path $installerRoot 'templates/common/central/tooling/context-continuity.ps1'));$gate=[IO.File]::ReadAllText((Join-Path $installerRoot 'templates/common/member/context-sync-gate.ps1'))
    $pattern='(?s)# The same validator.*?# End shared reviewed legacy validator\.'
    Assert ([regex]::Match($source,$pattern).Value -ceq [regex]::Match($gate,$pattern).Value) 'Engine and native independent validator drifted'
    $r=Run $install @('-Operation','verify','-Target',$a,'-Format','json');Assert ($r.Code -eq 0) $r.Text
    $r=Run $install @('-Operation','plan','-Target',$a,'-Format','json');Assert ($r.Code -eq 0 -and @(($r.Text|ConvertFrom-Json).actions).Count -eq 0) 'Installed corrected1.2.9 is not idempotent'
  }
}catch{$failed=1;$exitCode=1;$results.Add([pscustomobject]@{name='failure';result='FAIL';detail=$_.Exception.Message});Write-Output ('FAIL '+$_.Exception.Message)}
finally{
  $hashes=@();foreach($relative in @('templates/common/member/context-sync-gate.ps1','templates/common/central/tooling/context-lifecycle.ps1','templates/common/central/tooling/context-continuity.ps1','tests/integration/test-reviewed-legacy-enrollment.ps1')){$hashes += [ordered]@{path=$relative;sha256=(Get-FileHash -LiteralPath (Join-Path $installerRoot $relative)).Hash}}
  $summary=[ordered]@{suite='reviewed-legacy-enrollment';startUtc=$started.ToString('o');endUtc=[DateTimeOffset]::UtcNow.ToString('o');powershell=$PSVersionTable.PSVersion.ToString();gitVersion=(& git.exe --version);sourceHead=(Git $toolkitRoot @('rev-parse','HEAD'));sourceBranch=(Git $toolkitRoot @('branch','--show-current'));sourceHashes=$hashes;passed=$passed;failed=$failed;executed=($passed+$failed);skipped=0;exitCode=$exitCode;fixtureRoot=$runRoot;results=@($results.ToArray())}
  WriteUtf8 (Join-Path $runRoot 'results.json') ($summary|ConvertTo-Json -Depth 15);Write-Output ('REVIEWED_LEGACY executed='+($passed+$failed)+' passed='+$passed+' failed='+$failed+' skipped=0 exit='+$exitCode+' evidence='+$runRoot)
}
exit $exitCode
