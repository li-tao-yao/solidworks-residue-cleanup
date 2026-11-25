#requires -Version 5.1
[CmdletBinding()]
param(
    [string[]]$AdditionalPath = @(),
    [string]$OutFile
)
$ErrorActionPreference = 'Stop'
$onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or [bool]$IsWindows
if (-not $onWindows -or -not [Environment]::Is64BitProcess) {
    throw 'Use 64-bit Windows PowerShell 5.1 or PowerShell 7+ on Windows.'
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

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$activeName = $null
$pendingName = $null
try { $activeName = [string](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction Stop).ComputerName } catch {}
try { $pendingName = [string](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction Stop).ComputerName } catch {}
$context = [ordered]@{
    IsAdmin = $isAdmin
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    Is64Bit = [Environment]::Is64BitProcess
    HasNonAsciiActiveHostname = if ($activeName) { [bool]($activeName -match '[^\x00-\x7F]') } else { $null }
    PendingHostnameReboot = if ($activeName -and $pendingName) { [bool]($activeName -ine $pendingName) } else { $null }
}

$checks = [ordered]@{}
$faults = [Collections.Generic.List[object]]::new()
$script:probeStatus = 'Checked'
$script:probeName = ''

function Add-ProbeFault($Exception) {
    $script:probeStatus = 'Incomplete'
    $faults.Add([pscustomobject]@{ Check=$script:probeName; ErrorType=$Exception.GetType().Name })
}

function Record-Probe([string]$Name, [scriptblock]$Query) {
    $items = [Collections.Generic.List[object]]::new()
    $script:probeStatus = 'Checked'
    $script:probeName = $Name
    try { & $Query | ForEach-Object { $items.Add($_) } }
    catch {
        Add-ProbeFault $_.Exception
    }
    $checks[$Name] = [pscustomobject]@{ Status=$script:probeStatus; Items=$items.ToArray() }
}

foreach ($view in @('HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node', 'HKCU:\Software')) {
    Record-Probe "ARP $view" {
        $root = Join-Path $view 'Microsoft\Windows\CurrentVersion\Uninstall'
        if (-not (Test-Path -LiteralPath $root)) { return }
        foreach ($entry in @(Get-ChildItem -LiteralPath $root -ErrorAction Stop)) {
            try {
                $name = [string]$entry.GetValue('DisplayName')
                $kind = Get-ProductCategory $name
                if ($kind) {
                    $uninstallStr = [string]$entry.GetValue('UninstallString')
                    [pscustomobject]@{
                        Name = $name
                        DisplayVersion = [string]$entry.GetValue('DisplayVersion')
                        Category = $kind
                        KeyName = $entry.PSChildName
                        InstallLocation = [string]$entry.GetValue('InstallLocation')
                        HasUninstallString = (-not [string]::IsNullOrWhiteSpace($uninstallStr))
                    }
                }
            } catch { Add-ProbeFault $_.Exception }
        }
    }
}

Record-Probe 'InstallerUserData' {
    $currentSid = $id.User.Value
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData'
    if (-not (Test-Path -LiteralPath $root)) { return }
    foreach ($owner in @(Get-ChildItem -LiteralPath $root -ErrorAction Stop)) {
        try {
            $products = Join-Path $owner.PSPath 'Products'
            if (-not (Test-Path -LiteralPath $products)) { continue }
            foreach ($key in @(Get-ChildItem -LiteralPath $products -ErrorAction Stop)) {
                try {
                    $path = Join-Path $key.PSPath 'InstallProperties'
                    if (-not (Test-Path -LiteralPath $path)) { continue }
                    $props = Get-Item -LiteralPath $path -ErrorAction Stop
                    $scope = switch ($owner.PSChildName) {
                        'S-1-5-18' { 'Machine' }
                        $currentSid { 'CurrentUser' }
                        default { 'OtherUser' }
                    }
                    Get-MsiProductEvidence $props $key.PSChildName $scope
                } catch { Add-ProbeFault $_.Exception }
            }
        } catch { Add-ProbeFault $_.Exception }
    }
}

foreach ($base in @('HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node')) {
    Record-Probe "SqlInstanceMap $base" {
        $root = Join-Path $base 'Microsoft\Microsoft SQL Server\Instance Names\SQL'
        if (Test-Path -LiteralPath $root) { (Get-Item -LiteralPath $root -ErrorAction Stop).GetValueNames() }
    }
    Record-Probe "SqlBranches $base" {
        $root = Join-Path $base 'Microsoft\Microsoft SQL Server'
        if (Test-Path -LiteralPath $root) { (Get-Item -LiteralPath $root -ErrorAction Stop).GetSubKeyNames() }
    }
}

Record-Probe 'Services' {
    foreach ($svc in @(Get-CimInstance Win32_Service -Property Name,DisplayName,State,StartMode,PathName -ErrorAction Stop)) {
        $kind = Get-ProductCategory ($svc.Name + ' ' + $svc.DisplayName + ' ' + $svc.PathName)
        if ($kind) {
            [pscustomobject]@{
                Name = $svc.Name
                DisplayName = $svc.DisplayName
                State = $svc.State
                StartMode = $svc.StartMode
                PathName = $svc.PathName
                Category = $kind
            }
        }
    }
}

Record-Probe 'RsFxDrivers' {
    Get-CimInstance Win32_SystemDriver -Property Name,State,StartMode -ErrorAction Stop |
        Where-Object Name -match '^RsFx\d+$' | Select-Object Name,State,StartMode
}

Record-Probe 'RsFxServiceKeys' {
    $svcRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services'
    foreach ($key in @(Get-ChildItem -LiteralPath $svcRoot -ErrorAction Stop)) {
        try {
            if ($key.PSChildName -match '^RsFx\d+$') { $key.PSChildName }
        } catch { Add-ProbeFault $_.Exception }
    }
}

Record-Probe 'RsFxDriverFiles' {
    $drvDir = Join-Path $env:SystemRoot 'System32\drivers'
    if (Test-Path -LiteralPath $drvDir) {
        Get-ChildItem -LiteralPath $drvDir -Filter 'RsFx*.sys' -File -Force -ErrorAction Stop |
            Select-Object -ExpandProperty Name
    }
}

Record-Probe 'LicenseFileMetadata' {
    $root = Join-Path $env:ProgramData 'FLEXnet'
    if (Test-Path -LiteralPath $root) {
        Get-ChildItem -LiteralPath $root -Filter 'SW_D_*' -File -Force -ErrorAction Stop | Select-Object Name,Length
    }
}

foreach ($base in @('HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node', 'HKCU:\Software')) {
    Record-Probe "LicenseValueNames $base" {
        $root = Join-Path $base 'FLEXlm License Manager'
        if (Test-Path -LiteralPath $root) {
            (Get-Item -LiteralPath $root -ErrorAction Stop).GetValueNames() | Where-Object { $_ -in 'SW_D_LICENSE_FILE','SEEMAGE_LICENSE_FILE' }
        }
    }
}

Record-Probe 'ExcludeFromKnownDlls' {
    $sm = Get-Item -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
    $hasVal = $sm.GetValueNames() -contains 'ExcludeFromKnownDlls'
    $count = if ($hasVal) {
        @($sm.GetValue('ExcludeFromKnownDlls') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
    } else { 0 }
    [pscustomobject]@{ ValueExists=$hasVal; NonEmptyEntryCount=$count }
}

$paths = @(
    (Join-Path $env:ProgramData 'SOLIDWORKS Electrical')
    (Join-Path $env:ProgramData 'SOLIDWORKS')
    (Join-Path $env:ProgramFiles 'SOLIDWORKS Corp')
    (Join-Path $env:CommonProgramFiles 'SOLIDWORKS Shared')
    (Join-Path $env:ProgramFiles 'Microsoft SQL Server')
    (Join-Path $env:APPDATA 'SOLIDWORKS')
    (Join-Path $env:LOCALAPPDATA 'SOLIDWORKS')
    (Join-Path $env:TEMP 'SOLIDWORKS')
    (Join-Path ([Environment]::GetFolderPath('CommonDocuments')) 'SOLIDWORKS')
)
if (${env:ProgramFiles(x86)}) {
    $paths += (Join-Path ${env:ProgramFiles(x86)} 'SOLIDWORKS Corp')
    $paths += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft SQL Server')
}
if (${env:CommonProgramFiles(x86)}) {
    $paths += (Join-Path ${env:CommonProgramFiles(x86)} 'SOLIDWORKS Shared')
}
if ($env:SystemDrive) {
    $paths += (Join-Path ($env:SystemDrive + '\') 'SOLIDWORKS Data')
    $paths += (Join-Path ($env:SystemDrive + '\') 'SOLIDWORKS Downloads')
}
$paths += $AdditionalPath

Record-Probe 'Paths' {
    foreach ($path in @($paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        try {
            [pscustomobject]@{ Path=$path; Exists=(Test-Path -LiteralPath $path) }
        } catch { Add-ProbeFault $_.Exception }
    }
}

$artifactPattern = 'SOLIDWORKS|eDrawings|sldim|sldworks|ewserver|TEW_SQLEXPRESS|SolidNetWork|Seemage'

Record-Probe 'Tasks' {
    foreach ($task in @(Get-ScheduledTask -ErrorAction Stop)) {
        $match = $task.TaskName -match $artifactPattern
        foreach ($action in $task.Actions) {
            if (($action.Execute + ' ' + $action.Arguments) -match $artifactPattern) { $match = $true }
        }
        if ($match) { [pscustomobject]@{ Name=$task.TaskName; Folder=$task.TaskPath } }
    }
}

Record-Probe 'Startup' {
    Get-CimInstance Win32_StartupCommand -Property Name,Command -ErrorAction Stop |
        Where-Object { ($_.Name + ' ' + $_.Command) -match $artifactPattern } | Select-Object -ExpandProperty Name
}

Record-Probe 'FirewallPrograms' {
    Get-NetFirewallApplicationFilter -ErrorAction Stop | Where-Object Program -match $artifactPattern |
        Select-Object -ExpandProperty Program -Unique
}

$summary = [ordered]@{
    Status = if ($faults.Count) { 'Incomplete' } else { 'CheckedListedScopes' }
    Context = $context
    Checks = @($checks.GetEnumerator() | ForEach-Object {
        if ($_.Key -eq 'Paths') {
            [pscustomobject]@{
                Check = $_.Key
                Status = $_.Value.Status
                Rows = @($_.Value.Items | Where-Object { $_.Exists }).Count
                TotalChecked = $_.Value.Items.Count
            }
        } else {
            [pscustomobject]@{ Check=$_.Key; Status=$_.Value.Status; Rows=$_.Value.Items.Count }
        }
    })
    Errors = $faults.ToArray()
}
if ($OutFile) {
    $report = [ordered]@{ Summary=$summary; Evidence=$checks }
    Write-NewAuditFile $OutFile ($report | ConvertTo-Json -Depth 8)
}
$summary | ConvertTo-Json -Depth 5
