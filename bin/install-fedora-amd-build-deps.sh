#!/usr/bin/env bash
set -euo pipefail

echo "This installs Fedora packages needed to build ONNX Runtime ROCm provider bundles."
echo "It does not build or install RedLnx itself."
echo

sudo dnf --disablerepo='ookla_speedtest-cli*' install -y \
  git \
  cmake \
  ninja-build \
  python3 \
  python3-pip \
  gcc \
  gcc-c++ \
  make \
  tar \
  zstd \
  patchelf \
  rocminfo \
  rocm-core \
  rocm-runtime \
  rocm-runtime-devel \
  rocm-hip \
  rocm-hip-devel \
  rocm-clang \
  rocm-clang-devel \
  rocm-comgr \
  rocm-comgr-devel \
  rocm-device-libs \
  rocblas \
  miopen \
  hipblas \
  hipblaslt \
  hipsolver \
  hipsparse \
  hipfft \
  hiprand

echo
echo "Verify with:"
echo "  rocminfo | head"
echo "  hipconfig --full"
