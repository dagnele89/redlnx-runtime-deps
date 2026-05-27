#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <runtime-dir-or-tar.zst>" >&2
  exit 1
fi

input="$1"
tmp=""
cleanup() {
  if [[ -n "$tmp" ]]; then
    rm -rf "$tmp"
  fi
}
trap cleanup EXIT

if [[ -d "$input" ]]; then
  dir="$input"
else
  tmp="$(mktemp -d)"
  tar -I zstd -xf "$input" -C "$tmp"
  dir="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
fi

missing=0
for file in libonnxruntime.so; do
  if [[ ! -e "$dir/$file" ]]; then
    echo "missing: $file"
    missing=1
  fi
done

provider_count=0
for provider in \
  libonnxruntime_providers_rocm.so \
  libonnxruntime_providers_migraphx.so \
  libonnxruntime_providers_webgpu.so \
  libonnxruntime_providers_cuda.so; do
  if [[ -e "$dir/$provider" ]]; then
    echo "found: $provider"
    provider_count=$((provider_count + 1))
  fi
done

# The WebGPU EP can be linked INTO libonnxruntime.so (static_lib layout) instead
# of shipping as a separate plugin. In that case there is no providers_*.so, so
# detect the built-in provider by the EP registration symbol in the main dylib.
# (Dawn strings are NOT usable: Dawn is statically linked in both layouts.)
if [[ "$provider_count" -eq 0 ]]; then
  lib="$(readlink -f "$dir/libonnxruntime.so" 2>/dev/null || true)"
  if [[ -n "$lib" && -e "$lib" ]]; then
    # SIGPIPE-safe under `set -o pipefail`: capture a count (grep -c reads all
    # input) rather than `grep -q` (which SIGPIPEs the huge nm/strings producer
    # and makes the pipeline report failure despite a match).
    nm_hits=0
    if command -v nm >/dev/null 2>&1; then
      nm_hits="$(nm -C "$lib" 2>/dev/null | grep -cE 'WebGpuProviderFactoryCreator|WebGpuExecutionProvider' || true)"
    fi
    str_hits="$(strings -a "$lib" 2>/dev/null | grep -c 'WebGpuProviderFactoryCreator' || true)"
    if [[ "${nm_hits:-0}" -gt 0 || "${str_hits:-0}" -gt 0 ]]; then
      echo "found: WebGPU EP built into libonnxruntime.so"
      provider_count=$((provider_count + 1))
    fi
  fi
fi

if [[ "$provider_count" -eq 0 ]]; then
  echo "missing: no GPU provider library found"
  missing=1
fi

if [[ -f "$dir/runtime-manifest.txt" ]]; then
  echo "found: runtime-manifest.txt"
fi

if [[ "$missing" -ne 0 ]]; then
  exit 1
fi

echo "runtime package looks usable: $dir"
