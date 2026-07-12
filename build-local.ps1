param(
    # Alpine PHP version to build against (e.g. "84", "85").
    # Leave empty to use the Dockerfile's ARG default.
    [string]$PhpVersion = ""
)

# Explicitly set the error action to stop the script if any command throws a terminating error
$ErrorActionPreference = "Stop"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Starting Local Docker Build Pipeline     " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# Pre-flight: resolve the effective PHP version, falling back to the Dockerfile ARG default.
if ($PhpVersion) {
    $EffectivePhpVersion = $PhpVersion
} else {
    $Dockerfile = Join-Path $PSScriptRoot "Dockerfile"
    $ArgMatch = Select-String -Path $Dockerfile -Pattern '^\s*ARG\s+ALPINE_PHP_VERSION=(\d+)' | Select-Object -First 1
    if (-not $ArgMatch) {
        Write-Error "Could not determine default ALPINE_PHP_VERSION from '$Dockerfile'."
        Exit 1
    }
    $EffectivePhpVersion = $ArgMatch.Matches[0].Groups[1].Value
}
Write-Host "`n[Config] Building with Alpine PHP version: $EffectivePhpVersion" -ForegroundColor Cyan

# Pre-flight: expose the version to docker buildx bake (reads ALPINE_PHP_VERSION from the environment).
if ($PhpVersion) {
    $env:ALPINE_PHP_VERSION = $PhpVersion
} else {
    # No override: clear it so a stale session value can't leak into the build.
    Remove-Item Env:\ALPINE_PHP_VERSION -ErrorAction SilentlyContinue
}

# Pre-flight: ensure the matching PHP config template folder exists before building.
$PhpTemplateDir = Join-Path $PSScriptRoot "rootfs/tpls/etc/php$EffectivePhpVersion"
if (-not (Test-Path $PhpTemplateDir -PathType Container)) {
    Write-Error "PHP template folder '$PhpTemplateDir' not found. Create it before building with PHP $EffectivePhpVersion."
    Exit 1
}

# Pre-flight: remove old tar archive if it exists
$TarFile = "rtorrent-rutorrent_local.tar"
if (Test-Path $TarFile) {
    Write-Host "`n[Pre-check] Removing existing $TarFile..." -ForegroundColor DarkYellow
    Remove-Item $TarFile -Force
}

# 1. Clear out the Buildx cache completely
Write-Host "`n[1/3] Purging Buildx cache..." -ForegroundColor Yellow
docker buildx prune --all --force

# 2. Execute the bake definition for the local target
Write-Host "`n[2/3] Baking local image target..." -ForegroundColor Yellow
docker buildx bake image-local

# Check the native exit code since external CLI tools don't always trigger PowerShell's $ErrorActionPreference
if ($LASTEXITCODE -ne 0) {
    Write-Error "Docker Buildx Bake failed with exit code $LASTEXITCODE."
    Exit $LASTEXITCODE
}

# 3. Export the resulting image to a tarball archive
Write-Host "`n[3/3] Saving image to $TarFile..." -ForegroundColor Yellow
docker save -o $TarFile rtorrent-rutorrent:local

if ($LASTEXITCODE -ne 0) {
    Write-Error "Docker save failed with exit code $LASTEXITCODE."
    Exit $LASTEXITCODE
}

Write-Host "`n==========================================" -ForegroundColor Green
Write-Host " Success: Pipeline completed cleanly!     " -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
