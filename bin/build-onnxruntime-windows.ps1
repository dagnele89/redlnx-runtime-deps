<#
.SYNOPSIS
Build ONNX Runtime Windows x64 provider bundles for RedLnx.

.DESCRIPTION
Mirror of `bin/build-onnxruntime-linux.sh` for Windows. Two provider
bundles are built here, because Microsoft publishes neither:
- `webgpu`: the universal Vulkan/D3D12 Dawn fallback for AMD Radeon,
  Intel iGPU, Intel Arc, integrated GPUs, and NVIDIA cards without CUDA.
  There is no prebuilt WebGPU NuGet for Windows.
- `directml`: the DirectX 12 engine. Microsoft stopped publishing
  Microsoft.ML.OnnxRuntime.DirectML after 1.24.4, and the official 1.31
  zips do not contain the DirectML EP.
Both bundles are built with `--no_telemetry`: native ORT builds enable
1DS telemetry by default since the 1.31 build scripts.

.PARAMETER OrtVersion
ONNX Runtime tag to build, default 1.31.1 (the release of the official
CUDA 13 zip RedLnx ships beside these bundles).

.PARAMETER ProviderSet
Provider bundle: webgpu (default) or directml.

.PARAMETER WorkDir
Build cache directory.

.PARAMETER OutDir
Artifact output directory.

.PARAMETER Jobs
Parallel jobs, default = number of logical processors.

.PARAMETER CleanBuild
Switch — remove provider build directory before building.

.EXAMPLE
.\bin\build-onnxruntime-windows.ps1 -OrtVersion 1.31.1 -ProviderSet webgpu

.EXAMPLE
.\bin\build-onnxruntime-windows.ps1 -OrtVersion 1.31.1 -ProviderSet directml

.NOTES
Requires: Git, Python 3.11+, CMake 3.26+, Visual Studio 2022 Build Tools
17.10+ (MSVC 19.40+ / v143 + Windows 10/11 SDK + ATL), Ninja; the
webgpu bundle also needs Node.js 20+ with npm 10+. GitHub `windows-2022`
runners have all of these.
#>
[CmdletBinding()]
param(
    [string]$OrtVersion = "1.31.1",
    [ValidateSet("webgpu", "directml")]
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

function Require-PythonVersion {
    $pythonVersion = [string](& python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')")
    if ($pythonVersion -notmatch "^(\d+)\.(\d+)") {
        throw "could not detect Python version: $pythonVersion"
    }

    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    if ($major -lt 3 -or ($major -eq 3 -and $minor -lt 11)) {
        throw "ONNX Runtime $OrtVersion needs Python 3.11+. Current Python is $pythonVersion."
    }
}

function Require-CmakeVersion {
    $cmakeVersionLine = [string](& cmake --version | Select-Object -First 1)
    if ($cmakeVersionLine -notmatch "(\d+)\.(\d+)\.(\d+)") {
        throw "could not detect CMake version from output: $cmakeVersionLine"
    }

    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    if ($major -lt 3 -or ($major -eq 3 -and $minor -lt 26)) {
        throw "ONNX Runtime $OrtVersion needs CMake 3.26+. Current CMake is $($Matches[0])."
    }
}

function Require-MsvcCompiler {
    $clPath = (Get-Command cl.exe -ErrorAction Stop).Source
    if ($env:VSCMD_ARG_TGT_ARCH -and $env:VSCMD_ARG_TGT_ARCH -ne "x64") {
        throw "ONNX Runtime Windows artifacts must be built for x64. Current VS target architecture is '$env:VSCMD_ARG_TGT_ARCH' ($clPath). Open an x64 Native Tools prompt from VS 2022 Build Tools."
    }
    if ($clPath -match "\\Host[^\\]+\\x86\\cl\.exe$") {
        throw "ONNX Runtime Windows artifacts must be built with the x64 target compiler. Current cl.exe targets x86: $clPath. Open an x64 Native Tools prompt from VS 2022 Build Tools."
    }

    if ($env:VCToolsVersion -match "^(\d+)\.(\d+)") {
        $major = [int]$Matches[1]
        $minor = [int]$Matches[2]
        if ($major -lt 14 -or ($major -eq 14 -and $minor -lt 40)) {
            throw "ONNX Runtime $OrtVersion needs MSVC 14.40+ / cl.exe 19.40+ (VS 2022 17.10+). Current VCToolsVersion is $env:VCToolsVersion. Open an x64 Native Tools prompt from VS 2022 Build Tools."
        }
        return
    }

    $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($clPath)
    $major = [int]$versionInfo.FileMajorPart
    $minor = [int]$versionInfo.FileMinorPart
    if ($major -lt 19 -or ($major -eq 19 -and $minor -lt 40)) {
        throw "ONNX Runtime $OrtVersion needs MSVC 14.40+ / cl.exe 19.40+ (VS 2022 17.10+). Current cl.exe is $major.$minor at $clPath. Open an x64 Native Tools prompt from VS 2022 Build Tools."
    }
}

function Require-AtlHeaders {
    $atlBase = $null
    if ($env:VCToolsInstallDir) {
        $candidate = Join-Path $env:VCToolsInstallDir "ATLMFC\include\atlbase.h"
        if (Test-Path $candidate) { $atlBase = $candidate }
    }

    if (-not $atlBase -and $env:INCLUDE) {
        foreach ($includeDir in ($env:INCLUDE -split ";")) {
            if (-not $includeDir) { continue }
            $candidate = Join-Path $includeDir "atlbase.h"
            if (Test-Path $candidate) {
                $atlBase = $candidate
                break
            }
        }
    }

    if (-not $atlBase) {
        throw "ATL headers are missing (atlbase.h). Install the VS 2022 Build Tools component Microsoft.VisualStudio.Component.VC.ATL, then reopen the x64 Native Tools prompt."
    }
}

function Require-WindowsSdkHeaders {
    if (-not $env:INCLUDE) {
        throw "INCLUDE is empty. Open an x64 Native Tools prompt from VS 2022 Build Tools so the Windows SDK environment is loaded."
    }

    foreach ($header in @("windows.h", "d3d12.h", "dxgi1_6.h")) {
        $found = $false
        foreach ($includeDir in ($env:INCLUDE -split ";")) {
            if (-not $includeDir) { continue }
            if (Test-Path (Join-Path $includeDir $header)) {
                $found = $true
                break
            }
        }

        if (-not $found) {
            throw "Windows SDK header '$header' was not found in INCLUDE. Install a Windows 10/11 SDK through VS 2022 Build Tools, then reopen the x64 Native Tools prompt."
        }
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
Require-PythonVersion
Require-CmakeVersion

$SourceDir = Join-Path $WorkDir "onnxruntime-$OrtVersion"
$RepoUrl   = "https://github.com/microsoft/onnxruntime.git"
$Tag       = "v$OrtVersion"

function Ensure-Source {
    if (-not (Test-Path (Join-Path $SourceDir ".git"))) {
        Write-Host "Cloning ONNX Runtime $Tag into $SourceDir" -ForegroundColor Cyan
        git -c core.longpaths=true clone --recursive --depth 1 --shallow-submodules --branch $Tag $RepoUrl $SourceDir
        if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
    } elseif ((git -C $SourceDir describe --tags --exact-match HEAD 2>$null) -eq $Tag) {
        Write-Host "Existing checkout is already at $Tag" -ForegroundColor Cyan
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

    # WebGPU stays statically linked into onnxruntime.dll, with the Dawn/DXC
    # DLLs side by side: RedLnx appends the EP by name on the core it loads,
    # which a `shared_lib` plugin EP (loaded through RegisterExecutionProviderLibrary)
    # would not satisfy. DirectML is always compiled into the core; the
    # build restores DirectML.dll from the Microsoft.AI.DirectML NuGet and
    # copies it next to onnxruntime.dll.
    $providerArgs = @()
    $extraDefines = @("onnxruntime_BUILD_UNIT_TESTS=OFF", "CMAKE_SHARED_LINKER_FLAGS=delayimp.lib")
    switch ($Provider) {
        "webgpu" {
            $providerArgs = @("--use_webgpu", "static_lib")
            $extraDefines += @("onnxruntime_BUILD_DAWN_SHARED_LIBRARY=ON", "onnxruntime_ENABLE_DAWN_BACKEND_VULKAN=ON")
        }
        "directml" { $providerArgs = @("--use_dml") }
        default    { throw "unsupported provider $Provider" }
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
    Require-AtlHeaders
    Require-WindowsSdkHeaders
    if (-not (Get-Command ninja.exe -ErrorAction SilentlyContinue)) {
        throw "ninja.exe is not in PATH. Install Ninja (`"winget install Ninja-build.Ninja`") or use a Native Tools prompt that bundles it."
    }
    if ($Provider -eq "webgpu") { Require-NodeTools }

    # Note: `--compile_no_warning_as_error` was dropped — ORT 1.24.2's
    # build.py either renamed or removed it, and PowerShell ended up
    # leaking the flag straight into the cmake invocation. Instead we
    # tolerate compiler warnings by leaving the default behaviour alone;
    # if a build breaks on a real warning, fix the warning rather than
    # silencing every check.
    # Call build.py directly. ORT's build.bat prepends its own
    # `--build_dir <source>\build\Windows`, which makes diagnostics noisy
    # and can mask the build directory selected by this script.
    # `--no_telemetry` is the build.py switch since telemetry became the
    # default for native builds; it sets onnxruntime_USE_TELEMETRY=OFF.
    # A CMAKE_GENERATOR in the caller's environment would leak into ORT's
    # ExternalProject sub-builds, so it is cleared for this process.
    # Ensure-Source already checked the submodules out; `--skip_submodule_sync`
    # keeps two provider builds on one source tree from racing on the git index.
    Add-GitUsrBinToPath
    Remove-Item Env:CMAKE_GENERATOR, Env:CMAKE_GENERATOR_INSTANCE, Env:CMAKE_TOOLCHAIN_FILE -ErrorAction SilentlyContinue
    & python $buildScript `
        --config Release `
        --build_shared_lib `
        --no_telemetry `
        --skip_submodule_sync `
        --parallel $Jobs `
        --skip_tests `
        --build_dir $BuildDir `
        --cmake_generator "$generator" `
        --cmake_extra_defines @extraDefines `
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

    switch ($Provider) {
        "webgpu" {
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
            # dxil.dll is optional: up to ORT 1.24.x the build copied the signed
            # validator next to dxcompiler.dll; the Dawn pinned by ORT 1.31.x
            # (v20260916) loads only dxcompiler.dll and the build no longer
            # produces dxil.dll.
            $required = @("onnxruntime.dll", "webgpu_dawn.dll", "dxcompiler.dll")
        }
        "directml" {
            $patterns = @(
                "onnxruntime.dll",
                "onnxruntime_providers_shared.dll",
                "DirectML.dll"
            )
            $required = @("onnxruntime.dll", "DirectML.dll")
        }
    }

    # Top-level outputs first: the DirectML NuGet restore leaves x86, arm and
    # arm64 copies of DirectML.dll deeper in the tree.
    $copied = @()
    foreach ($pat in $patterns) {
        $found = Get-ChildItem -Path $releaseRoot -Filter $pat -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $found) {
            $found = Get-ChildItem -Path $releaseRoot -Filter $pat -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '\\(x86|arm|arm64)-win\\' } |
                Sort-Object { $_.FullName.Length } |
                Select-Object -First 1
        }
        if ($found) {
            Copy-Item -Path $found.FullName -Destination $packageDir -Force
            $copied += $found.Name
        }
    }

    $directmlVersion = $null
    if ($Provider -eq "directml") {
        $dmlPackage = Get-ChildItem -Path (Join-Path $BuildDir "packages"), (Join-Path $BuildDir "Release\packages") `
                -Directory -Filter "Microsoft.AI.DirectML.*" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $dmlPackage) {
            throw "Microsoft.AI.DirectML NuGet package not found under $BuildDir"
        }
        $directmlVersion = $dmlPackage.Name.Substring("Microsoft.AI.DirectML.".Length)
        $dmlLicense = Join-Path $dmlPackage.FullName "LICENSE.txt"
        if (-not (Test-Path $dmlLicense)) {
            throw "DirectML license not found at $dmlLicense"
        }
        Copy-Item -Path $dmlLicense -Destination (Join-Path $packageDir "DIRECTML-LICENSE.txt")
        $copied += "DIRECTML-LICENSE.txt"
        $dmlFromPackage = Join-Path $dmlPackage.FullName "bin\x64-win\DirectML.dll"
        $dmlPackaged = Join-Path $packageDir "DirectML.dll"
        if ((Test-Path $dmlPackaged) -and
            (Get-FileHash $dmlPackaged).Hash -ne (Get-FileHash $dmlFromPackage).Hash) {
            throw "packaged DirectML.dll differs from the x64 NuGet redistributable $dmlFromPackage"
        }
    }

    # dxcompiler.dll is built from the DirectX Shader Compiler sources Dawn
    # pins; ORT's ThirdPartyNotices.txt names Dawn but not DXC, so its own
    # license travels with the binary.
    if ($Provider -eq "webgpu") {
        $dxcLicense = Join-Path $BuildDir "Release\_deps\dawn-src\third_party\directx-shader-compiler\src\LICENSE.TXT"
        if (-not (Test-Path $dxcLicense)) {
            throw "DirectX Shader Compiler license not found at $dxcLicense"
        }
        Copy-Item -Path $dxcLicense -Destination (Join-Path $packageDir "DXC-LICENSE.txt")
        $copied += "DXC-LICENSE.txt"
    }

    # Required deliverables — fail the build immediately if missing.
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
    $repoNotice = Join-Path $PSScriptRoot "..\NOTICE.txt"
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
    }
    if ($directmlVersion) { $manifest.directmlVersion = $directmlVersion }
    $manifest.telemetry = "disabled at build time (--no_telemetry)"
    switch ($Provider) {
        "webgpu" {
            $manifest.notes = @(
                "Copy or extract these files into RedLnx runtime storage, or point REDLNX_RUNTIME_DIR at this directory.",
                "WebGPU on Windows is statically linked into onnxruntime.dll for ORT $OrtVersion; webgpu_dawn.dll and the DXC DLL(s) must remain beside it.",
                "The host needs working Vulkan or D3D12 drivers from the GPU vendor."
            )
        }
        "directml" {
            $manifest.notes = @(
                "Extract these files into <RedLnx runtime storage>/directml/ (NOT the runtime root: this onnxruntime.dll is the DirectML flavor and must not replace the CUDA/WebGPU one).",
                "DirectML is statically linked into this onnxruntime.dll (ONNX Runtime $OrtVersion built from source with --use_dml); DirectML.dll (Microsoft.AI.DirectML $directmlVersion) must remain beside it.",
                "RedLnx loads this flavor only when Settings > AI Engines device is set to DirectML. Works on every DirectX 12 GPU: AMD, Intel, NVIDIA, integrated APUs."
            )
        }
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
