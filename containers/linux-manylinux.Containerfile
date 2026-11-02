# The Linux build base for every RedLnx ONNX Runtime core: AlmaLinux 8 with
# glibc 2.28, as the published CUDA core, so a core loads on Ubuntu 20.04 and
# later, Debian 11 and later, RHEL 8 and later. A core built on the host takes
# the host's glibc (Fedora 44: 2.43) and loads almost nowhere else.
#
# ROCm 7.1.1 comes from AMD's RHEL 8 repository: MIGraphX 2.14 to build the
# provider against, and the libraries the AMD bundle ships beside it.
FROM quay.io/pypa/manylinux_2_28_x86_64

RUN printf '%s\n' '[rocm]' 'name=ROCm 7.1.1' \
      'baseurl=https://repo.radeon.com/rocm/rhel8/7.1.1/main' \
      'enabled=1' 'gpgcheck=1' 'gpgkey=https://repo.radeon.com/rocm/rocm.gpg.key' \
      > /etc/yum.repos.d/rocm.repo \
 && dnf install -y migraphx-devel migraphx rocblas rocblas-devel hipblaslt hipblaslt-devel \
      miopen-hip miopen-hip-devel hip-devel zstd patchelf \
 && dnf clean all

# build.py needs a current Python; manylinux keeps them under /opt/python.
ENV PATH=/opt/python/cp312-cp312/bin:$PATH
RUN pip install --no-cache-dir cmake ninja
