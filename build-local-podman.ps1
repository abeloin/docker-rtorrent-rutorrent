<#
.SYNOPSIS
    Builds the rtorrent-rutorrent image locally with Podman and saves it as a
    tarball that both `podman load` and `docker load` can import.

.DESCRIPTION
    Podman counterpart of build-local.ps1. Podman has no `buildx bake`, so this
    script reproduces what the `image-local` target in docker-bake.hcl does:
      - tags the image as rtorrent-rutorrent:local
      - passes ALPINE_PHP_VERSION only when explicitly provided
      - builds a single-platform image

    The result is written to rtorrent-rutorrent_local.tar in the current
    directory, as an OCI archive. This matches the size of buildx's type=docker
    output (a docker-archive stores layers uncompressed and comes out roughly
    2.7x larger).

    Podman does not write the manifest.json file that buildx adds alongside its
    OCI layout, so a plain `podman save` archive fails with
      invalid archive: does not contain a manifest.json
    when passed to `docker load`. Step 4 adds that file back.
    See https://github.com/containers/podman/issues/21347

.PARAMETER PhpVersion
    Alpine PHP version to build against (for example "84" or "85").
    When omitted, the default ALPINE_PHP_VERSION from the Dockerfile is used.

.EXAMPLE
    .\build-local-podman.ps1

.EXAMPLE
    .\build-local-podman.ps1 -PhpVersion 85
#>
param(
    [string]$PhpVersion = ""
)

# Stop the script on any terminating error.
$ErrorActionPreference = "Stop"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Starting Local Podman Build Pipeline     " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# Pre-flight: podman must be on PATH.
if (-not (Get-Command podman -CommandType Application -ErrorAction SilentlyContinue)) {
    Write-Error "'podman' was not found in PATH."
    Exit 1
}

# Pre-flight: resolve the effective PHP version, falling back to the Dockerfile ARG default.
$Dockerfile = Join-Path $PSScriptRoot "Dockerfile"
if ($PhpVersion) {
    $EffectivePhpVersion = $PhpVersion
} else {
    $ArgMatch = Select-String -Path $Dockerfile -Pattern '^\s*ARG\s+ALPINE_PHP_VERSION=(\d+)' | Select-Object -First 1
    if (-not $ArgMatch) {
        Write-Error "Could not determine default ALPINE_PHP_VERSION from '$Dockerfile'."
        Exit 1
    }
    $EffectivePhpVersion = $ArgMatch.Matches[0].Groups[1].Value
}
Write-Host "`n[Config] Building with Alpine PHP version: $EffectivePhpVersion" -ForegroundColor Cyan

# Pre-flight: ensure the matching PHP config template folder exists before building.
$PhpTemplateDir = Join-Path $PSScriptRoot "rootfs/tpls/etc/php$EffectivePhpVersion"
if (-not (Test-Path $PhpTemplateDir -PathType Container)) {
    Write-Error "PHP template folder '$PhpTemplateDir' not found. Create it before building with PHP $EffectivePhpVersion."
    Exit 1
}

# Pre-flight: remove any archive left over from a previous run.
$TarFile = "rtorrent-rutorrent_local.tar"
if (Test-Path $TarFile) {
    Write-Host "`n[Pre-check] Removing existing $TarFile..." -ForegroundColor DarkYellow
    Remove-Item $TarFile -Force
}

$ImageTag = "rtorrent-rutorrent:local"

# 1. Purge the build cache so the image is built from scratch.
Write-Host "`n[1/4] Purging Podman build cache..." -ForegroundColor Yellow
podman builder prune --all --force

# External commands don't trigger $ErrorActionPreference, so check the exit code.
if ($LASTEXITCODE -ne 0) {
    Write-Error "Podman builder prune failed with exit code $LASTEXITCODE."
    Exit $LASTEXITCODE
}

# 2. Build the local image (equivalent of `docker buildx bake image-local`)
Write-Host "`n[2/4] Building local image..." -ForegroundColor Yellow
$BuildArgs = @(
    "build",
    # Podman defaults to the OCI format, which drops HEALTHCHECK. Buildx bake
    # produces a docker-format image, so ask for the same here.
    "--format", "docker",
    "--file", $Dockerfile,
    "--tag", $ImageTag
)
if ($PhpVersion) {
    # Only override the Dockerfile ARG default when a version is provided.
    $BuildArgs += @("--build-arg", "ALPINE_PHP_VERSION=$PhpVersion")
}
$BuildArgs += $PSScriptRoot

podman @BuildArgs

if ($LASTEXITCODE -ne 0) {
    Write-Error "Podman build failed with exit code $LASTEXITCODE."
    Exit $LASTEXITCODE
}

# 3. Export the image to an OCI archive.
Write-Host "`n[3/4] Saving image to $TarFile..." -ForegroundColor Yellow
podman save --format oci-archive -o $TarFile $ImageTag

if ($LASTEXITCODE -ne 0) {
    Write-Error "Podman save failed with exit code $LASTEXITCODE."
    Exit $LASTEXITCODE
}

# 4. Make the OCI archive loadable by Docker.
# Generate the missing manifest.json so `docker load` accepts the archive, and
# annotate index.json with io.containerd.image.name so `podman load` still tags
# the image (Podman ignores manifest.json when index.json is present).
Write-Host "`n[4/4] Adding docker compatibility shim..." -ForegroundColor Yellow

$WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("oci-shim-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $WorkDir | Out-Null

try {
    tar -xf $TarFile -C $WorkDir
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to unpack '$TarFile' with exit code $LASTEXITCODE."
        Exit $LASTEXITCODE
    }

    $BlobPath = { param($Digest) "blobs/sha256/" + $Digest.Split(':')[-1] }

    $IndexFile = Join-Path $WorkDir "index.json"
    $Index = Get-Content $IndexFile -Raw | ConvertFrom-Json

    # Resolve to the image manifest, stepping through a nested index if present
    # and skipping attestation entries (platform "unknown").
    $Entry = $Index.manifests[0]
    while ($Entry.mediaType -like "*image.index*") {
        $Nested = Get-Content (Join-Path $WorkDir (& $BlobPath $Entry.digest)) -Raw | ConvertFrom-Json
        $Entry = $Nested.manifests | Where-Object { $_.platform.os -ne "unknown" } | Select-Object -First 1
    }

    $Manifest = Get-Content (Join-Path $WorkDir (& $BlobPath $Entry.digest)) -Raw | ConvertFrom-Json

    $DockerManifest = @(
        [ordered]@{
            Config   = & $BlobPath $Manifest.config.digest
            RepoTags = @($ImageTag)
            Layers   = @($Manifest.layers | ForEach-Object { & $BlobPath $_.digest })
        }
    )
    $DockerManifest | ConvertTo-Json -Depth 10 -AsArray |
        Set-Content (Join-Path $WorkDir "manifest.json") -Encoding utf8NoBOM

    # podman load reads the tag from this annotation, not from manifest.json.
    $Index.manifests[0] | Add-Member -NotePropertyName annotations -NotePropertyValue ([pscustomobject]@{}) -Force
    $Index.manifests[0].annotations | Add-Member -NotePropertyName "io.containerd.image.name" -NotePropertyValue "localhost/$ImageTag" -Force
    $Index | ConvertTo-Json -Depth 10 | Set-Content $IndexFile -Encoding utf8NoBOM

    # Repack the archive, listing members explicitly so they keep their top-level paths.
    Remove-Item $TarFile -Force
    tar -cf $TarFile -C $WorkDir "oci-layout" "index.json" "manifest.json" "blobs"
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to repack '$TarFile' with exit code $LASTEXITCODE."
        Exit $LASTEXITCODE
    }
} finally {
    Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n==========================================" -ForegroundColor Green
Write-Host " Success: Pipeline completed cleanly!     " -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

# Note: the generated manifest.json uses the bare "rtorrent-rutorrent:local" tag,
# so `docker load` produces the same image name as buildx and no retag is needed.
# The index.json annotation keeps the localhost/ prefix Podman expects, so
# `podman load` tags the image as "localhost/rtorrent-rutorrent:local".
