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

function Write-Step([string]$Text) {
    Write-Host ('[PMAnalyzer-Zstd] ' + $Text)
}

function Resolve-RequiredFile([string]$Path, [string]$DisplayName) {
    if ([String]::IsNullOrEmpty($Path)) {
        throw ($DisplayName + ' was not specified.')
    }

    if (-not [IO.Path]::IsPathRooted($Path)) {
        $Path = Join-Path $PSScriptRoot $Path
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ($DisplayName + ' was not found: ' + $Path)
    }

    return (Get-Item -LiteralPath $Path).FullName
}

function Find-DefaultProjectZip {
    $items = @(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter 'PMAnalyzer*.zip' |
        Where-Object {
            $_.Name -notmatch 'ZstdSharp' -and
            $_.Name -notmatch 'Dictionary' -and
            $_.Name -notmatch 'ZstdIntegrated'
        } |
        Sort-Object LastWriteTime -Descending)

    if ($items.Count -eq 0) {
        throw 'No PMAnalyzer project ZIP was found beside this script. Use -ProjectZip.'
    }
    return $items[0].FullName
}

function Find-DefaultZip([string]$ExactName, [string]$Pattern, [string]$DisplayName) {
    $exact = Join-Path $PSScriptRoot $ExactName
    if (Test-Path -LiteralPath $exact -PathType Leaf) {
        return (Get-Item -LiteralPath $exact).FullName
    }

    $items = @(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter $Pattern |
        Sort-Object LastWriteTime -Descending)
    if ($items.Count -eq 0) {
        throw ('No ' + $DisplayName + ' ZIP was found beside this script.')
    }
    return $items[0].FullName
}

function Expand-ZipFile([string]$ZipPath, [string]$Destination) {
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
}

function Get-Sha256Hex([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = $sha.ComputeHash($stream)
        }
        finally {
            $sha.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }

    return ([BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant())
}

function Read-TextFileInfo([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $offset = 0
    $encoding = $null

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = New-Object Text.UTF8Encoding($true)
        $offset = 3
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = New-Object Text.UnicodeEncoding($false, $true)
        $offset = 2
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = New-Object Text.UnicodeEncoding($true, $true)
        $offset = 2
    }
    else {
        try {
            $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
            [void]$strictUtf8.GetString($bytes)
            $encoding = New-Object Text.UTF8Encoding($false)
        }
        catch {
            $encoding = [Text.Encoding]::Default
        }
    }

    $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
    return New-Object PSObject -Property @{
        Text = $text
        Encoding = $encoding
    }
}

function Write-TextFileInfo([string]$Path, [string]$Text, [Text.Encoding]$Encoding) {
    $body = $Encoding.GetBytes($Text)
    $preamble = $Encoding.GetPreamble()
    $all = New-Object byte[] ($preamble.Length + $body.Length)
    if ($preamble.Length -ne 0) {
        [Buffer]::BlockCopy($preamble, 0, $all, 0, $preamble.Length)
    }
    if ($body.Length -ne 0) {
        [Buffer]::BlockCopy($body, 0, $all, $preamble.Length, $body.Length)
    }
    [IO.File]::WriteAllBytes($Path, $all)
}

function Find-UniqueFile([string]$Root, [string]$RelativeSuffix, [string]$DisplayName) {
    $normalizedSuffix = $RelativeSuffix.Replace('/', '\').ToLowerInvariant()
    $matches = @(Get-ChildItem -LiteralPath $Root -Recurse -File |
        Where-Object {
            $_.FullName.Replace('/', '\').ToLowerInvariant().EndsWith($normalizedSuffix)
        } |
        Sort-Object { $_.FullName.Length })

    if ($matches.Count -eq 0) {
        throw ($DisplayName + ' was not found under: ' + $Root)
    }
    return $matches[0].FullName
}

function Select-ZstdDll([string]$Root) {
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter 'ZstdSharp.dll')
    if ($files.Count -eq 0) {
        return $null
    }

    $ranked = foreach ($file in $files) {
        $lower = $file.FullName.ToLowerInvariant()
        $score = 0
        if ($lower -match '[\\/]release[\\/]') { $score += 500 }
        if ($lower -match 'net35|framework35|clr2') { $score += 400 }
        if ($lower -notmatch 'test|benchmark|sample') { $score += 100 }
        if ($lower -match 'runtime') { $score += 50 }
        New-Object PSObject -Property @{ File = $file; Score = $score }
    }

    $selected = @($ranked | Sort-Object @{Expression='Score';Descending=$true}, @{Expression={$_.File.FullName.Length};Ascending=$true})[0]
    return $selected.File.FullName
}

function Build-ZstdIfNeeded([string]$Root) {
    $dll = Select-ZstdDll $Root
    if ($null -ne $dll) {
        return $dll
    }

    $buildFiles = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter 'build.bat' |
        Sort-Object { $_.FullName.Length })
    if ($buildFiles.Count -eq 0) {
        throw 'ZstdSharp.dll was not present and build.bat was not found in the Zstd package.'
    }

    $buildBat = $buildFiles[0].FullName
    Write-Step ('Building ZstdSharp .NET 3.5: ' + $buildBat)
    $process = Start-Process -FilePath 'cmd.exe' `
        -ArgumentList @('/d', '/c', ('"' + $buildBat + '"')) `
        -WorkingDirectory (Split-Path -Parent $buildBat) `
        -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) {
        throw ('ZstdSharp build failed with exit code ' + $process.ExitCode.ToString() + '.')
    }

    $dll = Select-ZstdDll $Root
    if ($null -eq $dll) {
        throw 'ZstdSharp build completed but ZstdSharp.dll was not found.'
    }
    return $dll
}

function Select-SpectrumDictionary([string]$Root) {
    $candidates = @(Get-ChildItem -LiteralPath $Root -Recurse -File |
        Where-Object {
            $_.Length -eq 4096 -and
            ($_.Extension -ieq '.zdict' -or $_.Extension -ieq '.dict' -or $_.Extension -ieq '.bin')
        })

    if ($candidates.Count -eq 0) {
        throw 'No 4096-byte dictionary was found in the dictionary package.'
    }

    $metricMatches = @()
    $textFiles = @(Get-ChildItem -LiteralPath $Root -Recurse -File |
        Where-Object { $_.Extension -match '^\.(csv|txt|md|json|tsv)$' })
    foreach ($textFile in $textFiles) {
        try {
            $lines = @(Get-Content -LiteralPath $textFile.FullName -ErrorAction Stop)
            foreach ($line in $lines) {
                if ($line -match '26\.735881' -and $line -match '62\.283' -and $line -match '21\.063') {
                    $metricMatches += $line
                }
            }
        }
        catch {
        }
    }

    foreach ($line in $metricMatches) {
        foreach ($candidate in $candidates) {
            if ($line.IndexOf($candidate.Name, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $line.IndexOf($candidate.BaseName, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return $candidate.FullName
            }
        }
    }

    $ranked = foreach ($candidate in $candidates) {
        $name = $candidate.Name.ToLowerInvariant()
        $score = 0
        if ($name -match 'fastcover') { $score += 1000 }
        if ($name -match 'auto|automatic') { $score += 500 }
        if ($name -match '(^|[_\-.])level[_\-.]?1([^0-9]|$)|(^|[_\-.])l1([^0-9]|$)') { $score += 300 }
        if ($name -match '4k|4096') { $score += 200 }
        if ($name -match 'spectrumdata|spectrum') { $score += 100 }
        if ($name -match 'v2') { $score += 50 }
        New-Object PSObject -Property @{ File = $candidate; Score = $score }
    }

    $ordered = @($ranked | Sort-Object @{Expression='Score';Descending=$true}, @{Expression={$_.File.Name};Ascending=$true})
    if ($ordered.Count -gt 1 -and $ordered[0].Score -eq $ordered[1].Score) {
        $names = ($ordered | ForEach-Object { $_.File.FullName }) -join [Environment]::NewLine
        throw ('The exact FastCover Auto level-1 4K dictionary could not be selected uniquely:' + [Environment]::NewLine + $names)
    }

    if ($ordered[0].Score -lt 1200 -and $candidates.Count -gt 1) {
        throw ('The highest-ranked 4096-byte dictionary does not look like FastCover Auto 4K: ' + $ordered[0].File.FullName)
    }

    return $ordered[0].File.FullName
}

function Add-ProjectXmlBlock([string]$ProjectPath, [string]$Marker, [string]$Block) {
    $info = Read-TextFileInfo $ProjectPath
    if ($info.Text.IndexOf($Marker, [StringComparison]::Ordinal) -ge 0) {
        return
    }

    $index = $info.Text.LastIndexOf('</Project>', [StringComparison]::OrdinalIgnoreCase)
    if ($index -lt 0) {
        throw ('Invalid MSBuild project file: ' + $ProjectPath)
    }

    $newline = if ($info.Text.IndexOf("`r`n", [StringComparison]::Ordinal) -ge 0) { "`r`n" } else { "`n" }
    $normalizedBlock = $Block -replace "`r?`n", $newline
    $updated = $info.Text.Insert($index, $normalizedBlock + $newline)
    Write-TextFileInfo $ProjectPath $updated $info.Encoding
}

function Find-MatchingBrace([string]$Text, [int]$OpenIndex) {
    $depth = 0
    $state = 0

    for ($i = $OpenIndex; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        $n = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }

        if ($state -eq 1) {
            if ($c -eq "`n") { $state = 0 }
            continue
        }
        if ($state -eq 2) {
            if ($c -eq '*' -and $n -eq '/') { $state = 0; $i++; }
            continue
        }
        if ($state -eq 3) {
            if ($c -eq '\') { $i++; continue }
            if ($c -eq '"') { $state = 0 }
            continue
        }
        if ($state -eq 4) {
            if ($c -eq '\') { $i++; continue }
            if ($c -eq "'") { $state = 0 }
            continue
        }
        if ($state -eq 5) {
            if ($c -eq '"') {
                if ($n -eq '"') { $i++; }
                else { $state = 0 }
            }
            continue
        }

        if ($c -eq '/' -and $n -eq '/') { $state = 1; $i++; continue }
        if ($c -eq '/' -and $n -eq '*') { $state = 2; $i++; continue }
        if ($c -eq '@' -and $n -eq '"') { $state = 5; $i++; continue }
        if ($c -eq '"') { $state = 3; continue }
        if ($c -eq "'") { $state = 4; continue }
        if ($c -eq '{') { $depth++; continue }
        if ($c -eq '}') {
            $depth--
            if ($depth -eq 0) { return $i }
        }
    }

    return -1
}

function Patch-SerializeHelper([string]$Path) {
    $info = Read-TextFileInfo $Path
    $text = $info.Text
    if ($text.IndexOf('ZSTD-SPECTRUM-HOOK', [StringComparison]::Ordinal) -ge 0) {
        return
    }

    $serializePattern = '(?m)^[ \t]*public[ \t]+static[ \t]+byte[ \t]*\[[ \t]*\][ \t]+(?<method>Serialize)[ \t]*\([ \t]*(?<ptype>[A-Za-z_@][A-Za-z0-9_@\.<>\[\], \t]*?)[ \t]+(?<pname>@?[A-Za-z_][A-Za-z0-9_]*)[ \t]*\)'
    $serializeRegex = New-Object Text.RegularExpressions.Regex($serializePattern)
    $serializeMatch = $serializeRegex.Match($text)
    if (-not $serializeMatch.Success) {
        throw ('SerializeHelper.Serialize(byte[]) declaration was not recognized: ' + $Path)
    }

    $serializeType = $serializeMatch.Groups['ptype'].Value.Trim()
    $serializeName = $serializeMatch.Groups['pname'].Value
    $methodGroup = $serializeMatch.Groups['method']
    $text = $text.Substring(0, $methodGroup.Index) + 'SerializeRaw' + $text.Substring($methodGroup.Index + $methodGroup.Length)

    $deserializePattern = '(?m)^[ \t]*public[ \t]+static[ \t]+T[ \t]+(?<method>Deserialize)[ \t]*<[ \t]*T[ \t]*>[ \t]*\([ \t]*byte[ \t]*\[[ \t]*\][ \t]+(?<pname>@?[A-Za-z_][A-Za-z0-9_]*)[ \t]*\)'
    $deserializeRegex = New-Object Text.RegularExpressions.Regex($deserializePattern)
    $deserializeMatch = $deserializeRegex.Match($text)
    if (-not $deserializeMatch.Success) {
        throw ('SerializeHelper.Deserialize<T>(byte[]) declaration was not recognized: ' + $Path)
    }

    $deserializeName = $deserializeMatch.Groups['pname'].Value
    $methodGroup = $deserializeMatch.Groups['method']
    $text = $text.Substring(0, $methodGroup.Index) + 'DeserializeRaw' + $text.Substring($methodGroup.Index + $methodGroup.Length)

    $classMatch = [Text.RegularExpressions.Regex]::Match($text, '\bclass[ \t]+SerializeHelper\b')
    if (-not $classMatch.Success) {
        throw ('SerializeHelper class declaration was not found: ' + $Path)
    }

    $openBrace = $text.IndexOf('{', $classMatch.Index + $classMatch.Length)
    if ($openBrace -lt 0) {
        throw ('SerializeHelper class opening brace was not found: ' + $Path)
    }
    $closeBrace = Find-MatchingBrace $text $openBrace
    if ($closeBrace -lt 0) {
        throw ('SerializeHelper class closing brace was not found: ' + $Path)
    }

    $newline = if ($text.IndexOf("`r`n", [StringComparison]::Ordinal) -ge 0) { "`r`n" } else { "`n" }
    $wrapper = @"

        // ZSTD-SPECTRUM-HOOK: only SpecListEntity is compressed.
        // Other configuration/menu BinaryFormatter payloads keep their original bytes.
        public static byte[] Serialize($serializeType $serializeName)
        {
            byte[] rawData = SerializeRaw($serializeName);
            if ($serializeName is Htekray.EDXRFLibrary.Spectrum.SpecListEntity)
                return SpectrumDataCompression.Compress(rawData);
            return rawData;
        }

        public static T Deserialize<T>(byte[] $deserializeName)
        {
            byte[] rawData = $deserializeName;
            if (typeof(T) == typeof(Htekray.EDXRFLibrary.Spectrum.SpecListEntity))
                rawData = SpectrumDataCompression.Decompress($deserializeName);
            return DeserializeRaw<T>(rawData);
        }
"@
    $wrapper = $wrapper -replace "`r?`n", $newline
    $text = $text.Insert($closeBrace, $wrapper)
    Write-TextFileInfo $Path $text $info.Encoding
}

function Find-StartupFile([string]$UserControlDirectory) {
    $preferred = @(Get-ChildItem -LiteralPath $UserControlDirectory -Recurse -File -Filter 'InitHelper.cs')
    foreach ($file in $preferred) {
        $info = Read-TextFileInfo $file.FullName
        if ($info.Text -match 'DataBaseHelper\s*\.\s*CheckTable\s*\(') {
            return $file.FullName
        }
    }

    $all = @(Get-ChildItem -LiteralPath $UserControlDirectory -Recurse -File -Filter '*.cs')
    foreach ($file in $all) {
        $info = Read-TextFileInfo $file.FullName
        if ($info.Text -match 'DataBaseHelper\s*\.\s*CheckTable\s*\(') {
            return $file.FullName
        }
    }

    throw 'The startup call to DataBaseHelper.CheckTable was not found in EDX.UserControl.'
}

function Patch-Startup([string]$Path) {
    $info = Read-TextFileInfo $Path
    $text = $info.Text
    if ($text.IndexOf('ZSTD-SPECTRUM-UPGRADE', [StringComparison]::Ordinal) -ge 0) {
        return
    }

    $match = [Text.RegularExpressions.Regex]::Match($text, 'DataBaseHelper\s*\.\s*CheckTable\s*\(')
    if (-not $match.Success) {
        throw ('DataBaseHelper.CheckTable call was not found: ' + $Path)
    }

    $semicolon = $text.IndexOf(';', $match.Index + $match.Length)
    if ($semicolon -lt 0) {
        throw ('The end of DataBaseHelper.CheckTable call was not found: ' + $Path)
    }

    $lineStart = $text.LastIndexOf("`n", $match.Index)
    if ($lineStart -lt 0) { $lineStart = 0 } else { $lineStart++ }
    $indentMatch = [Text.RegularExpressions.Regex]::Match($text.Substring($lineStart, $match.Index - $lineStart), '^[ \t]*')
    $indent = $indentMatch.Value
    $newline = if ($text.IndexOf("`r`n", [StringComparison]::Ordinal) -ge 0) { "`r`n" } else { "`n" }
    $insertion = $newline + $indent + 'JPSPEC.SpectrumDataUpgradeForm.EnsureUpgraded(); // ZSTD-SPECTRUM-UPGRADE'
    $text = $text.Insert($semicolon + 1, $insertion)
    Write-TextFileInfo $Path $text $info.Encoding
}

function Find-MSBuild {
    $command = Get-Command 'MSBuild.exe' -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $path = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
        if (-not [String]::IsNullOrEmpty($path)) {
            return $path
        }
    }

    return $null
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if ([String]::IsNullOrEmpty($ProjectZip)) {
    $ProjectZip = Find-DefaultProjectZip
}
if ([String]::IsNullOrEmpty($ZstdZip)) {
    $ZstdZip = Find-DefaultZip 'ZstdSharp-Net35-runtime-fix.zip' '*ZstdSharp*runtime*fix*.zip' 'ZstdSharp runtime-fix'
}
if ([String]::IsNullOrEmpty($DictionaryZip)) {
    $DictionaryZip = Find-DefaultZip 'SpectrumData_Zstd_Dictionary_Pack_v2.zip' '*SpectrumData*Dictionary*Pack*.zip' 'SpectrumData dictionary pack'
}

$ProjectZip = Resolve-RequiredFile $ProjectZip 'Project ZIP'
$ZstdZip = Resolve-RequiredFile $ZstdZip 'ZstdSharp ZIP'
$DictionaryZip = Resolve-RequiredFile $DictionaryZip 'Dictionary ZIP'

if ([String]::IsNullOrEmpty($OutputZip)) {
    $OutputZip = Join-Path (Split-Path -Parent $ProjectZip) (([IO.Path]::GetFileNameWithoutExtension($ProjectZip)) + '_ZstdIntegrated.zip')
}
elseif (-not [IO.Path]::IsPathRooted($OutputZip)) {
    $OutputZip = Join-Path (Get-Location).Path $OutputZip
}
$OutputZip = [IO.Path]::GetFullPath($OutputZip)

$workRoot = Join-Path ([IO.Path]::GetTempPath()) ('PMAnalyzer_Zstd_' + [Guid]::NewGuid().ToString('N'))
$projectWork = Join-Path $workRoot 'project'
$zstdWork = Join-Path $workRoot 'zstd'
$dictionaryWork = Join-Path $workRoot 'dictionary'

try {
    Write-Step 'Extracting source and integration packages.'
    Expand-ZipFile $ProjectZip $projectWork
    Expand-ZipFile $ZstdZip $zstdWork
    Expand-ZipFile $DictionaryZip $dictionaryWork

    $serializeHelper = Find-UniqueFile $projectWork 'AppCore\EDX.DataLib\Helper\SerializeHelper.cs' 'SerializeHelper.cs'
    $dataLibDirectory = Split-Path -Parent (Split-Path -Parent $serializeHelper)
    $sourceRoot = Split-Path -Parent (Split-Path -Parent $dataLibDirectory)
    $userControlDirectory = Join-Path (Split-Path -Parent $dataLibDirectory) 'EDX.UserControl'

    $dataLibProject = Join-Path $dataLibDirectory 'EDX.DataLib.csproj'
    $userControlProject = Join-Path $userControlDirectory 'EDX.UserControl.csproj'
    if (-not (Test-Path -LiteralPath $dataLibProject -PathType Leaf)) {
        throw ('EDX.DataLib.csproj was not found: ' + $dataLibProject)
    }
    if (-not (Test-Path -LiteralPath $userControlProject -PathType Leaf)) {
        throw ('EDX.UserControl.csproj was not found: ' + $userControlProject)
    }

    $templateDirectory = Join-Path $PSScriptRoot 'Files'
    $compressionTemplate = Resolve-RequiredFile (Join-Path $templateDirectory 'SpectrumDataCompression.cs') 'SpectrumDataCompression.cs template'
    $formTemplate = Resolve-RequiredFile (Join-Path $templateDirectory 'SpectrumDataUpgradeForm.cs') 'SpectrumDataUpgradeForm.cs template'

    Write-Step 'Selecting the requested FastCover Auto level-1 4K dictionary.'
    $selectedDictionary = Select-SpectrumDictionary $dictionaryWork
    if ((Get-Item -LiteralPath $selectedDictionary).Length -ne 4096) {
        throw 'Selected dictionary is not exactly 4096 bytes.'
    }

    Write-Step 'Locating or building ZstdSharp.dll for .NET Framework 3.5.'
    $zstdDll = Build-ZstdIfNeeded $zstdWork

    $helperDirectory = Join-Path $dataLibDirectory 'Helper'
    $resourceDirectory = Join-Path $dataLibDirectory 'Resources'
    $libraryDirectory = Join-Path $dataLibDirectory 'Lib'
    $formDirectory = Join-Path $userControlDirectory 'Forms'
    $thirdPartyDirectory = Join-Path $sourceRoot 'ThirdParty\PMAnalyzer-Zstd'
    foreach ($directory in @($helperDirectory, $resourceDirectory, $libraryDirectory, $formDirectory, $thirdPartyDirectory)) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }

    $compressionTarget = Join-Path $helperDirectory 'SpectrumDataCompression.cs'
    $formTarget = Join-Path $formDirectory 'SpectrumDataUpgradeForm.cs'
    $dictionaryTarget = Join-Path $resourceDirectory 'SpectrumData_FastCoverAuto_Level1_4K_v2.zdict'
    $zstdTarget = Join-Path $libraryDirectory 'ZstdSharp.dll'

    Copy-Item -LiteralPath $compressionTemplate -Destination $compressionTarget -Force
    Copy-Item -LiteralPath $formTemplate -Destination $formTarget -Force
    Copy-Item -LiteralPath $selectedDictionary -Destination $dictionaryTarget -Force
    Copy-Item -LiteralPath $zstdDll -Destination $zstdTarget -Force
    Copy-Item -LiteralPath $ZstdZip -Destination (Join-Path $thirdPartyDirectory 'ZstdSharp-Net35-runtime-fix.zip') -Force
    Copy-Item -LiteralPath $DictionaryZip -Destination (Join-Path $thirdPartyDirectory 'SpectrumData_Zstd_Dictionary_Pack_v2.zip') -Force

    $license = @(Get-ChildItem -LiteralPath $zstdWork -Recurse -File |
        Where-Object { $_.Name -match '^LICENSE(\.|$)|^COPYING(\.|$)' } |
        Sort-Object { $_.FullName.Length } | Select-Object -First 1)
    if ($license.Count -ne 0) {
        Copy-Item -LiteralPath $license[0].FullName -Destination (Join-Path $thirdPartyDirectory 'ZstdSharp-LICENSE.txt') -Force
    }

    Write-Step 'Adding the type-gated SerializeHelper hook.'
    Patch-SerializeHelper $serializeHelper

    Write-Step 'Adding the database upgrade splash after CheckTable.'
    $startupFile = Find-StartupFile $userControlDirectory
    Patch-Startup $startupFile

    $dataLibBlock = @'
  <!-- ZSTD-SPECTRUM-INTEGRATION -->
  <ItemGroup>
    <Compile Include="Helper\SpectrumDataCompression.cs" />
    <EmbeddedResource Include="Resources\SpectrumData_FastCoverAuto_Level1_4K_v2.zdict" />
  </ItemGroup>
  <ItemGroup>
    <Reference Include="System.Data" />
    <Reference Include="ZstdSharp">
      <HintPath>Lib\ZstdSharp.dll</HintPath>
      <Private>True</Private>
    </Reference>
  </ItemGroup>
'@
    Add-ProjectXmlBlock $dataLibProject 'ZSTD-SPECTRUM-INTEGRATION' $dataLibBlock

    $userControlBlock = @'
  <!-- ZSTD-SPECTRUM-UPGRADE-FORM -->
  <ItemGroup>
    <Compile Include="Forms\SpectrumDataUpgradeForm.cs" />
  </ItemGroup>
'@
    Add-ProjectXmlBlock $userControlProject 'ZSTD-SPECTRUM-UPGRADE-FORM' $userControlBlock

    $dictionaryHash = Get-Sha256Hex $dictionaryTarget
    $zstdHash = Get-Sha256Hex $zstdTarget
    $reportPath = Join-Path $sourceRoot 'ZSTD_SPECTRUM_INTEGRATION.md'
    $report = @"
# PMAnalyzer SpectrumData Zstd integration

Generated by Integrate-PMAnalyzer-Zstd.ps1.

- Dictionary profile: FastCover Auto 4K, level 1
- Dictionary bytes: 4096
- Benchmark row: 26.735881 / 62.283 / 21.063
- Dictionary SHA-256: $dictionaryHash
- ZstdSharp.dll SHA-256: $zstdHash
- Storage envelope: SPZSTD01, version 1, original length, dictionary tag and CRC32
- Database table: SpectrumCompressionDictionary
- Migration: one SQLite transaction, batches of 128 rows, prepared UPDATE command
- Compatibility: legacy BinaryFormatter bytes pass through unchanged; only SpecListEntity is compressed

Modified or added files:

- AppCore/EDX.DataLib/Helper/SerializeHelper.cs
- AppCore/EDX.DataLib/Helper/SpectrumDataCompression.cs
- AppCore/EDX.DataLib/Resources/SpectrumData_FastCoverAuto_Level1_4K_v2.zdict
- AppCore/EDX.DataLib/Lib/ZstdSharp.dll
- AppCore/EDX.DataLib/EDX.DataLib.csproj
- AppCore/EDX.UserControl/Forms/SpectrumDataUpgradeForm.cs
- AppCore/EDX.UserControl/EDX.UserControl.csproj
- $($startupFile.Substring($sourceRoot.Length).TrimStart('\', '/'))

The original input ZIP is never modified.
"@
    [IO.File]::WriteAllText($reportPath, $report, (New-Object Text.UTF8Encoding($true)))

    $manifestFiles = @($compressionTarget, $formTarget, $dictionaryTarget, $zstdTarget, $serializeHelper, $startupFile, $dataLibProject, $userControlProject)
    $manifestLines = foreach ($file in $manifestFiles) {
        (Get-Sha256Hex $file) + '  ' + $file.Substring($sourceRoot.Length).TrimStart('\', '/')
    }
    [IO.File]::WriteAllLines(
        (Join-Path $sourceRoot 'ZSTD_SPECTRUM_FILES.sha256'),
        $manifestLines,
        (New-Object Text.UTF8Encoding($false)))

    if ($Build) {
        $msbuild = Find-MSBuild
        if ([String]::IsNullOrEmpty($msbuild)) {
            throw 'MSBuild.exe was not found. Install the VS 2022 .NET desktop build tools.'
        }

        $solutionCandidates = @(Get-ChildItem -LiteralPath $sourceRoot -File -Filter '*.sln' |
            Sort-Object { if ($_.Name -ieq 'EDX.sln') { 0 } else { 1 } }, Name)
        $buildTarget = if ($solutionCandidates.Count -ne 0) {
            $solutionCandidates[0].FullName
        }
        else {
            Find-UniqueFile $sourceRoot 'WinApps\PMAnalyzer\PMAnalyzer.csproj' 'PMAnalyzer.csproj'
        }

        Write-Step ('Building: ' + $buildTarget)
        & $msbuild $buildTarget '/t:Rebuild' ('/p:Configuration=' + $BuildConfiguration) ('/p:Platform=' + $BuildPlatform) '/m'
        if ($LASTEXITCODE -ne 0) {
            throw ('MSBuild failed with exit code ' + $LASTEXITCODE.ToString() + '.')
        }
    }

    Write-Step 'Validating generated source tree.'
    if ((Get-Item -LiteralPath $dictionaryTarget).Length -ne 4096) { throw 'Dictionary length validation failed.' }
    if ((Read-TextFileInfo $serializeHelper).Text.IndexOf('ZSTD-SPECTRUM-HOOK', [StringComparison]::Ordinal) -lt 0) { throw 'SerializeHelper hook validation failed.' }
    if ((Read-TextFileInfo $startupFile).Text.IndexOf('ZSTD-SPECTRUM-UPGRADE', [StringComparison]::Ordinal) -lt 0) { throw 'Startup hook validation failed.' }
    if ((Read-TextFileInfo $dataLibProject).Text.IndexOf('ZSTD-SPECTRUM-INTEGRATION', [StringComparison]::Ordinal) -lt 0) { throw 'EDX.DataLib project validation failed.' }
    if ((Read-TextFileInfo $userControlProject).Text.IndexOf('ZSTD-SPECTRUM-UPGRADE-FORM', [StringComparison]::Ordinal) -lt 0) { throw 'EDX.UserControl project validation failed.' }

    if (Test-Path -LiteralPath $OutputZip) {
        Remove-Item -LiteralPath $OutputZip -Force
    }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $OutputZip)) | Out-Null

    Write-Step ('Creating complete source ZIP: ' + $OutputZip)
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $projectWork,
        $OutputZip,
        [IO.Compression.CompressionLevel]::Optimal,
        $false)

    Write-Host ''
    Write-Host 'Integration completed.' -ForegroundColor Green
    Write-Host ('Output: ' + $OutputZip)
    Write-Host ('Dictionary: ' + $selectedDictionary)
    Write-Host ('Dictionary SHA-256: ' + $dictionaryHash)
    Write-Host ('ZstdSharp SHA-256: ' + $zstdHash)
}
finally {
    if ($KeepWork) {
        Write-Host ('Work directory retained: ' + $workRoot)
    }
    elseif (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
