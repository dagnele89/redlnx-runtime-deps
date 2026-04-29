#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Install one downloaded runtime asset into RedLnx runtime storage.

Environment:
  ASSET        Path to .tar.zst, .tgz, .tar.gz, or .zip asset. Required.
  RUNTIME_DIR  Destination runtime dir, default: ~/.local/share/redlnx/runtime
  STRIP_TOP    1 to strip first archive directory, default: 1

Examples:
  ASSET=dist/downloads/redlnx-onnxruntime-linux-x64-webgpu-1.24.2.tar.zst ./bin/install-runtime-asset.sh
  ASSET=dist/downloads/onnxruntime-linux-x64-gpu-1.24.2.tgz RUNTIME_DIR=/tmp/redlnx-runtime ./bin/install-runtime-asset.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

ASSET="${ASSET:-}"
RUNTIME_DIR="${RUNTIME_DIR:-$HOME/.local/share/redlnx/runtime}"
STRIP_TOP="${STRIP_TOP:-1}"

if [[ -z "$ASSET" ]]; then
  echo "ASSET is required" >&2
  usage >&2
  exit 1
fi

if [[ ! -f "$ASSET" ]]; then
  echo "asset not found: $ASSET" >&2
  exit 1
fi

tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

case "$ASSET" in
  *.tar.zst)
    tar -I zstd -xf "$ASSET" -C "$tmp"
    ;;
  *.tgz|*.tar.gz)
    tar -xzf "$ASSET" -C "$tmp"
    ;;
  *.zip)
    if ! command -v unzip >/dev/null 2>&1; then
      echo "missing unzip command" >&2
      exit 1
    fi
    unzip -q "$ASSET" -d "$tmp"
    ;;
  *)
    echo "unsupported asset type: $ASSET" >&2
    exit 1
    ;;
esac

mkdir -p "$RUNTIME_DIR"

source_dir="$tmp"
if [[ "$STRIP_TOP" == "1" ]]; then
  first_dir="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)"
  if [[ -n "$first_dir" ]]; then
    source_dir="$first_dir"
  fi
fi

copied=0
while IFS= read -r -d '' file; do
  name="$(basename "$file")"
  case "$name" in
    libonnxruntime*.so*|onnxruntime*.dll|LICENSE|NOTICE.txt|ThirdPartyNotices.txt|runtime-manifest.txt|redlnx-runtime-package.json)
      cp -a "$file" "$RUNTIME_DIR/"
      copied=$((copied + 1))
      ;;
  esac
done < <(find "$source_dir" \( -type f -o -type l \) -print0)

if [[ "$copied" -eq 0 ]]; then
  echo "no runtime files copied from $ASSET" >&2
  exit 1
fi

(
  cd "$RUNTIME_DIR"
  find . -maxdepth 1 -mindepth 1 \( -type f -o -type l \) -printf '%f\n' | sort > runtime-manifest.txt
)

echo "installed $copied runtime files into $RUNTIME_DIR"
echo "Use: REDLNX_RUNTIME_DIR=$RUNTIME_DIR"
