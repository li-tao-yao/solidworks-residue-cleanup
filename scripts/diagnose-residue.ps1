#requires -Version 7.0
[CmdletBinding()]
param(
    [string[]]$AdditionalPath = @(),
    [string]$OutFile
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or -not [Environment]::Is64BitProcess) {
    throw 'Use 64-bit PowerShell 7 on Windows.'
}
. (Join-Path $PSScriptRoot 'audit-helpers.ps1')
if (-not ('SwResidue.Product' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
namespace SwResidue {
    public static class Product {
        [DllImport("msi.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
        public static extern int MsiQueryProductStateW(string product);
    }
}
'@
}
$checks = [ordered]@{}
$faults = [Collections.Generic.List[object]]::new()
function Record-Probe([string]$Name, [scriptblock]$Query) {
    $items = [Collections.Generic.List[object]]::new()
    $status = 'Checked'
    try { & $Query | ForEach-Object { $items.Add($_) } }
    catch {
        $status = 'Incomplete'
        $faults.Add([pscustomobject]@{ Check=$Name; ErrorType=$_.Exception.GetType().Name })
    }
    $checks[$Name] = [pscustomobject]@{ Status=$status; Items=$items.ToArray() }
}

foreach ($view in @('HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node', 'HKCU:\Software')) {
    Record-Probe "ARP $view" {
        $root = Join-Path $view 'Microsoft\Windows\CurrentVersion\Uninstall'
        if (!(Test-Path -LiteralPath $root)) { return }
        foreach ($entry in Get-ChildItem -LiteralPath $root) {
            $name = [string]$entry.GetValue('DisplayName')
            $kind = Get-ProductCategory $name
            if ($kind) { [pscustomobject]@{ Name=$name; Category=$kind } }
        }
    }
}
Record-Probe 'InstallerUserData' {
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData'
    foreach ($owner in Get-ChildItem -LiteralPath $root) {
        $products = Join-Path $owner.PSPath 'Products'
        if (!(Test-Path -LiteralPath $products)) { continue }
        foreach ($key in Get-ChildItem -LiteralPath $products) {
            $path = Join-Path $key.PSPath 'InstallProperties'
            if (!(Test-Path -LiteralPath $path)) { continue }
            $props = Get-Item -LiteralPath $path
            $scope = switch ($owner.PSChildName) {
                'S-1-5-18' { 'Machine' }
                $currentSid { 'CurrentUser' }
                default { 'OtherUser' }
            }
            Get-MsiProductEvidence $props $key.PSChildName $scope
        }
    }
}
foreach ($base in @('HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node')) {
    Record-Probe "SqlInstanceMap $base" {
        $root = Join-Path $base 'Microsoft\Microsoft SQL Server\Instance Names\SQL'
        if (Test-Path -LiteralPath $root) { (Get-Item -LiteralPath $root).GetValueNames() }
    }
    Record-Probe "SqlBranches $base" {
        $root = Join-Path $base 'Microsoft\Microsoft SQL Server'
        if (Test-Path -LiteralPath $root) { (Get-Item -LiteralPath $root).GetSubKeyNames() }
    }
}
Record-Probe 'Services' {
    foreach ($svc in Get-CimInstance Win32_Service -Property Name,DisplayName,State,PathName) {
        $kind = Get-ProductCategory ($svc.Name+' '+$svc.DisplayName+' '+$svc.PathName)
        if ($kind) { [pscustomobject]@{ Name=$svc.Name; State=$svc.State; Category=$kind } }
    }
}
Record-Probe 'RsFxDrivers' {
    Get-CimInstance Win32_SystemDriver -Property Name,State,StartMode |
        Where-Object Name -match '^RsFx\d+$' | Select-Object Name,State,StartMode
}
Record-Probe 'RsFxServiceKeys' {
    Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services' |
        Where-Object PSChildName -match '^RsFx\d+$' | Select-Object -ExpandProperty PSChildName
}
Record-Probe 'RsFxDriverFiles' {
    Get-ChildItem -LiteralPath (Join-Path $env:SystemRoot 'System32\drivers') -Filter 'RsFx*.sys' -File -Force |
        Select-Object -ExpandProperty Name
}
Record-Probe 'LicenseFileMetadata' {
    $root = Join-Path $env:ProgramData 'FLEXnet'
    if (Test-Path -LiteralPath $root) {
        Get-ChildItem -LiteralPath $root -Filter 'SW_D_*' -File -Force | Select-Object Name,Length
    }
}
foreach ($base in @('HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node', 'HKCU:\Software')) {
    Record-Probe "LicenseValueNames $base" {
        $root = Join-Path $base 'FLEXlm License Manager'
        if (Test-Path -LiteralPath $root) {
            (Get-Item -LiteralPath $root).GetValueNames() | Where-Object { $_ -in 'SW_D_LICENSE_FILE','SEEMAGE_LICENSE_FILE' }
        }
    }
}
$paths = @(
    (Join-Path $env:ProgramData 'SOLIDWORKS Electrical')
    (Join-Path $env:ProgramFiles 'SOLIDWORKS Corp')
    (Join-Path $env:CommonProgramFiles 'SOLIDWORKS Shared')
    (Join-Path $env:APPDATA 'SOLIDWORKS')
    (Join-Path $env:LOCALAPPDATA 'SOLIDWORKS')
    (Join-Path $env:TEMP 'SOLIDWORKS')
    (Join-Path ([Environment]::GetFolderPath('CommonDocuments')) 'SOLIDWORKS')
) + $AdditionalPath
Record-Probe 'Paths' {
    foreach ($path in $paths | Select-Object -Unique) {
        [pscustomobject]@{ Path=$path; Exists=(Test-Path -LiteralPath $path) }
    }
}
Record-Probe 'Tasks' {
    foreach ($task in Get-ScheduledTask) {
        $match = $task.TaskName -match 'SOLIDWORKS|eDrawings|sldim'
        foreach ($action in $task.Actions) {
            if (($action.Execute+' '+$action.Arguments) -match 'SOLIDWORKS|eDrawings|sldim') { $match = $true }
        }
        if ($match) { [pscustomobject]@{ Name=$task.TaskName; Folder=$task.TaskPath } }
    }
}
Record-Probe 'Startup' {
    Get-CimInstance Win32_StartupCommand -Property Name,Command |
        Where-Object { ($_.Name+' '+$_.Command) -match 'SOLIDWORKS|eDrawings|sldim' } | Select-Object -ExpandProperty Name
}
Record-Probe 'FirewallPrograms' {
    Get-NetFirewallApplicationFilter | Where-Object Program -match 'SOLIDWORKS|eDrawings|sldim' |
        Select-Object -ExpandProperty Program -Unique
}

$summary = [ordered]@{
    Status = if ($faults.Count) { 'Incomplete' } else { 'CheckedListedScopes' }
    Checks = @($checks.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{ Check=$_.Key; Status=$_.Value.Status; Rows=$_.Value.Items.Count }
    })
    Errors = $faults.ToArray()
}
if ($OutFile) {
    $report = [ordered]@{ Summary=$summary; Evidence=$checks }
    Write-NewAuditFile $OutFile ($report | ConvertTo-Json -Depth 8)
}
$summary | ConvertTo-Json -Depth 5
