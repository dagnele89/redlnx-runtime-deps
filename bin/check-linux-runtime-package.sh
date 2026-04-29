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
