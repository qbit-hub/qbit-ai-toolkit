#requires -Version 5.1
param([string]$FixtureParent='')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$installer=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if(-not $FixtureParent){$FixtureParent=[IO.Path]::GetTempPath()}
$fixture=Join-Path $FixtureParent ('qbit-reviewed-git-text-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $fixture|Out-Null
. (Join-Path $installer 'templates/common/central/tooling/context-continuity.ps1')
function Git([string[]]$Arguments){$r=Invoke-ContinuityReviewGit $fixture $Arguments;return $r.Text}
$null=Git @('init','-q','-b','main')
$null=Git @('config','core.autocrlf','false')
$null=Git @('config','user.name','Fixture')
$null=Git @('config','user.email','fixture@example.invalid')
$paths=@('bom.json','plain.json');$original=@{}
foreach($name in $paths){
 $path=Join-Path $fixture $name
 [IO.File]::WriteAllText($path,'{"preserved":"legacy-intent","items":["QRUST-001"]}',[Text.UTF8Encoding]::new(($name -eq 'bom.json')))
 $original[$name]=(Get-FileHash -LiteralPath $path).Hash
}
$null=Git @('add','--','bom.json','plain.json');$null=Git @('commit','-q','-m','real historical JSON blobs')
$passed=0
foreach($name in $paths){
 $text=Git @('show',('HEAD:'+$name));$json=$text|ConvertFrom-Json
 if($json.preserved -cne 'legacy-intent' -or $json.items[0] -cne 'QRUST-001' -or $text.StartsWith([string][char]0xFEFF,[StringComparison]::Ordinal)){throw 'Git JSON decoding lost intent or retained BOM'}
 if((Get-FileHash -LiteralPath (Join-Path $fixture $name)).Hash -cne $original[$name]){throw 'Reader changed original bytes'}
 $blob=Git @('rev-parse',('HEAD:'+$name));if($blob -cne (Git @('hash-object','--no-filters','--',$name))){throw 'Reader changed Git blob identity'}
 $passed++;Write-Output ('PASS '+$name+' decode with original bytes/blob preserved')
}
$central=[IO.File]::ReadAllText((Join-Path $installer 'templates/common/central/tooling/context-continuity.ps1'))
$gate=[IO.File]::ReadAllText((Join-Path $installer 'templates/common/member/context-sync-gate.ps1'))
$pattern='(?s)# The same validator.*?# End shared reviewed legacy validator\.'
if([regex]::Match($central,$pattern).Value -cne [regex]::Match($gate,$pattern).Value){throw 'Independent gate/engine validators differ'}
$passed++;Write-Output 'PASS independent validator copies match'
$status=Git @('status','--porcelain=v1');if($status){throw 'Reader dirtied fixture'}
Write-Output ('REVIEWED_GIT_TEXT executed='+$passed+' passed='+$passed+' failed=0 skipped=0 host='+$PSVersionTable.PSVersion+' fixture='+$fixture)
