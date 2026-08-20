#!/usr/bin/env pwsh
# Publish a deliberate, versioned fork release for the in-app updater.
#
# UpdateService checks the fork's GitHub /releases/latest for a newer semver
# tag; the fork's day-to-day builds live on the non-semver rolling tags
# (windows-latest / android-latest), which that check can't read. This script
# cuts an explicit `<version>` release, marked latest, so a release you actually
# intend to ship is the one users get notified about — not every main build.
#
# It assembles the two halves that are signed in different places:
#   - Windows: Authenticode-signed locally (Azure Trusted Signing) and passed in
#     via -WindowsDir. Refuses to publish if the installer isn't validly signed.
#   - Android: keystore-signed by CI and already published to the rolling
#     `android-latest` release, from which the APKs are pulled.
#
# Example:
#   ./windows/publish-fork-release.ps1 -Version 2.15.0 -WindowsDir C:\path\to\signed
param(
  [Parameter(Mandatory)][string]$Version,          # semver, no leading v (e.g. 2.15.0)
  [Parameter(Mandatory)][string]$WindowsDir,       # dir holding the 3 signed Windows files
  [string]$Repo = 'TeeJS/plezy',
  [string]$AndroidReleaseTag = 'android-latest',   # rolling release CI signs APKs into
  [switch]$Draft
)

$ErrorActionPreference = 'Stop'

if ($Version -notmatch '^\d+\.\d+\.\d+') {
  throw "Version must be semantic (e.g. 2.15.0), got: $Version"
}

# --- Windows: locate and verify the signed artifacts ---
$winFileNames = @(
  'plezy-windows-installer.exe',
  'plezy-windows-x64-portable.zip',
  'plezy-windows-arm64-portable.zip'
)
$winPaths = foreach ($name in $winFileNames) {
  $p = Join-Path $WindowsDir $name
  if (-not (Test-Path -LiteralPath $p)) { throw "Missing Windows artifact: $p" }
  $p
}

$installer = Join-Path $WindowsDir 'plezy-windows-installer.exe'
$sig = Get-AuthenticodeSignature -LiteralPath $installer
if ($sig.Status -ne 'Valid') {
  throw "Installer is not validly signed (status: $($sig.Status)). Sign it before publishing."
}
Write-Host "Installer signed by: $($sig.SignerCertificate.Subject.Split(',')[0])" -ForegroundColor Green

# --- Android: pull the CI-signed APKs from the rolling release ---
$apkNames = @(
  'plezy-android-arm64-v8a.apk',
  'plezy-android-armeabi-v7a.apk',
  'plezy-android-x86_64.apk'
)
$apkDir = Join-Path ([System.IO.Path]::GetTempPath()) "plezy-apks-$Version"
New-Item -ItemType Directory -Force $apkDir | Out-Null
Write-Host "Downloading signed APKs from '$AndroidReleaseTag'..." -ForegroundColor Cyan
& gh release download $AndroidReleaseTag --repo $Repo --dir $apkDir --clobber --pattern 'plezy-android-*.apk'
if ($LASTEXITCODE -ne 0) { throw "Failed to download APKs from '$AndroidReleaseTag'" }
$apkPaths = foreach ($name in $apkNames) {
  $p = Join-Path $apkDir $name
  if (-not (Test-Path -LiteralPath $p)) { throw "APK not found in '$AndroidReleaseTag': $name" }
  $p
}

$allFiles = @($winPaths) + @($apkPaths)

$notes = @"
Fork build $Version, signed.

- Windows: Authenticode-signed installer + portable zips (x64 / arm64)
- Android: signed APKs (arm64-v8a / armeabi-v7a / x86_64)

Built from the $Repo fork. The in-app updater tracks these versioned releases.
"@

# --- Create or update the release, and mark it the latest ---
& gh release view $Version --repo $Repo *> $null
$exists = ($LASTEXITCODE -eq 0)

if ($exists) {
  Write-Host "Updating existing release $Version..." -ForegroundColor Cyan
  & gh release upload $Version @allFiles --repo $Repo --clobber
  if ($LASTEXITCODE -ne 0) { throw "Asset upload failed" }
  & gh release edit $Version --repo $Repo --latest --draft=$($Draft.IsPresent) --notes $notes
  if ($LASTEXITCODE -ne 0) { throw "Release edit failed" }
} else {
  Write-Host "Creating release $Version..." -ForegroundColor Cyan
  $ghArgs = @(
    'release', 'create', $Version,
    '--repo', $Repo,
    '--title', "Plezy $Version (fork build, signed)",
    '--notes', $notes,
    '--latest'
  )
  if ($Draft) { $ghArgs += '--draft' }
  $ghArgs += $allFiles
  & gh @ghArgs
  if ($LASTEXITCODE -ne 0) { throw "Release creation failed" }
}

Write-Host "Published: https://github.com/$Repo/releases/tag/$Version" -ForegroundColor Green
