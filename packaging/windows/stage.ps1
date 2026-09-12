# SPDX-License-Identifier: MIT OR Apache-2.0
[CmdletBinding()]
param(
    [string]$BuildDir = (Join-Path $PSScriptRoot '..\..\build\windows-release'),
    [string]$StageDir = (Join-Path $PSScriptRoot '..\..\stage\windows-release'),
    [string]$CraftRoot = $(if ($env:KIRC_CRAFT_ROOT) { $env:KIRC_CRAFT_ROOT } else { 'E:\CraftRoot' }),
    [string]$VCRedistRoot = $(if ($env:KIRC_VC_REDIST_ROOT) { $env:KIRC_VC_REDIST_ROOT } else { 'E:\BuildTools\VC\Redist\MSVC' }),
    [string]$ArchiveName = 'kIRC-windows-x64.zip',
    [switch]$Archive
)
$ErrorActionPreference = 'Stop'
# The name lands inside the .sha256 file as well, so keep it a bare file name.
if ($ArchiveName -notmatch '^[A-Za-z0-9._-]+\.zip$') {
    throw "ArchiveName must be a bare .zip file name: $ArchiveName"
}

$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$build = [IO.Path]::GetFullPath($BuildDir)
$stage = [IO.Path]::GetFullPath($StageDir)
$stageRoot = [IO.Path]::GetFullPath((Join-Path $repo 'stage'))
if (-not $stage.StartsWith($stageRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "StageDir must be below $stageRoot"
}
foreach ($required in @((Join-Path $build 'kIRC.exe'), (Join-Path $build 'kirc-shortcut.exe'),
                         (Join-Path $CraftRoot 'bin\windeployqt.exe'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing required file: $required" }
}

$temp = "$stage.tmp-$PID"
if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    Copy-Item -LiteralPath (Join-Path $build 'kIRC.exe'), (Join-Path $build 'kirc-shortcut.exe') -Destination $temp
    & (Join-Path $CraftRoot 'bin\windeployqt.exe') --release --qmldir (Join-Path $repo 'rust\qml') (Join-Path $temp 'kIRC.exe')
    if ($LASTEXITCODE -ne 0) { throw "windeployqt failed with exit code $LASTEXITCODE" }

    $extra = @(
        'Kirigami.dll','KirigamiPlatform.dll','KirigamiControls.dll','KirigamiDelegates.dll',
        'KirigamiDialogs.dll','KirigamiForms.dll','KirigamiFormsPrivateCards.dll',
        'KirigamiFormsPrivateFlat.dll','KirigamiFormsPrivateTemplates.dll','KirigamiLayouts.dll',
        'KirigamiLayoutsPrivate.dll','KirigamiPrimitives.dll','KirigamiPrivate.dll',
        'KirigamiTemplates.dll','KirigamiPolyfill.dll','KF6ConfigCore.dll','KF6ConfigGui.dll',
        'libcrypto-3-x64.dll','libssl-3-x64.dll','brotlidec.dll','brotlicommon.dll',
        'freetype.dll','harfbuzz.dll','libpng16.dll','zlib1.dll','bz2.dll','b2-1.dll',
        'zstd.dll','pcre2-16.dll','jpeg62.dll'
    )
    foreach ($dll in $extra) {
        $source = Join-Path $CraftRoot "bin\$dll"
        if (-not (Test-Path -LiteralPath $source)) { throw "Missing runtime dependency: $source" }
        Copy-Item -LiteralPath $source -Destination $temp
    }

    $redist = Get-ChildItem -LiteralPath $VCRedistRoot -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'x64\Microsoft.VC143.CRT') } |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $redist) { throw "No VC143 x64 redistributable found below $VCRedistRoot" }
    foreach ($dll in @('msvcp140.dll','msvcp140_1.dll','msvcp140_2.dll','vcruntime140.dll','vcruntime140_1.dll')) {
        Copy-Item -LiteralPath (Join-Path $redist.FullName "x64\Microsoft.VC143.CRT\$dll") -Destination $temp
    }
    Copy-Item -LiteralPath (Join-Path $redist.FullName 'x64\Microsoft.VC143.OpenMP\vcomp140.dll') -Destination $temp
    Copy-Item -LiteralPath (Join-Path $repo 'LICENSES.md') -Destination $temp

    $mustExist = @('platforms\qwindows.dll','qml\org\kde\kirigami\Kirigamiplugin.dll',
        'qml\org\kde\kirigami\layouts\qmldir','qml\QtQuick\Effects\qmldir',
        'qml\QtQuick\Controls\qmldir','KF6ConfigCore.dll','vcruntime140.dll','vcomp140.dll')
    foreach ($item in $mustExist) {
        if (-not (Test-Path -LiteralPath (Join-Path $temp $item))) { throw "Incomplete stage: missing $item" }
    }

    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    Move-Item -LiteralPath $temp -Destination $stage
    if ($Archive) {
        $zip = Join-Path (Split-Path $stage -Parent) $ArchiveName
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
        $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $zip
        Set-Content -LiteralPath "$zip.sha256" -Encoding ascii -Value ("{0}  {1}" -f $hash.Hash.ToLowerInvariant(), [IO.Path]::GetFileName($zip))
        Write-Host "Archive: $zip"
    }
    Write-Host "Windows stage ready: $stage"
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
