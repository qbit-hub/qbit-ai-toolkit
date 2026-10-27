[CmdletBinding()]
param(
  [ValidateSet('plan','install','update','verify','uninstall')][string]$Operation='install',
  [Parameter(Mandatory=$true)][string]$Target,
  [ValidateSet('member','central','')][string]$Mode='',
  [string]$ProjectId='',
  [string]$ProjectDisplayName='',
  [string]$RepositoryId='',
  [string]$ContextRepositoryId='',
  [string]$ContextRemote='',
  [string]$ContextBranch='',
  [ValidateSet('fail','replace')][string]$OwnedModified='fail',
  [switch]$AdoptMatching,
  [switch]$MigrateLegacy,
  [ValidateSet('text','json')][string]$Format='text'
)

Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib/installer.ps1')

$ExitCode=0
$Result=$null
try {
  Assert-AiContextRelease
  $Root=Resolve-AiContextTarget $Target
  $State=Get-State $Root

  if ($Operation -eq 'verify') {
    $Verified=Test-AiContextInstallation $Root
    $Result=[ordered]@{schema_version='1.0';installer_version=$Script:InstallerVersion;operation=$Operation;target=$Root;mode=[string]$Verified.mode;success=$true;exit_code=0;actions=@();conflicts=@();warnings=@()}
  } elseif ($Operation -eq 'uninstall') {
    Invoke-AiContextUninstall $Root $OwnedModified
    $Result=[ordered]@{schema_version='1.0';installer_version=$Script:InstallerVersion;operation=$Operation;target=$Root;mode=if($State){[string]$State.mode}else{''};success=$true;exit_code=0;actions=@('remove managed AI Context assets');conflicts=@();warnings=@('Project-owned seed files are intentionally preserved.')}
  } else {
    if ($Operation -eq 'update' -and $null -eq $State) { throw 'Update requires an existing AI Context ownership state.' }

    $EffectiveMode=if(-not [string]::IsNullOrWhiteSpace($Mode)){$Mode}elseif($State){[string]$State.mode}else{'member'}
    if($State -and $EffectiveMode -cne [string]$State.mode){throw 'Mode is immutable for an existing AI Context installation.'}

    $EffectiveProject=if(-not [string]::IsNullOrWhiteSpace($ProjectId)){$ProjectId}elseif($State){[string]$State.projectId}else{''}
    $EffectiveProject=Assert-SafeId $EffectiveProject 'ProjectId'
    if($State -and $EffectiveProject -cne [string]$State.projectId){throw 'ProjectId is immutable for an existing AI Context installation.'}

    $FallbackRepository=Split-Path -Leaf $Root
    $EffectiveRepository=if(-not [string]::IsNullOrWhiteSpace($RepositoryId)){$RepositoryId}elseif($State){[string]$State.repositoryId}else{$FallbackRepository}
    $EffectiveRepository=Assert-SafeId $EffectiveRepository 'RepositoryId'
    if($State -and $EffectiveRepository -cne [string]$State.repositoryId){throw 'RepositoryId is immutable for an existing AI Context installation.'}

    $EffectiveDisplay=if(-not [string]::IsNullOrWhiteSpace($ProjectDisplayName)){$ProjectDisplayName}else{$EffectiveProject}
    $EffectiveDisplay=Assert-SafeDisplayName $EffectiveDisplay

    $EffectiveBranch=if(-not [string]::IsNullOrWhiteSpace($ContextBranch)){$ContextBranch}elseif($State){[string]$State.contextBranch}else{'main'}
    $EffectiveBranch=Assert-SafeBranch $EffectiveBranch

    $EffectiveRemote=if(-not [string]::IsNullOrWhiteSpace($ContextRemote)){$ContextRemote}elseif($State){[string]$State.contextRemote}else{''}
    if([string]::IsNullOrWhiteSpace($EffectiveRemote) -and $EffectiveMode -eq 'central'){
      $Origin=@(& git -C $Root remote get-url origin 2>$null)
      if($LASTEXITCODE -eq 0){$EffectiveRemote=($Origin -join '').Trim()}
    }
    $EffectiveRemote=Assert-SafeRemote $EffectiveRemote

    $EffectiveContextRepository=if(-not [string]::IsNullOrWhiteSpace($ContextRepositoryId)){$ContextRepositoryId}else{''}
    if([string]::IsNullOrWhiteSpace($EffectiveContextRepository)){
      if($EffectiveRemote -match '/([^/]+?)(?:\.git)?/?$'){$EffectiveContextRepository=$Matches[1]}
      else{$EffectiveContextRepository=if($EffectiveMode -eq 'central'){$EffectiveRepository}else{($EffectiveProject + '-ai-context')}}
    }
    $EffectiveContextRepository=Assert-SafeId $EffectiveContextRepository 'ContextRepositoryId'

    $Variables=Get-Variables $EffectiveProject $EffectiveDisplay $EffectiveRepository $EffectiveContextRepository $EffectiveRemote $EffectiveBranch
    $Spec=New-Spec $EffectiveMode $Variables
    $Plan=New-Plan $Root $Spec $State $OwnedModified ([bool]$AdoptMatching) ([bool]$MigrateLegacy)
    $ActionText=@($Plan.Actions|ForEach-Object{"$($_.Action) $($_.Path)"})

    if($Operation -eq 'plan'){
      $Success=$Plan.Conflicts.Count -eq 0
      $ExitCode=if($Success){0}else{4}
      $Result=[ordered]@{schema_version='1.0';installer_version=$Script:InstallerVersion;operation=$Operation;target=$Root;mode=$EffectiveMode;success=$Success;exit_code=$ExitCode;actions=$ActionText;conflicts=@($Plan.Conflicts);warnings=@()}
    } else {
      if($Plan.Conflicts.Count -gt 0){$ExitCode=4;throw ('Conflicts: ' + ($Plan.Conflicts -join '; '))}
      $NeedsStateRefresh = $null -ne $State -and ([string]$State.installerVersion -cne $Script:InstallerVersion)
      if ($null -ne $State -and $Plan.Actions.Count -eq 0 -and -not $NeedsStateRefresh) {
        $null=Test-AiContextInstallation $Root
      } else {
        Invoke-AiContextMutation $Root $Spec $State $Plan $EffectiveMode $EffectiveProject $EffectiveRepository $EffectiveRemote $EffectiveBranch
        $null=Test-AiContextInstallation $Root
      }
      $Result=[ordered]@{schema_version='1.0';installer_version=$Script:InstallerVersion;operation=$Operation;target=$Root;mode=$EffectiveMode;success=$true;exit_code=0;actions=$ActionText;conflicts=@();warnings=@()}
    }
  }
} catch {
  if($ExitCode -eq 0){
    $Message=$_.Exception.Message
    if($Message -match 'conflict|modified|managed block|AdoptMatching'){$ExitCode=4}
    elseif($Message -match 'ownership state|identity|hash mismatch'){$ExitCode=5}
    elseif($Message -match 'Target|Git work tree|Refusing|required|invalid|immutable'){$ExitCode=2}
    else{$ExitCode=12}
  }
  $Result=[ordered]@{schema_version='1.0';installer_version=$Script:InstallerVersion;operation=$Operation;target=$Target;mode=$Mode;success=$false;exit_code=$ExitCode;actions=@();conflicts=if($ExitCode -eq 4){@($_.Exception.Message)}else{@()};warnings=@();error=$_.Exception.Message}
}

if($Format -eq 'json'){$Result|ConvertTo-Json -Depth 8 -Compress}else{
  if($Result.success){Write-Output "AI Context $($Result.operation) succeeded for $($Result.target).";foreach($Action in @($Result.actions)){Write-Output "  $Action"};foreach($Warning in @($Result.warnings)){Write-Warning $Warning}}
  else{[Console]::Error.WriteLine([string]$Result.error);foreach($Conflict in @($Result.conflicts)){[Console]::Error.WriteLine("  $Conflict")}}
}
exit $ExitCode
