RedLnx Runtime Dependencies Notice
==================================

This repository stores helper scripts and release assets for optional RedLnx
runtime dependencies. These binary assets are separate third-party components
and are NOT covered by the AGPL-3.0 license that governs the RedLnx source
code.

GeoCalib perspective-field model
--------------------------------

Asset: `geocalib-perspective-field-pinhole.onnx`

SHA256: `1d59fa256989dabb33e03fdcd85813d2c860c4fab7c127e470f924647b06d13c`

This is an ONNX export of the perspective-field network from cvg/GeoCalib at
revision `97b8968e7798a66bf04fcf791fb535624241bda7`. The upstream source code is
Apache-2.0 and the pretrained `pinhole` weights are CC-BY-4.0. The export emits
up-vector, latitude, and confidence fields; it does not include the upstream
Levenberg-Marquardt optimization loop.

Source: https://github.com/cvg/GeoCalib

Paper: Luca Veicht, Paul-Edouard Sarlin, Philipp Lindenberger, Viktor Larsson,
Marc Pollefeys, and Torsten Sattler, "GeoCalib: Single-image Calibration with
Geometric Optimization", ECCV 2024, https://arxiv.org/abs/2409.06704

Depth Anything V2 Small FP16
----------------------------

Asset: `depth-anything-v2-small-fp16.onnx`

SHA256: `10d35ac4e5e705a6d2bcbcb7685e11846fc02e2658cc61ac3a7c6984bb807e11`

This asset is an ONNX export of the Small checkpoint from
DepthAnything/Depth-Anything-V2, using the export published by
onnx-community/depth-anything-v2-small-ONNX at revision
`c3b67641fd837b2368757101311e5d21e511441e`.

The upstream source code and the Small checkpoint are licensed under the
Apache License 2.0. Only the Small checkpoint is redistributed. The Base,
Large, and Giant checkpoints are CC-BY-NC-4.0 and are excluded.

Sources:

  https://github.com/DepthAnything/Depth-Anything-V2
  https://huggingface.co/onnx-community/depth-anything-v2-small-ONNX

EfficientSAM Ti April 2025
--------------------------

Asset: `efficient-sam-ti-2025apr.onnx`

SHA256: `4eb496e0a7259b435b49b66faf1754aa45a5c382a34558ddda9a8c6fe5915d77`

This asset is the EfficientSAM Ti ONNX model published by
opencv/image_segmentation_efficientsam at revision
`1e791988b34b2098736003057da0f3e6bc826259`, derived from
yformer/EfficientSAM.

License: Apache License 2.0.

Sources:

  https://github.com/yformer/EfficientSAM
  https://huggingface.co/opencv/image_segmentation_efficientsam

BiRefNet General FP16
---------------------

Asset: `birefnet-general-fp16.onnx`

SHA256: `3654c741eb80bd926ada8fed1713b506ccf8d30eb1f6487e87eb9f234f33df09`

This asset is an ONNX export of ZhengPeng7/BiRefNet, published by
onnx-community/BiRefNet-ONNX at revision
`534d3c82d3bb8b2f0867db6dfbc3a525b8e42f67`.

License: MIT License.

BiRefNet General is preferred; `birefnet_lite_fp16.onnx` remains the
low-resource fallback.

Sources:

  https://github.com/ZhengPeng7/BiRefNet
  https://huggingface.co/onnx-community/BiRefNet-ONNX

BiRefNet Portrait FP16
----------------------

Asset: `birefnet-portrait-fp16.onnx`

SHA256: `4c05930c0b6f1418d02eb1de81c46fe37638ba54f5a93adeb5c674521db10110`

This asset is an ONNX FP16 export of the BiRefNet portrait-matting variant,
published by onnx-community/BiRefNet-portrait-ONNX (`onnx/model_fp16.onnx`),
derived from ZhengPeng7/BiRefNet. The exporter replaces the upstream
`deform_conv2d` with a grid_sample-equivalent so the graph runs in ONNX
Runtime; the output is a sigmoid-like foreground membership map.

License: MIT License.

Used by RedLnx as the "portrait" option of the subject-mask hair/edge matting
refinement stage.

Sources:

  https://github.com/ZhengPeng7/BiRefNet
  https://huggingface.co/onnx-community/BiRefNet-portrait-ONNX

BiRefNet Matting FP32
---------------------

Asset: `birefnet-matting-fp32.onnx`

SHA256: `f0843e38f6a4e88efc8c5fad4178ad7ed6c818346ce12f82e7b579324fe7e0c5`

This asset is an ONNX FP32 export (opset 16) of ZhengPeng7/BiRefNet-matting,
published by emrikol/birefnet-matting-onnx (`birefnet-matting.onnx`). The
exporter replaces the upstream `deform_conv2d` with a grid_sample-equivalent
so the graph runs in ONNX Runtime; the output is logits (apply a sigmoid for
the alpha matte). FP32 is retained because a bench measured a structured
precision loss on hair/edge alpha when this model is converted to FP16.

License: MIT License.

Used by RedLnx as the "matting" option of the subject-mask hair/edge matting
refinement stage.

Sources:

  https://github.com/ZhengPeng7/BiRefNet
  https://huggingface.co/emrikol/birefnet-matting-onnx

Linux ONNX Runtime WebGPU/Vulkan runtime
----------------------------------------

Package:

  redlnx-onnxruntime-linux-x64-webgpu-1.24.2.tar.zst

SHA256:

  9c786f8ee837add2392bb38009fd35d3a5066dc4518d629cb31d0a994366d2d6

Contents:

  libonnxruntime.so
  libonnxruntime.so.1
  libonnxruntime.so.1.24.2
  libonnxruntime_providers_shared.so
  libonnxruntime_providers_webgpu.so
  LICENSE
  ThirdPartyNotices.txt
  VERSION_NUMBER
  runtime-manifest.txt
  redlnx-runtime-package.json

The package is built from ONNX Runtime 1.24.2 and enables the ONNX Runtime
WebGPU execution provider. RedLnx registers this provider with Dawn's Vulkan
backend and labels it as the Linux Vulkan fallback in the application UI.

ONNX Runtime is licensed under the MIT License. The release archive includes
the upstream ONNX Runtime LICENSE and ThirdPartyNotices.txt files. Those files
must stay with the archive and installed runtime files.

Dawn/WebGPU and related Vulkan build dependencies are covered by their own
upstream open-source notices as captured by the ONNX Runtime third-party
notices file included in the package.

Vulkan is a registered trademark of the Khronos Group Inc. WebGPU is a W3C web
standard. Dawn is an open-source WebGPU implementation from the Chromium
project.

NVIDIA CUDA / cuDNN runtime
---------------------------

This package contains pre-built binary libraries ("DLLs") from NVIDIA
Corporation, redistributed under the terms of the NVIDIA Software License
Agreement.  These files are NOT open-source and are NOT covered by the
AGPL-3.0 license that governs the RedLnx source code.

The included DLLs are provided solely for the purpose of enabling GPU-
accelerated inference inside the RedLnx application.  They are unmodified
copies of the official NVIDIA redistributable binaries obtained from:

  CUDA Toolkit  — https://developer.nvidia.com/cuda-toolkit
  cuDNN SDK     — https://developer.nvidia.com/cudnn

By downloading or using these files, you agree to the NVIDIA license terms
included in this package:

  NVIDIA-CUDA-LICENSE.txt   — NVIDIA CUDA Toolkit EULA
  NVIDIA-CUDNN-LICENSE.txt  — NVIDIA cuDNN SDK License Agreement

NVIDIA, CUDA, and cuDNN are trademarks or registered trademarks of
NVIDIA Corporation.

This redistribution is permitted under section 1.1(iii) and 1.2 of the
NVIDIA Software License Agreement, which allows distribution of the
"distributable" portions of the SDK as incorporated into a software
application with material additional functionality.

RedLnx is not affiliated with, endorsed by, or sponsored by NVIDIA
Corporation.

RedLnx Camera Looks F v1
------------------------

Package:

  redlnx-camera-looks-f-v1.zip

SHA256:

  7b5266f1e15e9b7bf8f40919a5d00b56892c6158f291486bac6410d44ef6830e

The following chroma-only LUTs are generated from GPL-3.0-or-later presets
embedded in darktable. The tone curve is intentionally excluded so RedLnx's
own CAM/ODT tone path remains authoritative:

  f-as.cube  F-AS  Inspired by Fujifilm Astia
  f-cc.cube  F-CC  Inspired by Fujifilm Classic Chrome
  f-mo.cube  F-MO  Inspired by Fujifilm Monochrome
  f-pr.cube  F-PR  Inspired by Fujifilm Provia
  f-ve.cube  F-VE  Inspired by Fujifilm Velvia

These five files derive from the color-checker presets in darktable
src/iop/colorchecker.c. darktable attributes them to Jo's Fuji film
emulations. The following file derives from the Acros 100 spectral weights in
darktable src/iop/channelmixerrgb.c:

  f-ac.cube  F-AC  Inspired by Fujifilm Acros

Copyright (C) darktable developers and the respective preset contributors.
License: GNU General Public License version 3 or later.
Source: https://github.com/darktable-org/darktable
Jo's styles: https://jo.dreggn.org/blog/darktable-fuji-styles.tar.xz

F-AS, F-CC, F-MO, F-PR, F-VE and F-AC are RedLnx display names. Fujifilm and
the referenced simulation names are used only to describe inspiration and
compatibility. RedLnx is not affiliated with or endorsed by Fujifilm.

Package contents
----------------
cuda12-win-x64.zip:
  cublas64_12.dll, cublasLt64_12.dll, cudart64_12.dll,
  cufft64_12.dll, curand64_10.dll, cusolver64_12.dll, cusparse64_12.dll

cudnn9-cuda12-win-x64.zip:
  cudnn64_9.dll, cudnn_adv64_9.dll, cudnn_cnn64_9.dll,
  cudnn_engines_precompiled64_9.dll, cudnn_engines_runtime_compiled64_9.dll,
  cudnn_engines_tensor_ir64_9.dll, cudnn_graph64_9.dll,
  cudnn_heuristic64_9.dll, cudnn_ops64_9.dll

Compatibility: ONNX Runtime 1.20.x with CUDA 12 Execution Provider.
