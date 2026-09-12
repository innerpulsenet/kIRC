# SPDX-License-Identifier: MIT OR Apache-2.0
[CmdletBinding()]
param(
    [string]$StageDir = (Join-Path $PSScriptRoot '..\..\stage\windows-release'),
    [string]$Output = (Join-Path $PSScriptRoot '..\..\stage\kIRC-setup-x64.exe'),
    [string]$Makensis = $(if ($env:KIRC_MAKENSIS) { $env:KIRC_MAKENSIS } else { 'makensis.exe' }),
    [string]$Version = '1.0.0'
)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Version must be major.minor.patch' }
$stage = [IO.Path]::GetFullPath($StageDir)
$outputPath = [IO.Path]::GetFullPath($Output)
if (-not (Test-Path -LiteralPath (Join-Path $stage 'kIRC.exe'))) { throw "Invalid stage: $stage" }
$tool = (Get-Command $Makensis -ErrorAction Stop).Source
& $tool "/DSTAGE_DIR=$stage" "/DOUT_FILE=$outputPath" "/DKIRC_VERSION=$Version" (Join-Path $PSScriptRoot 'kirc.nsi')
if ($LASTEXITCODE -ne 0) { throw "makensis failed with exit code $LASTEXITCODE" }
$hash = Get-FileHash -Algorithm SHA256 -LiteralPath $outputPath
Set-Content -LiteralPath "$outputPath.sha256" -Encoding ascii -Value ("{0}  {1}" -f $hash.Hash.ToLowerInvariant(), [IO.Path]::GetFileName($outputPath))
Write-Host "Installer: $outputPath"
