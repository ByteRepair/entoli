# Packages a `flutter build windows` bundle as a WiX MSI, e.g.
#   tool/windows/make-msi.ps1 build/windows/x64/runner/Release dist/entoli-installer.msi -Version 4.6.2
#
# The version is handed in rather than read from pubspec: release-build.yml's
# version job owns that number, and this script owns nothing but turning a
# bundle into the installer. Nothing signs it yet, like the DMG — an unsigned
# MSI is what SmartScreen warns about, which a right-click "Run anyway" passes.
# WiX 7 is installed as a dotnet tool, pinned: it builds the file a release is
# attached by, and a release tag can be moved. Its Open Source Maintenance Fee
# EULA is accepted per invocation (-acceptEula wix7); the fee is an
# organization's to pay, not an open-source release's.
param(
    [Parameter(Mandatory = $true)] [string] $Bundle,
    [Parameter(Mandatory = $true)] [string] $Out,
    [Parameter(Mandatory = $true)] [string] $Version
)
$ErrorActionPreference = "Stop"

# The exe the shortcuts and the package run: BINARY_NAME in windows/CMakeLists.txt.
if (-not (Test-Path (Join-Path $Bundle "entoli.exe"))) {
    throw "make-msi.ps1: $Bundle\entoli.exe does not exist; is this the Release bundle?"
}

$wixVersion = "7.0.0"
dotnet tool install --global wix --version $wixVersion
if ($LASTEXITCODE -ne 0) {
    # A re-run finds the tool already installed; pin it back rather than fail.
    dotnet tool update --global wix --version $wixVersion
}
# The image has the dotnet tools directory on PATH; being explicit anyway
# means this script never depends on it.
$env:PATH = "$env:USERPROFILE\.dotnet\tools;$env:PATH"

$outDir = Split-Path $Out -Parent
if ($outDir) {
    New-Item -ItemType Directory -Force $outDir | Out-Null
}

wix build -acceptEula wix7 -arch x64 -b $Bundle -o $Out -d Version=$Version "$PSScriptRoot\entoli.wxs"
if ($LASTEXITCODE -ne 0) {
    throw "make-msi.ps1: wix build failed"
}