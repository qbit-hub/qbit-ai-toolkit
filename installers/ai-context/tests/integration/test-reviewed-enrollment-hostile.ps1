#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$FixtureRoot,[string]$ToolkitRoot='')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if([string]::IsNullOrWhiteSpace($ToolkitRoot)){$ToolkitRoot=(Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path}
. (Join-Path $ToolkitRoot 'installers/ai-context/templates/common/central/tooling/context-continuity.ps1')
$out=Join-Path (Split-Path -Parent $FixtureRoot) ('hostile-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Force -Path $out|Out-Null
function Git([string]$root,[string[]]$Arguments){$old=$ErrorActionPreference;$ErrorActionPreference='Continue';try{$text=@(& git.exe -C $root @Arguments 2>&1);$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old};if($code){throw ('Fixture Git failed '+($Arguments -join ' '))};return ($text -join "`n").Trim()}
$central=Join-Path $FixtureRoot 'central';$member=Join-Path $FixtureRoot 'a'
$rel='references/continuity-reconciliations/same-member.json'
$record=Get-Content -LiteralPath (Join-Path $central $rel) -Raw -Encoding UTF8|ConvertFrom-Json
$base=[string]$record.baseCommit;$passed=0;$results=@()
$modes=@('valid','unknown-key','wrong-repository','wrong-remote','wrong-base','missing-triple','wrong-triple-blob','unsafe-triple-path','wrong-workstream','wrong-workstream-blob','invalid-disposition','wrong-worktree-id','duplicate-root','old-target-id','duplicate-target-id','empty-review-provenance')
foreach($mode in $modes){
 $clone=Join-Path $out $mode
 $null=Git $out @('clone','--quiet','--no-checkout',$central,$clone)
 $null=Git $clone @('switch','--quiet','--detach',$base)
 $null=Git $clone @('remote','set-url','origin',[string]$record.contextRemote)
 $null=Git $clone @('config','user.name','Hostile Fixture');$null=Git $clone @('config','user.email','fixture@example.invalid')
 $r=$record|ConvertTo-Json -Depth 30|ConvertFrom-Json
 switch($mode){
  'unknown-key' {$r|Add-Member -NotePropertyName inferredOwner -NotePropertyValue 'forged'}
  'wrong-repository' {$r.repository='another-member'}
  'wrong-remote' {$r.contextRemote='https://example.invalid/wrong.git'}
  'wrong-base' {$r.baseCommit=('0'*40)}
  'missing-triple' {$r.legacy=@($r.legacy|Select-Object -First 2)}
  'wrong-triple-blob' {$r.legacy[0].blob=('0'*40)}
  'unsafe-triple-path' {$r.legacy[0].path='../outside.json'}
  'wrong-workstream' {$r.workstream.id='forged'}
  'wrong-workstream-blob' {$r.workstream.blob=('0'*40)}
  'invalid-disposition' {$r.workstream.disposition='assume-stale'}
  'wrong-worktree-id' {$r.enrollments[0].worktreeId=('wt-'+('0'*32))}
  'duplicate-root' {$r.enrollments=@($r.enrollments)+@($r.enrollments[0])}
  'old-target-id' {$r.enrollments[0].workstreamId='LEGACY'}
  'duplicate-target-id' {$r.enrollments[1].workstreamId=$r.enrollments[0].workstreamId}
  'empty-review-provenance' {$r.review.provenance=@()}
 }
 $file=Join-Path $clone $rel;New-Item -ItemType Directory -Force -Path (Split-Path $file)|Out-Null
 [IO.File]::WriteAllText($file,($r|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
 $null=Git $clone @('add','--',$rel);$null=Git $clone @('commit','--quiet','-m','isolated first review record')
 $before=Git $clone @('rev-parse','HEAD');$status=Git $clone @('status','--porcelain=v1')
 $accepted=$false;$reason=''
 try{$result=Get-ContinuityLegacyReview $clone 'same-member' $member;$accepted=$null -ne $result.Enrollment}catch{$reason=$_.Exception.Message}
 if(($mode -eq 'valid') -ne $accepted){throw ('Unexpected admission '+$mode+': '+$reason)}
 if((Git $clone @('rev-parse','HEAD')) -cne $before -or (Git $clone @('status','--porcelain=v1')) -cne $status){throw 'Read-only review mutated fixture'}
 $passed++;$results+=@{case=$mode;result='PASS';accepted=$accepted;reason=$reason};Write-Output ('PASS '+$mode)
}
$report=@{executed=$passed;passed=$passed;failed=0;skipped=0;fixtureRoot=$out;results=$results}
[IO.File]::WriteAllText((Join-Path $out 'results.json'),($report|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($false))
Write-Output ('HOSTILE_REVIEW passed='+$passed+' failed=0 skipped=0 evidence='+$out)
