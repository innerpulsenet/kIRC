# SPDX-License-Identifier: MIT OR Apache-2.0
[CmdletBinding()]
param(
    [string]$BuildDir = (Join-Path $PSScriptRoot '..\..\build\windows-release'),
    [string]$CraftRoot = $(if ($env:KIRC_CRAFT_ROOT) { $env:KIRC_CRAFT_ROOT } else { 'E:\CraftRoot' }),
    [string]$VsRoot = $(if ($env:KIRC_VS_ROOT) { $env:KIRC_VS_ROOT } else { '' }),
    [string]$CMake = $(if ($env:KIRC_CMAKE) { $env:KIRC_CMAKE } else { 'cmake.exe' }),
    [string]$NinjaDir = $(if ($env:KIRC_NINJA_DIR) { $env:KIRC_NINJA_DIR } else { '' })
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$build = [IO.Path]::GetFullPath($BuildDir)
if (-not (Test-Path -LiteralPath $CraftRoot -ErrorAction SilentlyContinue)) {
    throw "Craft root not found: $CraftRoot (set KIRC_CRAFT_ROOT or pass -CraftRoot)"
}
if (-not $VsRoot) {
    # The development machine's Build Tools install wins when it is present.
    # Compose that probe with [IO.Path]::Combine, not Join-Path: Join-Path
    # resolves the drive qualifier and throws "A drive with the name 'E' does
    # not exist" on every machine without an E: drive, CI included.
    $localVs = 'E:\BuildTools'
    $localVcvars = [IO.Path]::Combine($localVs, 'VC\Auxiliary\Build\vcvarsall.bat')
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $localVcvars -ErrorAction SilentlyContinue) {
        $VsRoot = $localVs
    } elseif (Test-Path -LiteralPath $vswhere) {
        $VsRoot = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
    }
}
$vcvars = Join-Path $VsRoot 'VC\Auxiliary\Build\vcvarsall.bat'
if (-not (Test-Path -LiteralPath $vcvars)) { throw "VS2022 vcvarsall.bat not found: $vcvars" }

# Import the supported x64 MSVC environment into this PowerShell process.
$lines = & $env:ComSpec /d /s /c "`"$vcvars`" x64 >nul && set"
if ($LASTEXITCODE -ne 0) { throw "vcvarsall failed with exit code $LASTEXITCODE" }
foreach ($line in $lines) {
    $at = $line.IndexOf('=')
    if ($at -gt 0) { [Environment]::SetEnvironmentVariable($line.Substring(0, $at), $line.Substring($at + 1), 'Process') }
}
if ($NinjaDir) { $env:PATH = "$NinjaDir;$env:PATH" }
$env:PATH = "$(Join-Path $CraftRoot 'bin');$(Join-Path $CraftRoot 'dev-utils\bin');$env:PATH"

$cmakeTool = (Get-Command $CMake -ErrorAction Stop).Source
& $cmakeTool -S $repo -B $build -G Ninja `
    -DCMAKE_BUILD_TYPE=Release `
    "-DCMAKE_PREFIX_PATH=$($CraftRoot.Replace('\','/'))" `
    "-DKIRC_QMAKE_EXECUTABLE=$($CraftRoot.Replace('\','/'))/bin/qmake.exe" `
    -DKIRC_BUILD_TESTS=ON
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed with exit code $LASTEXITCODE" }
& $cmakeTool --build $build --parallel
if ($LASTEXITCODE -ne 0) { throw "Build failed with exit code $LASTEXITCODE" }
& $cmakeTool -E env "PATH=$(Join-Path $CraftRoot 'bin');$env:PATH" ctest --test-dir $build --output-on-failure
if ($LASTEXITCODE -ne 0) { throw "CTest failed with exit code $LASTEXITCODE" }
Write-Host "Windows build and CTest passed: $build"
