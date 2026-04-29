#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Download RedLnx runtime release assets into a local folder.

Environment:
  REPO       GitHub repo, default: dagnele89/redlnx-runtime-deps
  TAG        Release tag, default: latest
  PATTERN    Asset glob or exact file name, default: *
  OUT_DIR    Output directory, default: dist/downloads

Examples:
  TAG=v1-linux-runtime PATTERN='*.tar.zst*' ./bin/download-release-assets.sh
  TAG=v1 PATTERN='cuda12-win-x64.zip' ./bin/download-release-assets.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

REPO="${REPO:-dagnele89/redlnx-runtime-deps}"
TAG="${TAG:-latest}"
PATTERN="${PATTERN:-*}"
OUT_DIR="${OUT_DIR:-dist/downloads}"

mkdir -p "$OUT_DIR"

is_exact_asset_name() {
  [[ "$PATTERN" != *'*'* && "$PATTERN" != *'?'* && "$PATTERN" != *'['* && "$PATTERN" != *']'* ]]
}

download_exact_asset() {
  if [[ "$TAG" == "latest" ]]; then
    return 1
  fi
  if ! is_exact_asset_name; then
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    return 1
  fi

  local url="https://github.com/$REPO/releases/download/$TAG/$PATTERN"
  local output="$OUT_DIR/$PATTERN"
  echo "downloading $url"
  curl --fail --location --retry 3 --output "$output" "$url"
  return 0
}

if download_exact_asset; then
  echo "downloaded assets into $OUT_DIR"
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "missing gh CLI for wildcard/latest release download." >&2
  echo "Use exact TAG and exact PATTERN to download without gh auth, or run: gh auth login" >&2
  exit 1
fi

if [[ "$TAG" == "latest" ]]; then
  gh release download --repo "$REPO" --pattern "$PATTERN" --dir "$OUT_DIR" --clobber
else
  gh release download "$TAG" --repo "$REPO" --pattern "$PATTERN" --dir "$OUT_DIR" --clobber
fi

echo "downloaded assets into $OUT_DIR"
