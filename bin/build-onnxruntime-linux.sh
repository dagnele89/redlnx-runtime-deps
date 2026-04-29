#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build ONNX Runtime Linux x64 provider bundles for RedLnx.

Environment:
  ORT_VERSION             ONNX Runtime version, default: 1.24.2
  REDLNX_PROVIDER_SET     webgpu | migraphx | all, default: webgpu
  ROCM_HOME               ROCm root for MIGraphX builds, auto-detected from hipconfig
  MIGRAPHX_HOME           MIGraphX root, default: $ROCM_HOME
  ROCM_VERSION_LABEL      Suffix for ROCm artifacts, default: rocm6
  WORK_DIR                Build cache directory, default: .work
  OUT_DIR                 Artifact output directory, default: dist
  JOBS                    Parallel jobs, default: nproc
  CLEAN_BUILD             1 to remove per-provider build dir first, default: 0

Examples:
  REDLNX_PROVIDER_SET=webgpu ./bin/build-onnxruntime-linux.sh
  REDLNX_PROVIDER_SET=migraphx MIGRAPHX_HOME=/path/to/migraphx ./bin/build-onnxruntime-linux.sh

Note:
  ONNX Runtime 1.24.2 no longer exposes a standalone ROCm EP build flag.
  For AMD Linux, WebGPU/Vulkan is the practical generic GPU path. MIGraphX
  requires a separate MIGraphX SDK installation.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

detect_rocm_home() {
  if command -v hipconfig >/dev/null 2>&1; then
    while IFS=: read -r key value; do
      key="${key//[[:space:]]/}"
      if [[ "$key" == "ROCM_PATH" ]]; then
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ -n "$value" ]]; then
          printf '%s\n' "$value"
          return
        fi
      fi
    done < <(hipconfig --full 2>/dev/null || true)
  fi

  if [[ -d /opt/rocm ]]; then
    printf '%s\n' /opt/rocm
  else
    printf '%s\n' /usr
  fi
}

ORT_VERSION="${ORT_VERSION:-1.24.2}"
REDLNX_PROVIDER_SET="${REDLNX_PROVIDER_SET:-webgpu}"
ROCM_HOME="${ROCM_HOME:-$(detect_rocm_home)}"
MIGRAPHX_HOME="${MIGRAPHX_HOME:-$ROCM_HOME}"
ROCM_VERSION_LABEL="${ROCM_VERSION_LABEL:-rocm6}"
WORK_DIR="${WORK_DIR:-$PWD/.work}"
OUT_DIR="${OUT_DIR:-$PWD/dist}"
JOBS="${JOBS:-$(nproc)}"
CLEAN_BUILD="${CLEAN_BUILD:-0}"

SOURCE_DIR="$WORK_DIR/onnxruntime-$ORT_VERSION"
REPO_URL="https://github.com/microsoft/onnxruntime.git"
TAG="v$ORT_VERSION"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "missing required command: $cmd" >&2
    exit 1
  fi
}

require_cmd git
require_cmd python3
require_cmd cmake
require_cmd ninja
require_cmd tar
require_cmd zstd
require_cmd sha256sum

mkdir -p "$WORK_DIR" "$OUT_DIR"

provider_list() {
  case "$REDLNX_PROVIDER_SET" in
    rocm)
      echo "ONNX Runtime $ORT_VERSION does not support --use_rocm." >&2
      echo "Use REDLNX_PROVIDER_SET=webgpu for AMD Vulkan fallback, or REDLNX_PROVIDER_SET=migraphx with a MIGraphX SDK." >&2
      exit 1
      ;;
    migraphx) printf '%s\n' migraphx ;;
    webgpu|vulkan) printf '%s\n' webgpu ;;
    all) printf '%s\n' webgpu migraphx ;;
    *)
      echo "unsupported REDLNX_PROVIDER_SET=$REDLNX_PROVIDER_SET" >&2
      usage >&2
      exit 1
      ;;
  esac
}

ensure_source() {
  if [[ ! -d "$SOURCE_DIR/.git" ]]; then
    git clone --recursive --depth 1 --branch "$TAG" "$REPO_URL" "$SOURCE_DIR"
  else
    git -C "$SOURCE_DIR" fetch --depth 1 origin "$TAG"
    git -C "$SOURCE_DIR" checkout "$TAG"
    git -C "$SOURCE_DIR" submodule sync --recursive
    git -C "$SOURCE_DIR" submodule update --init --recursive --depth 1
  fi
}

copy_matches() {
  local from_dir="$1"
  local to_dir="$2"
  local pattern="$3"
  while IFS= read -r -d '' file; do
    cp -a "$file" "$to_dir/"
  done < <(find "$from_dir" \( -type f -o -type l \) -name "$pattern" -print0)
}

ensure_unversioned_libonnxruntime() {
  local package_dir="$1"
  if [[ -e "$package_dir/libonnxruntime.so" ]]; then
    return
  fi

  local candidate
  candidate="$(find "$package_dir" -maxdepth 1 -type f -name 'libonnxruntime.so.*' | sort | head -n 1 || true)"
  if [[ -n "$candidate" ]]; then
    ln -s "$(basename "$candidate")" "$package_dir/libonnxruntime.so"
  fi
}

require_packaged_file() {
  local package_dir="$1"
  local file_name="$2"
  if [[ ! -e "$package_dir/$file_name" ]]; then
    echo "missing required packaged file: $file_name" >&2
    echo "package dir: $package_dir" >&2
    exit 1
  fi
}

write_manifest_files() {
  local package_dir="$1"
  local provider="$2"
  local artifact_name="$3"

  (
    cd "$package_dir"
    find . -maxdepth 1 -mindepth 1 \( -type f -o -type l \) -printf '%f\n' | sort > runtime-manifest.txt
  )

  cat > "$package_dir/redlnx-runtime-package.json" <<JSON
{
  "schemaVersion": 1,
  "packageId": "linux-x64-$provider",
  "artifactName": "$artifact_name",
  "platform": "linux-x64",
  "onnxRuntimeVersion": "$ORT_VERSION",
  "provider": "$provider",
  "rocmHomeUsedForBuild": "$ROCM_HOME",
  "migraphxHomeUsedForBuild": "$MIGRAPHX_HOME",
  "notes": [
    "Copy or extract these files into RedLnx runtime storage, or point REDLNX_RUNTIME_DIR at this directory.",
    "Provider builds may require matching system GPU driver/runtime libraries on the target system."
  ]
}
JSON
}

package_provider() {
  local provider="$1"
  local build_dir="$2"
  local package_suffix="$provider-$ORT_VERSION"
  if [[ "$provider" == "rocm" || "$provider" == "migraphx" ]]; then
    package_suffix="$package_suffix-$ROCM_VERSION_LABEL"
  fi

  local package_name="redlnx-onnxruntime-linux-x64-$package_suffix"
  local package_dir="$OUT_DIR/$package_name"
  local archive="$OUT_DIR/$package_name.tar.zst"

  rm -rf "$package_dir" "$archive" "$archive.sha256"
  mkdir -p "$package_dir"

  copy_matches "$build_dir" "$package_dir" 'libonnxruntime.so*'
  copy_matches "$build_dir" "$package_dir" 'libonnxruntime_providers_*.so*'

  for notice in LICENSE ThirdPartyNotices.txt VERSION_NUMBER; do
    if [[ -f "$SOURCE_DIR/$notice" ]]; then
      cp -a "$SOURCE_DIR/$notice" "$package_dir/"
    fi
  done
  if [[ -f "$PWD/NOTICE.txt" ]]; then
    cp -a "$PWD/NOTICE.txt" "$package_dir/"
  fi

  ensure_unversioned_libonnxruntime "$package_dir"
  require_packaged_file "$package_dir" libonnxruntime.so

  case "$provider" in
    rocm)
      require_packaged_file "$package_dir" libonnxruntime_providers_rocm.so
      ;;
    migraphx)
      require_packaged_file "$package_dir" libonnxruntime_providers_migraphx.so
      ;;
    webgpu)
      require_packaged_file "$package_dir" libonnxruntime_providers_webgpu.so
      ;;
  esac

  write_manifest_files "$package_dir" "$provider" "$(basename "$archive")"
  tar -I zstd -cf "$archive" -C "$OUT_DIR" "$package_name"
  sha256sum "$archive" | tee "$archive.sha256"
  echo "built $archive"
}

build_provider() {
  local provider="$1"
  local build_dir="$WORK_DIR/build-$provider-$ORT_VERSION"

  if [[ "$CLEAN_BUILD" == "1" ]]; then
    rm -rf "$build_dir"
  fi

  local args=(
    python3 "$SOURCE_DIR/tools/ci_build/build.py"
    --config Release
    --build_shared_lib
    --parallel "$JOBS"
    --skip_tests
    --build_dir "$build_dir"
    --cmake_generator Ninja
    --compile_no_warning_as_error
    --update
    --build
  )

  case "$provider" in
    migraphx)
      if ! find "$MIGRAPHX_HOME" -name 'migraphx-config.cmake' -print -quit 2>/dev/null | grep -q .; then
        echo "MIGraphX SDK not found under MIGRAPHX_HOME=$MIGRAPHX_HOME" >&2
        echo "Fedora ROCm packages provide HIP/rocBLAS/MIOpen, but not MIGraphX on this machine." >&2
        echo "Use REDLNX_PROVIDER_SET=webgpu now, or install/build MIGraphX and set MIGRAPHX_HOME." >&2
        exit 1
      fi
      args+=(--use_migraphx --migraphx_home "$MIGRAPHX_HOME")
      ;;
    webgpu)
      args+=(--use_webgpu shared_lib)
      ;;
    *)
      echo "internal error: unsupported provider $provider" >&2
      exit 1
      ;;
  esac

  echo "building provider=$provider ORT_VERSION=$ORT_VERSION build_dir=$build_dir"
  "${args[@]}"
  package_provider "$provider" "$build_dir"
}

ensure_source
while IFS= read -r provider; do
  build_provider "$provider"
done < <(provider_list)

echo "artifacts written to $OUT_DIR"
