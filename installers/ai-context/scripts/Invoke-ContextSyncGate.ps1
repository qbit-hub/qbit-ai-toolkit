#requires -Version 5.1
[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$MemberPath,
 [ValidateSet('Start','Status','Verify','Checkpoint')][string]$Mode='Verify',
 [ValidateRange(1,1440)][int]$MaxAgeMinutes=120,
 [ValidateRange(1,300)][int]$TimeoutSeconds=30
)
& (Join-Path $PSScriptRoot '../templates/common/member/context-sync-gate.ps1') @PSBoundParameters
exit $LASTEXITCODE
