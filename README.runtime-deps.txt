RedLnx Runtime Deps Starter Kit
================================

Copy the contents of this directory to the root of your redlnx-runtime-deps repo.

Recommended repository workflow
-------------------------------

Yes: keep this in a real redlnx-runtime-deps clone. Git does not clone GitHub
Release assets, but the helper scripts can download them into the clone.

Example:

  git clone https://github.com/dagnele89/redlnx-runtime-deps.git
  cp -a runtime-deps-kit/. redlnx-runtime-deps/
  cd redlnx-runtime-deps

Download existing release assets:

  TAG=v1-linux-runtime PATTERN='*.tar.zst*' ./bin/download-release-assets.sh

Install one asset into the local RedLnx runtime folder:

  ASSET=dist/downloads/redlnx-onnxruntime-linux-x64-webgpu-1.24.2.tar.zst ./bin/install-runtime-asset.sh

Then run RedLnx with the runtime folder explicitly if needed:

  REDLNX_RUNTIME_DIR="$HOME/.local/share/redlnx/runtime" cargo tauri dev

This keeps the repo as the source for scripts/manifests and GitHub Releases as
the source for large binaries.

What these files build
----------------------

The main target is a Linux x64 ONNX Runtime bundle with AMD-friendly GPU providers:

- WebGPU/Vulkan fallback: libonnxruntime_providers_webgpu.so using Dawn/WebGPU
- MIGraphX, optional: libonnxruntime_providers_migraphx.so

ONNX Runtime 1.24.2 does not expose the old standalone ROCm EP build flag.
Use WebGPU/Vulkan first on Fedora AMD systems. Use MIGraphX only when a MIGraphX
SDK is installed separately.

Each bundle also includes:

- libonnxruntime.so
- libonnxruntime_providers_shared.so when produced by the build
- runtime-manifest.txt
- redlnx-runtime-package.json
- ONNX Runtime license / third-party notices when present in the source tree

Important limits
----------------

MIGraphX bundles are not fully standalone. The target machine still needs matching AMD ROCm and MIGraphX runtime libraries visible through the system loader.

WebGPU/Vulkan is experimental. ONNX Runtime exposes it as WebGPU, not as a native Vulkan provider. RedLnx labels it Vulkan because it registers WebGPU with DawnBackendType::Vulkan.

Local build on Fedora
---------------------

1. Install generic build dependencies:

   sudo dnf install -y git cmake ninja-build python3 python3-pip gcc gcc-c++ make tar zstd patchelf

   Or use the Fedora helper:

   chmod +x bin/install-fedora-amd-build-deps.sh
   ./bin/install-fedora-amd-build-deps.sh

2. For WebGPU/Vulkan, install a working Vulkan loader and GPU driver.

   Fedora AMD/Intel:

     sudo dnf install -y vulkan-loader mesa-vulkan-drivers vulkan-tools

   Debian/Ubuntu AMD/Intel:

     sudo apt install libvulkan1 mesa-vulkan-drivers vulkan-tools

   Arch AMD:

     sudo pacman -S vulkan-icd-loader vulkan-radeon vulkan-tools

   Arch Intel:

     sudo pacman -S vulkan-icd-loader vulkan-intel vulkan-tools

   Arch NVIDIA:

     sudo pacman -S vulkan-icd-loader nvidia-utils vulkan-tools

   Verify the driver is visible before testing RedLnx:

     vulkaninfo --summary

   For MIGraphX, install AMD ROCm and MIGraphX development packages for your distro.

   Package names vary by repo/version. For MIGraphX builds, verify these commands work before building:

   rocminfo
   hipconfig --version

3. Build WebGPU/Vulkan bundle:

   chmod +x bin/build-onnxruntime-linux.sh
   ORT_VERSION=1.24.2 REDLNX_PROVIDER_SET=webgpu ./bin/build-onnxruntime-linux.sh

4. Build MIGraphX bundle, only when MIGraphX SDK is present:

   MIGRAPHX_HOME=/path/to/migraphx ORT_VERSION=1.24.2 REDLNX_PROVIDER_SET=migraphx ./bin/build-onnxruntime-linux.sh

Artifacts are written to dist/.

GitHub Actions build
--------------------

The included workflow uses a self-hosted Linux x64 runner because provider builds should be tested on target-like AMD hardware.

1. Copy .github/workflows/build-linux-onnxruntime.yml into redlnx-runtime-deps.
2. Register a self-hosted runner with labels: self-hosted, linux, x64.
3. Install the build deps on that runner. Install MIGraphX only if building the MIGraphX provider.
4. Run the workflow manually with provider_set=migraphx, webgpu, or all.
5. If the workflow runs on a tag, it uploads dist/* as release assets.

How RedLnx consumes it
----------------------

RedLnx currently detects local provider libraries in:

- REDLNX_RUNTIME_DIR
- ORT_DYLIB_PATH parent directory
- LD_LIBRARY_PATH
- ROCM_PATH/HIP_PATH lib directories
- /opt/rocm/lib and /opt/rocm/lib64
- /usr/local/lib, /usr/lib64, /usr/lib

RedLnx can fetch the WebGPU/Vulkan release asset and extract it into:

  ~/.local/share/redlnx/runtime

Release naming suggestion
-------------------------

Use a tag like:

  v1-linux-runtime

Suggested assets:

  redlnx-onnxruntime-linux-x64-migraphx-1.24.2-rocm6.tar.zst
  redlnx-onnxruntime-linux-x64-webgpu-1.24.2.tar.zst

Current WebGPU/Vulkan SHA256:

  9c786f8ee837add2392bb38009fd35d3a5066dc4518d629cb31d0a994366d2d6

Licensing
---------

ONNX Runtime is MIT licensed. Dawn/WebGPU, ROCm, and MIGraphX components have their own licenses. Keep the copied LICENSE and ThirdPartyNotices files in each archive, and add attribution in the release notes.
