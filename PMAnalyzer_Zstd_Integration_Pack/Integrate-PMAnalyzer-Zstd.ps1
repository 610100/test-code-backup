[CmdletBinding()]
param(
    [string]$ProjectZip,
    [string]$ZstdZip,
    [string]$DictionaryZip,
    [string]$OutputZip,
    [switch]$Build,
    [string]$BuildConfiguration = 'Debug',
    [string]$BuildPlatform = 'x86',
    [switch]$KeepWork
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$coreScript = Join-Path $PSScriptRoot 'Integrate-PMAnalyzer-Zstd.Core.ps1'
if (-not (Test-Path -LiteralPath $coreScript -PathType Leaf)) {
    throw ('Integration core script was not found: ' + $coreScript)
}

# The old source variants use either a direct CheckTable call or the public
# UpdateDatabase wrapper. Generate a same-directory temporary script so that
# $PSScriptRoot still points to this integration pack's Files directory.
$text = [IO.File]::ReadAllText($coreScript)
$oldPattern = 'DataBaseHelper\\s*\\.\\s*CheckTable\\s*\\('
$newPattern = 'DataBaseHelper\\s*\\.\\s*(?:CheckTable|UpdateDatabase)\\s*\\('

if ($text.IndexOf($oldPattern, [StringComparison]::Ordinal) -ge 0) {
    $text = $text.Replace($oldPattern, $newPattern)
}
elseif ($text.IndexOf($newPattern, [StringComparison]::Ordinal) -lt 0) {
    throw 'The startup database-call matcher in the integration core was not recognized.'
}

$text = $text.Replace(
    'The startup call to DataBaseHelper.CheckTable was not found in EDX.UserControl.',
    'The startup call to DataBaseHelper.UpdateDatabase/CheckTable was not found in EDX.UserControl.')
$text = $text.Replace(
    'DataBaseHelper.CheckTable call was not found:',
    'DataBaseHelper.UpdateDatabase/CheckTable call was not found:')
$text = $text.Replace(
    'The end of DataBaseHelper.CheckTable call was not found:',
    'The end of DataBaseHelper.UpdateDatabase/CheckTable call was not found:')

$fixedScript = Join-Path $PSScriptRoot ('_Integrate-PMAnalyzer-Zstd.Fixed.' + [Guid]::NewGuid().ToString('N') + '.ps1')
$encoding = New-Object Text.UTF8Encoding($true)
[IO.File]::WriteAllText($fixedScript, $text, $encoding)

$arguments = @{
    BuildConfiguration = $BuildConfiguration
    BuildPlatform = $BuildPlatform
}
if (-not [String]::IsNullOrEmpty($ProjectZip)) { $arguments.ProjectZip = $ProjectZip }
if (-not [String]::IsNullOrEmpty($ZstdZip)) { $arguments.ZstdZip = $ZstdZip }
if (-not [String]::IsNullOrEmpty($DictionaryZip)) { $arguments.DictionaryZip = $DictionaryZip }
if (-not [String]::IsNullOrEmpty($OutputZip)) { $arguments.OutputZip = $OutputZip }
if ($Build.IsPresent) { $arguments.Build = $true }
if ($KeepWork.IsPresent) { $arguments.KeepWork = $true }

$exitCode = 0
try {
    & $fixedScript @arguments
}
catch {
    Write-Error $_.Exception.ToString()
    $exitCode = 1
}
finally {
    Remove-Item -LiteralPath $fixedScript -Force -ErrorAction SilentlyContinue
}

exit $exitCode
