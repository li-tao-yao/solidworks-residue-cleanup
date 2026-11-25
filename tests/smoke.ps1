#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts/audit-helpers.ps1')
function Assert([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
Assert ((ConvertFrom-PackedProductCode '76543210BA98FEDC1032547698BADCFE') -eq '{01234567-89AB-CDEF-0123-456789ABCDEF}') 'Packed GUID failed'
Assert ((Get-ProductCategory 'MySQL Server 8.0') -eq $null) 'MySQL matched SQL Server'
Assert ((Get-ProductCategory 'Microsoft SQL Server 2022 Setup') -eq 'SharedComponent') 'Shared SQL misclassified'
Assert ((Get-ProductCategory 'CEF for SOLIDWORKS Applications') -eq 'ProductCandidate') 'CEF not identified'
& {
    function Get-CurrentMsiState([string]$ProductCode) { 5 }
    function Test-Path([string]$LiteralPath) { $false }
    $fixture = [pscustomobject]@{}
    $fixture | Add-Member ScriptMethod GetValue {
        param($name)
        if ($name -eq 'DisplayName') { 'Microsoft SQL Server 2022 Setup' }
    }
    $row = Get-MsiProductEvidence $fixture '76543210BA98FEDC1032547698BADCFE' 'Machine'
    Assert ($row.CurrentContextState -eq 5 -and !$row.MachineUninstall64 -and !$row.MachineUninstall32) 'MSI product lost when ARP is empty'
}
$probePath = Join-Path ([IO.Path]::GetTempPath()) ("sw-fixture-" + [guid]::NewGuid() + ".json")
try {
    Write-NewAuditFile $probePath '{"fixture":true}'
    $blocked = $false
    try { Write-NewAuditFile $probePath 'replacement' } catch [IO.IOException] { $blocked = $true }
    Assert ($blocked -and ([IO.File]::ReadAllText($probePath) -eq '{"fixture":true}')) 'Existing file was modified'
} finally {
    if ([IO.File]::Exists($probePath)) { [IO.File]::Delete($probePath) }
}
# Simulate a denied task query and a startup command containing private arguments.
# Other probes exercise the ordinary read-only Windows entry point.
function Get-ScheduledTask { throw [UnauthorizedAccessException]::new('synthetic access denial') }
function Get-CimInstance([string]$ClassName, [string[]]$Property) {
    if ($ClassName -eq 'Win32_StartupCommand') {
        [pscustomobject]@{ Name='Fixture'; Command='sldim.exe --fixture PRIVATE_MARKER' }
    }
}
$reportPath = Join-Path ([IO.Path]::GetTempPath()) ("sw-fixture-" + [guid]::NewGuid() + ".json")
try {
    $text = & (Join-Path $root 'scripts/diagnose-residue.ps1') -OutFile $reportPath
    $summary = $text | ConvertFrom-Json
    $raw = [IO.File]::ReadAllText($reportPath)
    $report = $raw | ConvertFrom-Json
    Assert ($summary.Status -eq 'Incomplete' -and $report.Evidence.Tasks.Status -eq 'Incomplete') 'Denied query counted as complete'
    Assert ($report.Evidence.Startup.Items -contains 'Fixture') 'Startup match missing'
    Assert ($raw -notmatch 'PRIVATE_MARKER') 'Private startup arguments in output'
    Assert (!($summary.PSObject.Properties.Name -contains 'Evidence')) 'Evidence in console summary'
} finally {
    if ([IO.File]::Exists($reportPath)) { [IO.File]::Delete($reportPath) }
}
'PASS: MSI GUID, component classification, output overwrite protection, incomplete checks, report privacy'
