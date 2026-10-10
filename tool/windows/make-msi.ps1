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
# organization's to pay, not an open-source release's. The welcome screen is
# WixUI_Minimal's, the UI extension pinned beside the tool, its license page
# generated from the repo's LICENSE below.
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

# The welcome dialog's license page: the repo's own LICENSE turned into rtf
# in this run's temp, so an AGPL edit flows into the installer without a
# second file to keep in step. RTF doubles nothing here; it escapes {, } and
# \ and writes a paragraph break at each line. Non-ASCII would need \uN
# escapes, which is a throw rather than an escape.
$rtfPath = Join-Path ([System.IO.Path]::GetTempPath()) "entoli-license.rtf"
$license = [System.IO.File]::ReadAllText("$PSScriptRoot\..\..\LICENSE")
if ($license -match "[^\x00-\x7F]") {
    throw "make-msi.ps1: the LICENSE carries non-ASCII the rtf escape below does not handle"
}
$license = $license.Replace("\", "\\").Replace("{", "\{").Replace("}", "\}")
$license = $license.Replace("`r`n", "\par`r`n").Replace("`n", "\par`r`n")
[System.IO.File]::WriteAllText($rtfPath, "{\rtf1\ansi\pard\fs16 $license}")

wix extension add -acceptEula wix7 -g WixToolset.UI.wixext -v 7.0.0
if ($LASTEXITCODE -ne 0) {
    throw "make-msi.ps1: the UI extension did not install"
}

wix build -acceptEula wix7 -ext WixToolset.UI.wixext -arch x64 -o $Out -d Version=$Version -d BundlePath=$((Resolve-Path $Bundle).Path) -d LicenseRtf=$rtfPath "$PSScriptRoot\entoli.wxs"
if ($LASTEXITCODE -ne 0) {
    throw "make-msi.ps1: wix build failed"
}

# WIX8600 grades a zero-file harvest a warning and the build ships green —
# this is where it fails instead: the exe as a literal in the MSI's File
# table is what the harvest having found the bundle looks like, and a size
# under a megabyte is the cab-embedment the same class of silently-missing
# payload — the table names the files either way.
if (-not (Select-String -Path $Out -Pattern "entoli.exe" -Quiet)) {
    throw "make-msi.ps1: the MSI carries no entoli.exe; the harvest found no files"
}
if ((Get-Item $Out).Length -lt 1048576) {
    throw "make-msi.ps1: $(Split-Path $Out -Leaf) is under a megabyte; the cabinet is not embedding"
}