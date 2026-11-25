function Get-ProductCategory([string]$Label) {
    if ($Label -match 'SOLIDWORKS|eDrawings|SolidNetWork|TEW_SQLEXPRESS|\bsld(?:works|im)\b') {
        return 'ProductCandidate'
    }
    if ($Label -match '\bSQL Server\b|^RsFx[0-9]+$|^SQL(?:Browser|Writer)$|\bFlexNet\b') {
        return 'SharedComponent'
    }
    return $null
}

function ConvertFrom-PackedProductCode([string]$Code) {
    if ($Code -notmatch '^[0-9a-fA-F]{32}$') { throw 'Invalid MSI product key' }
    $tail = for ($i = 16; $i -lt 32; $i += 2) { [string]$Code[$i+1] + $Code[$i] }
    $tail = $tail -join ''
    '{' + (-join $Code[7..0]) + '-' + (-join $Code[11..8]) + '-' +
        (-join $Code[15..12]) + '-' + $tail.Substring(0,4) + '-' + $tail.Substring(4) + '}'
}

function Get-CurrentMsiState([string]$ProductCode) {
    [SwResidue.Product]::MsiQueryProductStateW($ProductCode)
}

function Get-MsiProductEvidence($Properties, [string]$PackedCode, [string]$Scope) {
    $name = [string]$Properties.GetValue('DisplayName')
    $kind = Get-ProductCategory $name
    if (!$kind) { return }
    $guid = ConvertFrom-PackedProductCode $PackedCode
    $cache = $Properties.GetValue('LocalPackage')
    [pscustomobject]@{
        Name = $name
        Category = $kind
        ProductCode = $guid
        RecordScope = $Scope
        CurrentContextState = Get-CurrentMsiState $guid
        CacheExists = if ($cache) { Test-Path -LiteralPath $cache } else { $false }
        MachineUninstall64 = Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$guid"
        MachineUninstall32 = Test-Path -LiteralPath "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$guid"
    }
}

function Write-NewAuditFile([string]$Path, [string]$Json) {
    $nativePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ([IO.Path]::GetExtension($nativePath) -ine '.json') { throw 'Choose a new .json file.' }
    $stream = [IO.File]::Open($nativePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Json)
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
}
