<#
.SYNOPSIS
Build ONNX Runtime Windows x64 provider bundles for RedLnx.

.DESCRIPTION
Mirror of `bin/build-onnxruntime-linux.sh` for Windows. Today only the
`webgpu` provider is meaningful here (the universal Vulkan/Dawn fallback
for AMD Radeon, Intel iGPU, Intel Arc, integrated GPUs, and older NVIDIA
cards where DirectML is unstable). Microsoft does NOT publish a
prebuilt WebGPU NuGet for Windows — every release path goes through a
local build.

.PARAMETER OrtVersion
ONNX Runtime tag to build, default 1.24.2 (matches the Rust `ort` crate's
api-24 ABI used by RedLnx).

.PARAMETER ProviderSet
Provider bundle: webgpu (default).

.PARAMETER WorkDir
Build cache directory.

.PARAMETER OutDir
Artifact output directory.

.PARAMETER Jobs
Parallel jobs, default = number of logical processors.

.PARAMETER CleanBuild
Switch — remove provider build directory before building.

.EXAMPLE
.\bin\build-onnxruntime-windows.ps1 -OrtVersion 1.24.2 -ProviderSet webgpu

.NOTES
Requires: Git, Python 3.11+, CMake 3.26+, Visual Studio 2022 Build Tools
17.10+ (MSVC 19.40+ / v143 + Windows 10/11 SDK), Ninja, Node.js 20+
with npm 10+, 7-Zip (for archive packaging). GitHub `windows-2022`
runners have all of these.
#>
[CmdletBinding()]
param(
    [string]$OrtVersion = "1.24.2",
    [ValidateSet("webgpu")]
    [string]$ProviderSet = "webgpu",
    [string]$WorkDir = (Join-Path $PSScriptRoot "..\.work" | Resolve-Path -ErrorAction SilentlyContinue | ForEach-Object { $_.Path }),
    [string]$OutDir = (Join-Path $PSScriptRoot "..\dist" | Resolve-Path -ErrorAction SilentlyContinue | ForEach-Object { $_.Path }),
    [int]$Jobs = $env:NUMBER_OF_PROCESSORS,
    [switch]$CleanBuild
)

$ErrorActionPreference = "Stop"

if (-not $WorkDir) { $WorkDir = Join-Path (Get-Location) ".work" }
if (-not $OutDir)  { $OutDir  = Join-Path (Get-Location) "dist" }
if (-not $Jobs -or $Jobs -lt 1) { $Jobs = [Environment]::ProcessorCount }

New-Item -ItemType Directory -Force -Path $WorkDir, $OutDir | Out-Null

function Require-Cmd {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "missing required command: $Name"
    }
}

function Require-MsvcCompiler {
    if ($env:VCToolsVersion -match "^(\d+)\.(\d+)") {
        $major = [int]$Matches[1]
        $minor = [int]$Matches[2]
        if ($major -lt 14 -or ($major -eq 14 -and $minor -lt 40)) {
            throw "ONNX Runtime $OrtVersion needs MSVC 14.40+ / cl.exe 19.40+ (VS 2022 17.10+). Current VCToolsVersion is $env:VCToolsVersion. Open an x64 Native Tools prompt from VS 2022 Build Tools."
        }
        return
    }

    $clPath = (Get-Command cl.exe -ErrorAction Stop).Source
    $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($clPath)
    $major = [int]$versionInfo.FileMajorPart
    $minor = [int]$versionInfo.FileMinorPart
    if ($major -lt 19 -or ($major -eq 19 -and $minor -lt 40)) {
        throw "ONNX Runtime $OrtVersion needs MSVC 14.40+ / cl.exe 19.40+ (VS 2022 17.10+). Current cl.exe is $major.$minor at $clPath. Open an x64 Native Tools prompt from VS 2022 Build Tools."
    }
}

function Add-GitUsrBinToPath {
    $gitUsrBin = "C:\Program Files\Git\usr\bin"
    if ((Test-Path $gitUsrBin) -and ($env:PATH -notlike "*$gitUsrBin*")) {
        $env:PATH = "$gitUsrBin;$env:PATH"
    }
}

function Require-NodeTools {
    $nodePath = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
    if (-not $nodePath) {
        throw "node.exe is not in PATH. Install Node.js 20+ with npm 10+ before building the WebGPU provider."
    }

    $nodeVersion = [string](& $nodePath --version)
    if ($nodeVersion -notmatch "^v(\d+)\.") {
        throw "could not detect Node.js version from $nodePath output: $nodeVersion"
    }
    if ([int]$Matches[1] -lt 20) {
        throw "ONNX Runtime WebGPU needs Node.js 20+. Current Node.js is $nodeVersion at $nodePath."
    }

    # ORT's CMake helper requires npm to live next to node.exe; a newer npm
    # elsewhere in PATH is ignored.
    $nodeDir = Split-Path -Parent $nodePath
    $npmPath = Join-Path $nodeDir "npm.cmd"
    if (-not (Test-Path $npmPath)) {
        $npmPath = Join-Path $nodeDir "npm"
    }
    if (-not (Test-Path $npmPath)) {
        throw "npm was not found next to node.exe under $nodeDir. Reinstall Node.js 20+ so npm.cmd is installed beside node.exe."
    }

    $npmVersion = [string](& $npmPath --version)
    if ($npmVersion -notmatch "^(\d+)\.") {
        throw "could not detect npm version from $npmPath output: $npmVersion"
    }
    if ([int]$Matches[1] -lt 10) {
        throw "ONNX Runtime WebGPU needs npm 10+ next to node.exe. Current npm is $npmVersion at $npmPath. Reinstall Node.js 20+ or update that npm installation."
    }
}

Require-Cmd git
Require-Cmd python
Require-Cmd cmake

$SourceDir = Join-Path $WorkDir "onnxruntime-$OrtVersion"
$RepoUrl   = "https://github.com/microsoft/onnxruntime.git"
$Tag       = "v$OrtVersion"

function Ensure-Source {
    if (-not (Test-Path (Join-Path $SourceDir ".git"))) {
        Write-Host "Cloning ONNX Runtime $Tag into $SourceDir" -ForegroundColor Cyan
        git clone --recursive --depth 1 --branch $Tag $RepoUrl $SourceDir
        if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
    } else {
        Write-Host "Updating existing checkout to $Tag" -ForegroundColor Cyan
        git -C $SourceDir fetch --depth 1 origin $Tag
        git -C $SourceDir checkout $Tag
        git -C $SourceDir submodule sync --recursive
        git -C $SourceDir submodule update --init --recursive --depth 1
        if ($LASTEXITCODE -ne 0) { throw "submodule update failed" }
    }
}

function Build-Provider {
    param([string]$Provider)

    $BuildDir = Join-Path $WorkDir "build-$Provider-$OrtVersion"
    if ($CleanBuild -and (Test-Path $BuildDir)) {
        Write-Host "Removing previous build dir $BuildDir" -ForegroundColor Yellow
        Remove-Item -Recurse -Force $BuildDir
    }

    # `--use_webgpu shared_lib` makes the provider load as
    # onnxruntime_providers_webgpu.dll instead of being statically linked
    # into onnxruntime.dll — same approach as the Linux script.
    $providerArgs = @()
    switch ($Provider) {
        "webgpu" { $providerArgs = @("--use_webgpu", "shared_lib") }
        default  { throw "unsupported provider $Provider" }
    }

    $buildScript = Join-Path $SourceDir "tools\ci_build\build.py"
    if (-not (Test-Path $buildScript)) {
        throw "build.py not found under $SourceDir"
    }

    # Use Ninja as the CMake generator. Reasons:
    # - ORT 1.24.2 build.py only accepts "Visual Studio 17 2022" / "18 2026"
    #   among VS generators — VS 2019 is no longer in the supported list.
    # - Ninja is generator-agnostic: it just needs `cl.exe` in PATH, which
    #   the x64 Native Tools prompt provides when VS 2022 Build Tools 17.10+
    #   are installed.
    # - It's also what the Linux script uses (Ninja on linux/mac), keeping
    #   the two pipelines symmetric.
    # Ninja ships with every modern VS install under
    # `...\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe`
    # and the Native Tools prompt puts that directory in PATH for us.
    $generator = "Ninja"
    Write-Host "Building provider=$Provider build_dir=$BuildDir jobs=$Jobs generator='$generator'" -ForegroundColor Cyan

    # Sanity check: make sure cl.exe and ninja.exe are both visible —
    # without them Ninja generation will fail with a confusing message.
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
        throw "cl.exe is not in PATH. Re-run from an `"x64 Native Tools Command Prompt`" so MSVC env is loaded."
    }
    Require-MsvcCompiler
    if (-not (Get-Command ninja.exe -ErrorAction SilentlyContinue)) {
        throw "ninja.exe is not in PATH. Install Ninja (`"winget install Ninja-build.Ninja`") or use a Native Tools prompt that bundles it."
    }
    Require-NodeTools

    # Note: `--compile_no_warning_as_error` was dropped — ORT 1.24.2's
    # build.py either renamed or removed it, and PowerShell ended up
    # leaking the flag straight into the cmake invocation. Instead we
    # tolerate compiler warnings by leaving the default behaviour alone;
    # if a build breaks on a real warning, fix the warning rather than
    # silencing every check.
    # Call build.py directly. ORT's build.bat prepends its own
    # `--build_dir <source>\build\Windows`, which makes diagnostics noisy
    # and can mask the build directory selected by this script.
    Add-GitUsrBinToPath
    & python $buildScript `
        --config Release `
        --build_shared_lib `
        --parallel $Jobs `
        --skip_tests `
        --build_dir $BuildDir `
        --cmake_generator "$generator" `
        --update --build `
        @providerArgs
    if ($LASTEXITCODE -ne 0) { throw "build.py failed for $Provider" }

    Package-Provider -Provider $Provider -BuildDir $BuildDir
}

function Package-Provider {
    param(
        [string]$Provider,
        [string]$BuildDir
    )

    $packageName = "redlnx-onnxruntime-windows-x64-$Provider-$OrtVersion"
    $packageDir  = Join-Path $OutDir $packageName
    $archive     = Join-Path $OutDir "$packageName.zip"
    $sha         = "$archive.sha256"

    foreach ($p in @($packageDir, $archive, $sha)) {
        if (Test-Path $p) { Remove-Item -Recurse -Force $p }
    }
    New-Item -ItemType Directory -Force -Path $packageDir | Out-Null

    # ONNX Runtime drops Release artifacts into build_dir\Release\Release.
    $releaseRoot = Join-Path $BuildDir "Release\Release"
    if (-not (Test-Path $releaseRoot)) {
        # Older layouts use build_dir\Release directly.
        $releaseRoot = Join-Path $BuildDir "Release"
    }
    if (-not (Test-Path $releaseRoot)) {
        throw "could not find Release artifacts under $BuildDir"
    }

    $patterns = @(
        "onnxruntime.dll",
        "onnxruntime.pdb",
        "onnxruntime_providers_shared.dll",
        "onnxruntime_providers_webgpu.dll",
        # Dawn / DXC dependencies that ship alongside the WebGPU provider.
        # Some are absorbed statically by recent Dawn revisions; the rest
        # ship as side-by-side DLLs and would otherwise fail to load on
        # the user machine.
        "dxcompiler.dll",
        "dxil.dll",
        "webgpu_dawn.dll",
        "tint.dll"
    )

    $copied = @()
    foreach ($pat in $patterns) {
        $found = Get-ChildItem -Path $releaseRoot -Filter $pat -ErrorAction SilentlyContinue
        foreach ($f in $found) {
            Copy-Item -Path $f.FullName -Destination $packageDir
            $copied += $f.Name
        }
    }

    # Required deliverables — fail the build immediately if missing.
    $required = @("onnxruntime.dll", "onnxruntime_providers_webgpu.dll")
    foreach ($r in $required) {
        if (-not (Test-Path (Join-Path $packageDir $r))) {
            Write-Host "files copied so far: $($copied -join ', ')" -ForegroundColor Yellow
            throw "missing required packaged file: $r"
        }
    }

    # Pull in the legal/notice files alongside the binaries so a recipient
    # can identify and audit the bundle.
    foreach ($notice in @("LICENSE", "ThirdPartyNotices.txt", "VERSION_NUMBER")) {
        $src = Join-Path $SourceDir $notice
        if (Test-Path $src) {
            Copy-Item -Path $src -Destination $packageDir
        }
    }
    $repoNotice = Join-Path (Get-Location) "NOTICE.txt"
    if (Test-Path $repoNotice) {
        Copy-Item -Path $repoNotice -Destination $packageDir
    }

    # runtime-manifest.txt + redlnx-runtime-package.json so the install
    # script in the main app can introspect what's inside without opening
    # the archive.
    Get-ChildItem -Path $packageDir -File | Sort-Object Name |
        Select-Object -ExpandProperty Name |
        Set-Content -Path (Join-Path $packageDir "runtime-manifest.txt") -Encoding ASCII

    $manifest = [ordered]@{
        schemaVersion       = 1
        packageId           = "windows-x64-$Provider"
        artifactName        = (Split-Path $archive -Leaf)
        platform            = "windows-x64"
        onnxRuntimeVersion  = $OrtVersion
        provider            = $Provider
        notes               = @(
            "Copy or extract these files into RedLnx runtime storage, or point REDLNX_RUNTIME_DIR at this directory.",
            "WebGPU on Windows uses Dawn with a Vulkan/D3D12 backend. The host needs working Vulkan or D3D12 drivers from the GPU vendor."
        )
    }
    $manifest | ConvertTo-Json -Depth 4 |
        Set-Content -Path (Join-Path $packageDir "redlnx-runtime-package.json") -Encoding ASCII

    Compress-Archive -Path (Join-Path $packageDir "*") -DestinationPath $archive -CompressionLevel Optimal
    $hash = Get-FileHash -Algorithm SHA256 -Path $archive
    "$($hash.Hash.ToLower())  $(Split-Path $archive -Leaf)" |
        Set-Content -Path $sha -Encoding ASCII

    Write-Host "built $archive" -ForegroundColor Green
}

Ensure-Source
Build-Provider -Provider $ProviderSet

Write-Host "artifacts written to $OutDir" -ForegroundColor Green
