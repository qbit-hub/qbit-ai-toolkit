#requires -Version 5.1
param([string]$FixtureRoot=(Join-Path ([IO.Path]::GetTempPath()) 'qbit-worktree-receipts'))
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
  $a=Join-Path $runRoot 'a';$b=Join-Path $runRoot 'b';InitRepo $a;Git $a @('worktree','add','-q','-b','feature/b',$b)|Out-Null
  foreach($root in @($a,$b)){$r=Run $install @('-Operation','install','-Mode','member','-Target',$root,'-ProjectId','isolation','-RepositoryId','same-member','-ContextRemote',$bare);Assert ($r.Code -eq 0) $r.Text;$r=Gate $root 'Start';Assert ($r.Code -eq 0) $r.Text;Git (Cache $root) @('config','user.name','Worktree Fixture')|Out-Null;Git (Cache $root) @('config','user.email','worktree@example.invalid')|Out-Null}
  Case 'A publishes authoritative receipt bound to main Worktree' {
    Publish $a 'WS-A' 'a-first'
    $script:manifestA=Manifest $a;$rt=Runtime $a;$script:pathsA=$rt.continuity.receiptPaths
    Assert ($manifestA.worktreeId -eq (ExpectedId $a) -and $rt.continuity.worktreeId -eq $manifestA.worktreeId) 'A Worktree ID does not match normalized-root SHA256 contract'
    Assert ($pathsA.manifest -eq ('manifests/worktrees/same-member/'+(ExpectedId $a)+'.json') -and $pathsA.state -eq ('state/worktrees/same-member/'+(ExpectedId $a)+'.md') -and $pathsA.handoff -eq ('handoffs/worktrees/same-member/'+(ExpectedId $a)+'.md')) 'A receipt paths do not match canonical Worktree namespace'
    Assert ($manifestA.branch -eq 'main' -and $manifestA.memberWorktree -eq $a) 'A source identity changed'
    $script:payloadA=[IO.File]::ReadAllBytes((Join-Path $a '.ai-bridge/context-checkpoint-pending.json'))
  }
  Case 'B Start does not load bound sibling A Workstream' {$r=Gate $b 'Start';Assert ($r.Code -eq 0) $r.Text;$rt=Runtime $b;Assert ($null -eq $rt.continuity.workstream -and -not $rt.continuity.workstreamId -and $rt.continuity.worktreeId -eq (ExpectedId $b)) 'B inherited sibling A continuation';$bundle=[IO.File]::ReadAllText((Join-Path $b '.ai-bridge/context-runtime.md'));Assert (-not $bundle.Contains('Continue WS-A-1.')) 'B Markdown bundle inherited sibling A next action'}
  Case 'unbound active legacy summary blocks unmapped Worktree explicitly' {
    Git $central @('pull','-q','--ff-only','origin','main')|Out-Null;$restore=Git $central @('rev-parse','HEAD');$legacy=Join-Path $central 'manifests/repositories/same-member.json';$m=Get-Content -LiteralPath $legacy -Raw -Encoding UTF8|ConvertFrom-Json;$m.PSObject.Properties.Remove('memberWorktree');$m.PSObject.Properties.Remove('worktreeId');$m.PSObject.Properties.Remove('receiptPaths');WriteUtf8 $legacy ($m|ConvertTo-Json -Depth 20);Git $central @('add','--all')|Out-Null;Git $central @('commit','-q','-m','invalid unbound legacy fixture')|Out-Null;Git $central @('push','-q','origin','main')|Out-Null
    $before=SourceReceipt $b;$remote=Git $bare @('rev-parse','refs/heads/main');$r=Gate $b 'Start';Assert ($r.Code -eq 3 -and $r.Text -match 'CONTEXT_UNSYNCED') 'Unbound active legacy was silently mapped';Assert ((SourceReceipt $b) -ceq $before -and (Git $bare @('rev-parse','refs/heads/main')) -eq $remote) 'Rejected legacy Start changed source or remote'
    Git $central @('restore',('--source='+$restore),'--staged','--worktree','--','manifests/repositories/same-member.json')|Out-Null;Git $central @('commit','-q','-m','restore bound legacy summary')|Out-Null;Git $central @('push','-q','origin','main')|Out-Null
  }
  Case 'B cannot take over WS-A despite same repository ID' {
    # B has no prior Workstream: only the global owner guard can reject this
    # first checkpoint, rather than an unrelated unresolved-item transition.
    $r=Gate $b 'Start';Assert ($r.Code -eq 0) $r.Text
    Payload $b 'WS-A' 'attempt-sibling-takeover';$before=SourceReceipt $b;$remote=Git $bare @('rev-parse','refs/heads/main')
    $r=Gate $b 'Checkpoint';Assert ($r.Code -eq 3 -and $r.Text -match 'CONTEXT_UNSYNCED') 'Same-repository sibling stole global Workstream'
    $native=Run (Join-Path $b '.ai/context/context.ps1') @('checkpoint')
    Assert ($native.Code -ne 0 -and $native.Text -match 'Global workstream id belongs to another owning Worktree') 'Takeover was rejected for an unrelated reason'
    Assert ((SourceReceipt $b) -ceq $before -and (Git $bare @('rev-parse','refs/heads/main')) -eq $remote -and (Git (Cache $b) @('status','--porcelain')) -eq '') 'Rejected takeover changed source, journal, cache or publication'
  }
  # A new reviewed fixture payload replaces the deliberately rejected proposal.
  Case 'B publishes distinct WS-B on linked feature branch' {Publish $b 'WS-B' 'b-first';$script:manifestB=Manifest $b;$script:pathsB=(Runtime $b).continuity.receiptPaths;Assert ($manifestB.worktreeId -eq (ExpectedId $b) -and $manifestB.worktreeId -ne $manifestA.worktreeId -and $manifestB.branch -eq 'feature/b') 'B receipt collapsed onto A identity'}
  Case 'A Start and Verify remain valid after sibling B publication' {$r=Gate $a 'Start';Assert ($r.Code -eq 0) $r.Text;$rt=Runtime $a;Assert ($rt.continuity.workstreamId -eq 'WS-A' -and $rt.continuity.workstream.cursor.currentItemId -eq 'WS-A-1') 'A resumed B continuation';$bundle=[IO.File]::ReadAllText((Join-Path $a '.ai-bridge/context-runtime.md'));Assert ($bundle.Contains('Continue WS-A-1.') -and -not $bundle.Contains('Continue WS-B-1.')) 'A Markdown bundle selected sibling repository summary';$r=Gate $a 'Verify';Assert ($r.Code -eq 0) $r.Text}
  Case 'fresh independent Git client recovers both Worktree receipts' {
    $reader=Join-Path $runRoot 'independent-reader';Git $runRoot @('clone','-q','--branch','main','--',$bare,$reader)|Out-Null
    foreach($item in @(@{root=$a;paths=$pathsA;id='WS-A';manifest=$manifestA},@{root=$b;paths=$pathsB;id='WS-B';manifest=$manifestB})){$m=Get-Content -LiteralPath (Join-Path $reader $item.paths.manifest) -Raw -Encoding UTF8|ConvertFrom-Json;$ws=Get-Content -LiteralPath (Join-Path $reader $m.continuity.workstreamPath) -Raw -Encoding UTF8|ConvertFrom-Json;$state=[IO.File]::ReadAllText((Join-Path $reader $item.paths.state));$session=[IO.File]::ReadAllText((Join-Path $reader $m.session));Assert ($m.memberWorktree -eq $item.root -and $m.checkpointId -eq $item.manifest.checkpointId -and $ws.id -eq $item.id -and $ws.cursor.currentItemId -eq ($item.id+'-1') -and $ws.cursor.nextAction -eq ('Continue '+$item.id+'-1.') -and $state.Contains($m.session) -and $session.Contains('Checkpoint ID: '+$m.checkpointId)) 'Independent client lost Worktree-specific continuation'}
  }
  Case 'A completed journal retries after B without duplicate Session or commit' {
    $journal=Get-Content -LiteralPath (Join-Path $a '.ai-bridge/context-checkpoint-pending.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $remote=Git $bare @('rev-parse','refs/heads/main');$beforeSessions=Git (Cache $a) @('ls-tree','-r','--name-only','HEAD','--','sessions')
    # Exact original payload bytes are represented by the durable completed journal's original payload snapshot reconstructed from its Session scope.
    Payload $a 'WS-A' 'a-first';$r=Gate $a 'Checkpoint';Assert ($r.Code -eq 0) $r.Text
    $after=Get-Content -LiteralPath (Join-Path $a '.ai-bridge/context-checkpoint-pending.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Assert ((Git $bare @('rev-parse','refs/heads/main')) -eq $remote -and $after.id -eq $journal.id -and $after.session -eq $journal.session -and (Git (Cache $a) @('ls-tree','-r','--name-only','HEAD','--','sessions')) -ceq $beforeSessions) 'Sibling publication duplicated or invalidated completed A checkpoint'
  }
  Case 'missing owning Manifest cannot drop A continuation after sibling B publication' {
    Git $central @('pull','-q','--ff-only','origin','main')|Out-Null
    $restore=Git $central @('rev-parse','HEAD')
    $ownPaths=@([string]$pathsA.manifest,[string]$pathsA.state,[string]$pathsA.handoff)
    Git $central @('rm','-q','--',$ownPaths[0])|Out-Null
    Git $central @('commit','-q','-m','remove owning Manifest in corrupt remote fixture')|Out-Null
    Git $central @('push','-q','origin','main')|Out-Null
    Payload $a 'WS-A' 'rejected-snapshot-after-missing-receipt'
    $proposalPath=Join-Path $a '.ai-bridge/context-checkpoint.json'
    $proposal=Get-Content -LiteralPath $proposalPath -Raw -Encoding UTF8|ConvertFrom-Json
    $proposal.continuity.mode='snapshot';$proposal.continuity.workstream=$null
    WriteUtf8 $proposalPath ($proposal|ConvertTo-Json -Depth 20)
    $before=SourceReceipt $a
    foreach($removeOtherRecords in @($false,$true)){
      if($removeOtherRecords){
        Git $central @('rm','-q','--',$ownPaths[1],$ownPaths[2])|Out-Null
        Git $central @('commit','-q','-m','remove all scoped receipts while active owner remains')|Out-Null
        Git $central @('push','-q','origin','main')|Out-Null
      }
      $remote=Git $bare @('rev-parse','refs/heads/main')
      $r=Run (Join-Path $a '.ai/context/context.ps1') @('start')
      Assert ($r.Code -ne 0 -and $r.Text -match 'Scoped Worktree Context Manifest is missing') 'Start treated incomplete owning continuation as a new Worktree'
      $r=Gate $a 'Checkpoint'
      Assert ($r.Code -eq 3 -and $r.Text -match 'CONTEXT_UNSYNCED') 'Snapshot silently discarded unresolved owning Workstream'
      Assert ((SourceReceipt $a) -ceq $before -and (Git $bare @('rev-parse','refs/heads/main')) -eq $remote -and (Git (Cache $a) @('status','--porcelain')) -eq '') 'Rejected missing receipt changed source, proposal, journal, cache or publication'
    }
    Git $central (@('restore',('--source='+$restore),'--staged','--worktree','--')+$ownPaths)|Out-Null
    Git $central @('commit','-q','-m','restore owning continuity receipts')|Out-Null
    Git $central @('push','-q','origin','main')|Out-Null
    Publish $a 'WS-A' 'a-after-reviewed-receipt-recovery'
  }
  Case 'owning Workstream Session must match its scoped Manifest at Start' {
    Git $central @('pull','-q','--ff-only','origin','main')|Out-Null
    $restore=Git $central @('rev-parse','HEAD')
    $relative='workstreams/active/WS-A.json'
    $file=Join-Path $central $relative
    $ws=Get-Content -LiteralPath $file -Raw -Encoding UTF8|ConvertFrom-Json
    $ws.lastCheckpoint.session='sessions/forged-other-operation.md'
    WriteUtf8 $file ($ws|ConvertTo-Json -Depth 20)
    Git $central @('add','--',$relative)|Out-Null
    Git $central @('commit','-q','-m','mismatch owning Session in corrupt remote fixture')|Out-Null
    Git $central @('push','-q','origin','main')|Out-Null
    $before=SourceReceipt $a;$remote=Git $bare @('rev-parse','refs/heads/main')
    $r=Run (Join-Path $a '.ai/context/context.ps1') @('start')
    Assert ($r.Code -ne 0 -and $r.Text -match 'Previous workstream Session does not match its Manifest') 'Start loaded a Workstream from a different checkpoint Session'
    Assert ((SourceReceipt $a) -ceq $before -and (Git $bare @('rev-parse','refs/heads/main')) -eq $remote) 'Rejected Session mismatch changed owning source, decisions or publication'
    Git $central @('restore',('--source='+$restore),'--staged','--worktree','--',$relative)|Out-Null
    Git $central @('commit','-q','-m','restore owning Workstream Session')|Out-Null
    Git $central @('push','-q','origin','main')|Out-Null
    Publish $a 'WS-A' 'a-after-reviewed-session-recovery'
  }
  Case 'A source drift blocks only A and real A checkpoint repairs it' {
    WriteUtf8 (Join-Path $a 'source.txt') 'A changed source';$r=Gate $a 'Verify';Assert ($r.Code -eq 3) 'A drift falsely verified';$r=Gate $b 'Start';Assert ($r.Code -eq 0) $r.Text;$r=Gate $b 'Verify';Assert ($r.Code -eq 0) ('A drift invalidated B: '+$r.Text);Publish $a 'WS-A' 'a-source-repair'
  }
  Case 'A archive remains unchanged after new B checkpoint' {
    Publish $a 'WS-A' 'a-archive' $true;$archive=Join-Path (Cache $a) 'workstreams/archive/WS-A.json';$hash=(Get-FileHash -LiteralPath $archive).Hash;Publish $b 'WS-B' 'b-after-a-archive';$r=Gate $a 'Start';Assert ($r.Code -eq 0) $r.Text;Assert ((Get-FileHash -LiteralPath $archive).Hash -eq $hash -and -not(Test-Path -LiteralPath (Join-Path (Cache $a) 'workstreams/active/WS-A.json'))) 'Sibling B erased, reopened or rewrote A archive';$r=Gate $a 'Verify';Assert ($r.Code -eq 0) ('A terminal receipt invalidated by B: '+$r.Text)
  }
}catch{$failed=1;$exitCode=1;$results.Add([pscustomobject]@{name='failure';result='FAIL';detail=$_.Exception.Message});Write-Output ('FAIL '+$_.Exception.Message)}
finally{
  $hashes=@();foreach($relative in @('templates/common/member/context-sync-gate.ps1','templates/common/central/tooling/context-lifecycle.ps1','templates/common/central/tooling/context-continuity.ps1','tests/integration/test-worktree-receipt-isolation.ps1')){$hashes += [ordered]@{path=$relative;sha256=(Get-FileHash -LiteralPath (Join-Path $installerRoot $relative)).Hash}}
  $summary=[ordered]@{suite='worktree-receipt-isolation';startUtc=$started.ToString('o');endUtc=[DateTimeOffset]::UtcNow.ToString('o');powershell=$PSVersionTable.PSVersion.ToString();gitVersion=(& git.exe --version);sourceHead=(Git $toolkitRoot @('rev-parse','HEAD'));sourceBranch=(Git $toolkitRoot @('branch','--show-current'));sourceHashes=$hashes;passed=$passed;failed=$failed;executed=($passed+$failed);skipped=0;exitCode=$exitCode;fixtureRoot=$runRoot;results=@($results.ToArray())}
  WriteUtf8 (Join-Path $runRoot 'results.json') ($summary|ConvertTo-Json -Depth 15);Write-Output ('WORKTREE_RECEIPTS executed='+($passed+$failed)+' passed='+$passed+' failed='+$failed+' skipped=0 exit='+$exitCode+' evidence='+$runRoot)
}
exit $exitCode
