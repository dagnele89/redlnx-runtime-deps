#!/usr/bin/env python3

import argparse
import hashlib
import json
import re
import struct
import zipfile
from pathlib import Path

import numpy as np


COLORCHECKER_SHA256 = "fde70924e5774b587b8398b2ffd501daad83e5a5b8925ae69fc8edf06e0d63e5"
CHANNELMIXER_SHA256 = "2eda8d4b1906fe3565e96d22c89980a93095e4aeca314fcde71869d392e1a5f8"
GRID_SIZE = 33
LOOKS = (
    ("f-as", "F-AS", "Astia", "astia"),
    ("f-cc", "F-CC", "Classic Chrome", "chrome"),
    ("f-mo", "F-MO", "Monochrome", "mchrome"),
    ("f-pr", "F-PR", "Provia", "provia"),
    ("f-ve", "F-VE", "Velvia", "velvia"),
)
RGB_TO_XYZ_D50 = np.array(
    (
        (0.4360747, 0.3850649, 0.1430804),
        (0.2225045, 0.7168786, 0.0606169),
        (0.0139322, 0.0971045, 0.7141733),
    ),
    dtype=np.float64,
)
XYZ_D50_TO_RGB = np.linalg.inv(RGB_TO_XYZ_D50)
D50 = np.array((0.96422, 1.0, 0.82521), dtype=np.float64)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_source(path, expected):
    actual = sha256(path)
    if actual != expected:
        raise SystemExit(f"source hash mismatch for {path}: expected {expected}, got {actual}")


def extract_params(source, symbol):
    match = re.search(
        rf'const char \*{re.escape(symbol)}_params_input\s*=\s*"([0-9a-f]+)"',
        source,
    )
    if not match:
        raise SystemExit(f"darktable preset {symbol!r} not found")
    raw = bytes.fromhex(match.group(1))
    floats = np.array(struct.unpack_from("<294f", raw), dtype=np.float64).reshape(6, 49)
    count = struct.unpack_from("<i", raw, 294 * 4)[0]
    if count < 5 or count > 49:
        raise SystemExit(f"invalid patch count {count} for {symbol}")
    source_lab = np.column_stack((floats[0, :count], floats[1, :count], floats[2, :count]))
    target_lab = np.column_stack((floats[3, :count], floats[4, :count], floats[5, :count]))
    return source_lab, target_lab


def kernel(left, right):
    diff = left[:, None, :] - right[None, :, :]
    radius2 = np.sum(diff * diff, axis=2)
    return radius2 * np.log(np.maximum(1.0e-8, radius2))


def solve_tps(source_lab, target_lab):
    count = source_lab.shape[0]
    matrix = np.zeros((count + 4, count + 4), dtype=np.float64)
    matrix[:count, :count] = kernel(source_lab, source_lab)
    polynomial = np.column_stack((np.ones(count), source_lab))
    matrix[:count, count:] = polynomial
    matrix[count:, :count] = polynomial.T
    targets = np.zeros((count + 4, 3), dtype=np.float64)
    targets[:count] = target_lab
    return np.linalg.solve(matrix, targets)


def apply_tps(lab, source_lab, coefficients):
    count = source_lab.shape[0]
    radial = kernel(lab, source_lab) @ coefficients[:count]
    polynomial = np.column_stack((np.ones(lab.shape[0]), lab)) @ coefficients[count:]
    return radial + polynomial


def lab_curve(values):
    epsilon = 216.0 / 24389.0
    kappa = 24389.0 / 27.0
    return np.where(values > epsilon, np.cbrt(values), (kappa * values + 16.0) / 116.0)


def lab_curve_inverse(values):
    epsilon = 6.0 / 29.0
    return np.where(values > epsilon, values**3, 3.0 * epsilon**2 * (values - 4.0 / 29.0))


def linear_rgb_to_lab(rgb):
    xyz = rgb @ RGB_TO_XYZ_D50.T
    scaled = xyz / D50
    curved = lab_curve(scaled)
    return np.column_stack(
        (116.0 * curved[:, 1] - 16.0, 500.0 * (curved[:, 0] - curved[:, 1]), 200.0 * (curved[:, 1] - curved[:, 2]))
    )


def lab_to_linear_rgb(lab):
    fy = (lab[:, 0] + 16.0) / 116.0
    curved = np.column_stack((fy + lab[:, 1] / 500.0, fy, fy - lab[:, 2] / 200.0))
    xyz = lab_curve_inverse(curved) * D50
    return xyz @ XYZ_D50_TO_RGB.T


def identity_grid(size):
    axis = np.linspace(0.0, 1.0, size, dtype=np.float64)
    return np.array([(r, g, b) for b in axis for g in axis for r in axis], dtype=np.float64)


def bake_color_look(source_text, symbol, grid):
    source_lab, target_lab = extract_params(source_text, symbol)
    coefficients = solve_tps(source_lab, target_lab)
    input_lab = linear_rgb_to_lab(grid)
    mapped_lab = apply_tps(input_lab, source_lab, coefficients)
    mapped_lab[:, 0] = input_lab[:, 0]
    return lab_to_linear_rgb(mapped_lab)


def bake_acros(grid):
    weights = np.array((0.333, 0.313, 0.353), dtype=np.float64)
    grey = grid @ weights
    return np.repeat(grey[:, None], 3, axis=1)


def write_cube(path, title, values):
    with path.open("w", encoding="ascii", newline="\n") as handle:
        handle.write(f'TITLE "{title}"\n')
        handle.write(f"LUT_3D_SIZE {GRID_SIZE}\n")
        handle.write("DOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n")
        for row in values:
            handle.write(f"{row[0]:.9g} {row[1]:.9g} {row[2]:.9g}\n")


def deterministic_zip(root, destination):
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(root.rglob("*")):
            if not path.is_file():
                continue
            info = zipfile.ZipInfo(path.relative_to(root.parent).as_posix(), (2026, 7, 12, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, path.read_bytes(), compresslevel=9)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--darktable-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    colorchecker = args.darktable_root / "src" / "iop" / "colorchecker.c"
    channelmixer = args.darktable_root / "src" / "iop" / "channelmixerrgb.c"
    require_source(colorchecker, COLORCHECKER_SHA256)
    require_source(channelmixer, CHANNELMIXER_SHA256)

    pack = args.output / "camera-looks-f-v1"
    pack.mkdir(parents=True, exist_ok=True)
    source_text = colorchecker.read_text(encoding="utf-8")
    grid = identity_grid(GRID_SIZE)
    manifest_looks = []
    for file_stem, display_name, inspired_name, symbol in LOOKS:
        destination = pack / f"{file_stem}.cube"
        write_cube(destination, display_name, bake_color_look(source_text, symbol, grid))
        manifest_looks.append(
            {
                "id": display_name,
                "label": display_name,
                "subtitle": f"Inspired by Fujifilm {inspired_name}",
                "file": destination.name,
                "sha256": sha256(destination),
            }
        )

    acros = pack / "f-ac.cube"
    write_cube(acros, "F-AC", bake_acros(grid))
    manifest_looks.append(
        {
            "id": "F-AC",
            "label": "F-AC",
            "subtitle": "Inspired by Fujifilm Acros",
            "file": acros.name,
            "sha256": sha256(acros),
        }
    )
    manifest = {
        "schema": 1,
        "pack": "camera-looks-f-v1",
        "license": "GPL-3.0-or-later",
        "processing": "chroma-only; RedLnx tone curve remains authoritative",
        "source": {
            "project": "darktable",
            "colorchecker_sha256": COLORCHECKER_SHA256,
            "channelmixerrgb_sha256": CHANNELMIXER_SHA256,
        },
        "looks": manifest_looks,
    }
    (pack / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    (pack / "NOTICE.txt").write_text(
        "RedLnx Camera Looks F v1\n\n"
        "The F-AS, F-CC, F-MO, F-PR and F-VE LUTs are generated from the Fuji film "
        "emulation color-checker presets embedded in darktable src/iop/colorchecker.c. "
        "darktable attributes those presets to Jo's Fuji film emulations and states that "
        "the tone curve is intentionally omitted. F-AC is generated from the Fuji Acros 100 "
        "spectral weights in darktable src/iop/channelmixerrgb.c.\n\n"
        "Copyright (C) darktable developers and the respective preset contributors.\n"
        "License: GNU General Public License version 3 or later.\n"
        "Source: https://github.com/darktable-org/darktable\n"
        "Jo's styles: https://jo.dreggn.org/blog/darktable-fuji-styles.tar.xz\n\n"
        "F-AS, F-CC, F-MO, F-PR, F-VE and F-AC are RedLnx display names. Fujifilm, "
        "Astia, Classic Chrome, Provia, Velvia and Acros are used only to describe "
        "compatibility/inspiration. RedLnx is not affiliated with or endorsed by Fujifilm.\n",
        encoding="utf-8",
    )
    destination = args.output / "redlnx-camera-looks-f-v1.zip"
    deterministic_zip(pack, destination)
    print(json.dumps({"archive": str(destination), "sha256": sha256(destination), "looks": manifest_looks}, indent=2))


if __name__ == "__main__":
    main()
