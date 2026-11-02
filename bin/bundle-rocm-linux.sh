#!/usr/bin/env bash
# Puts the ROCm 7.1.1 libraries MIGraphX runs on beside the MIGraphX core, so
# an AMD machine needs nothing from its distribution: any ROCm version, or
# none. Runs inside containers/linux-manylinux.Containerfile, after
# build-onnxruntime-linux.sh, on the package directory it wrote.
#
# Kernels of AMD's datacenter GPUs (Instinct MI100/MI200/MI300/MI350) are left
# out: RedLnx runs on Radeon cards and Ryzen graphics. Vega (Radeon VII,
# Vega 56/64) stays.
#
# usage: bundle-rocm-linux.sh <package dir>
set -euo pipefail

PACKAGE_DIR="${1:?usage: bundle-rocm-linux.sh <package dir>}"
ROCM="${ROCM_HOME:-/opt/rocm}"
INSTINCT='gfx908|gfx90a|gfx940|gfx941|gfx942|gfx950'

export LD_LIBRARY_PATH="$ROCM/lib:$ROCM/lib/migraphx/lib"

# Every library the provider and MIGraphX's GPU target load from ROCm, plus
# libnuma, which not every distribution installs.
closure() {
  ldd "$@" | awk '/=>/ {print $3}' | sort -u | while read -r lib; do
    case "$(readlink -f "$lib")" in
      /opt/rocm*|*/libnuma.so*) echo "$lib" ;;
    esac
  done
}

copy_lib() {
  local lib="$1"
  local name
  name="$(basename "$lib")"
  [[ -e "$PACKAGE_DIR/$name" ]] || cp -L "$lib" "$PACKAGE_DIR/$name"
}

mapfile -t libs < <(closure "$PACKAGE_DIR/libonnxruntime_providers_migraphx.so" \
  "$ROCM/lib/migraphx/lib/libmigraphx_gpu.so")
for lib in "${libs[@]}"; do
  copy_lib "$lib"
done
# The GPU target is loaded by name at run time, not linked.
copy_lib "$ROCM/lib/migraphx/lib/libmigraphx_gpu.so.2014000"

# rocBLAS and hipBLASLt find their kernels beside themselves.
for library in rocblas hipblaslt; do
  mkdir -p "$PACKAGE_DIR/$library/library"
  find "$ROCM/lib/$library/library" -maxdepth 1 -type f | grep -Ev "$INSTINCT" |
    xargs -r cp -t "$PACKAGE_DIR/$library/library"
done

# Each library finds the others in its own directory.
find "$PACKAGE_DIR" -maxdepth 1 -name '*.so*' -type f -print0 |
  xargs -0 -n1 patchelf --set-rpath '$ORIGIN'

mkdir -p "$PACKAGE_DIR/licenses"
for doc in amd_comgr hip hipblaslt hsa-runtime64 migraphx miopen-hip rocblas rocm-core \
  rocprofiler-register roctracer; do
  [[ -d "$ROCM/share/doc/$doc" ]] || continue
  find "$ROCM/share/doc/$doc" -maxdepth 1 -type f \( -iname 'LICENSE*' -o -iname 'NOTICE*' \) |
    while read -r file; do
      cp "$file" "$PACKAGE_DIR/licenses/$doc-$(basename "$file")"
    done
done
# libnuma (LGPL-2.1) ships no licence file in its RPM: the text from numactl's
# repository, and where its source is.
cp "$(dirname "$0")/../licenses/numactl-LICENSE.LGPL2.1" "$PACKAGE_DIR/licenses/"
printf '%s\n' "libnuma.so.1: unmodified, from AlmaLinux 8's $(rpm -q numactl-libs)." \
  "Source: the matching numactl source RPM of AlmaLinux 8, and https://github.com/numactl/numactl." \
  > "$PACKAGE_DIR/licenses/numactl-SOURCE.txt"

# The archive build-onnxruntime-linux.sh wrote predates these files.
(
  cd "$PACKAGE_DIR"
  find . -maxdepth 1 -mindepth 1 \( -type f -o -type l \) -printf '%f\n' | sort > runtime-manifest.txt
)
archive="$PACKAGE_DIR.tar.zst"
rm -f "$archive" "$archive.sha256"
tar -I 'zstd -19 -T0' -cf "$archive" -C "$(dirname "$PACKAGE_DIR")" "$(basename "$PACKAGE_DIR")"
sha256sum "$archive" | tee "$archive.sha256"
du -sh "$PACKAGE_DIR" "$archive"
